// VaultWriter — writes a finished meeting to the vault as markdown + git-commits it.
//
// Phase 5 / ADR-0016 §4: the engine is now the sole meeting-file writer. This
// runs ONLY at capture.stop, after the offline diarization pass — never on the
// live hot path. The output format is fixed by ADR-0015 §1 (front-matter +
// `## Transcript` body of blockquoted utterances), with the speaker fields
// ADR-0015 reserved now populated by Phase 5's "Speaker N" labels.
//
// Java analogue: a stateless `@Component` writer with one public method. It's
// a `struct`, not an `actor`, because it holds NO mutable state — every call
// takes its inputs as parameters and touches only the filesystem + a local git
// process. EngineSession (an actor) already serializes the single call site, so
// there's nothing here to synchronize. We mark it `Sendable` so it crosses the
// actor boundary cleanly. The work is synchronous, blocking I/O; the caller
// hops it off the live path by only invoking it at stop.
//
// Hard rules honored:
//   #2/#4: writes ONLY under ~/Documents/vault/hark/; never deletes or rewrites
//          an existing file — filename collisions get a -2/-3 suffix.
//   #5:    no embeddings written or transmitted — v1 emits anonymous labels.
//   No network: git is purely local (init + add + commit). No remote, no push.
//   No new dependency: git is shelled out via Foundation.Process.
//
// Privacy: this type writes transcript text to the vault (the one sanctioned
// location, rule #2). It MUST NOT log transcript content to stderr — log lines
// are paths, counts, and git status only.

import Foundation

@available(macOS 14.4, *)
struct VaultWriter: Sendable {

    /// One labeled, finalized utterance to render into the transcript body.
    /// `tStart` is seconds since capture start; we add it to the session's
    /// wall-clock start to print an absolute HH:MM:SS header per ADR-0015.
    struct Utterance: Sendable {
        let tStart: Double
        let label: String   // "Speaker N" (v1 anonymous) or "Speaker ?"
        let text: String
    }

    /// Outcome of a write. The `.md` is the durable artefact; git is
    /// best-effort layered on top (ADR-0015 §4) and never fails the write.
    struct Result: Sendable {
        let fileURL: URL
        let slug: String
        let committed: Bool
    }

    /// Vault root — `~/Documents/vault/hark`. Resolved the same homedir way as
    /// HarkPaths (NSHomeDirectory), but pointed at the VAULT, not app-support:
    /// transcripts are user content (rule #2), caches/prefs are not.
    private var vaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents/vault/hark", isDirectory: true)
    }

    private var meetingsDir: URL {
        vaultRoot.appendingPathComponent("meetings", isDirectory: true)
    }

    // ─── Public API ───────────────────────────────────────────────────────

    /// Write the meeting markdown to the vault and (best-effort) git-commit it.
    ///
    /// - Parameters:
    ///   - title: the auto-derived timestamp title (e.g. "Meeting 2026-06-01 14:32").
    ///   - sessionStart: wall-clock start of capture — the anchor for both the
    ///     `date` front-matter and per-utterance HH:MM:SS headers.
    ///   - durationSec: session length in seconds (front-matter `duration_sec`).
    ///   - attendees: distinct speaker labels detected, in first-seen order.
    ///   - utterances: time-ordered, labeled, finalized utterances.
    /// - Returns: the absolute file URL + slug + whether the commit succeeded.
    /// - Throws: only on the FILE write (mkdir / atomic write). Git failures are
    ///   swallowed and reported via `Result.committed == false` — the `.md` is
    ///   already on disk, so a missing commit must not fail the meeting save.
    func write(
        title: String,
        sessionStart: Date,
        durationSec: Double,
        attendees: [String],
        utterances: [Utterance]
    ) throws -> Result {
        let fm = FileManager.default
        try fm.createDirectory(at: meetingsDir, withIntermediateDirectories: true)

        let slug = Self.slug(forStart: sessionStart)
        let (fileURL, finalSlug) = try uniqueFileURL(dateStart: sessionStart, slug: slug)

        let markdown = renderMarkdown(
            title: title,
            sessionStart: sessionStart,
            durationSec: durationSec,
            attendees: attendees,
            utterances: utterances
        )

        try atomicWrite(markdown, to: fileURL)

        // Git is best-effort and entirely local (ADR-0015 §4). Any failure
        // logs and returns committed=false; the .md is already durable.
        let committed = gitCommit(fileURL: fileURL, slug: finalSlug)

        return Result(fileURL: fileURL, slug: finalSlug, committed: committed)
    }

    // ─── Markdown rendering (ADR-0015 §1, design doc 07) ────────────────────

    private func renderMarkdown(
        title: String,
        sessionStart: Date,
        durationSec: Double,
        attendees: [String],
        utterances: [Utterance]
    ) -> String {
        var out = ""
        out += "---\n"
        out += "title: \(yamlScalar(title))\n"
        out += "date: \(Self.iso8601Local(sessionStart))\n"
        out += "duration_sec: \(Int(durationSec.rounded()))\n"
        out += "attendees: [\(attendees.map(yamlScalar).joined(separator: ", "))]\n"
        // Engine retains no bookmark store in this slice — bookmark.create is
        // event-only (UI mirrors it). So `bookmarks: 0` and no 📌 pins. Wiring
        // a session bookmark store + pinned headers is a deferred follow-up.
        out += "bookmarks: 0\n"
        out += "hark_version: \(HARKD_ENGINE_VERSION)\n"
        out += "---\n\n"
        out += "## Transcript\n\n"

        for u in utterances {
            let clock = Self.clockOffset(from: sessionStart, plus: u.tStart)
            // Header: `> **Speaker N** · HH:MM:SS` (ADR-0016 §3 / design 07).
            out += "> **\(u.label)** · \(clock)\n"
            // Body line(s): blockquote each line so multi-line text stays in
            // the quote. We don't re-wrap — Whisper text is already a sentence.
            for line in u.text.split(separator: "\n", omittingEmptySubsequences: false) {
                out += "> \(line)\n"
            }
            out += "\n"
        }
        return out
    }

    /// YAML scalar safety: quote when the value contains a character that would
    /// break the flow scalar (`:`, `#`, brackets, leading/trailing space) or is
    /// empty. Single-quote and double any embedded single quotes — valid YAML.
    private func yamlScalar(_ s: String) -> String {
        let needsQuote = s.isEmpty
            || s.first == " " || s.last == " "
            || s.contains(where: { ":#[]{},&*!|>'\"%@`".contains($0) })
        guard needsQuote else { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // ─── Filename / slug ────────────────────────────────────────────────────

    /// Slug for the v1 auto title: `YYYY-MM-DD-HHMM` in local time. Already
    /// kebab-safe (digits + hyphens), so no further kebab-casing needed.
    static func slug(forStart start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.string(from: start)
    }

    /// Date-prefix portion of the filename: `YYYY-MM-DD` local.
    private static func datePrefix(_ start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    /// Build `meetings/YYYY-MM-DD-{slug}.md`, appending `-2`, `-3`… on
    /// collision. NEVER overwrites an existing file (hard rule #4). Note: the
    /// v1 slug already starts with the date, so the filename is effectively
    /// `meetings/YYYY-MM-DD-HHMM.md`; the date-prefix wrapper is kept so a
    /// future user-supplied title still lands under a dated filename.
    private func uniqueFileURL(dateStart: Date, slug: String) throws -> (URL, String) {
        let fm = FileManager.default
        let prefix = Self.datePrefix(dateStart)
        // Avoid `YYYY-MM-DD-YYYY-MM-DD-HHMM` when the slug already leads with
        // the date (the v1 timestamp slug does).
        let base = slug.hasPrefix(prefix) ? slug : "\(prefix)-\(slug)"

        var candidate = base
        var n = 1
        while fm.fileExists(atPath: meetingsDir.appendingPathComponent("\(candidate).md").path) {
            n += 1
            candidate = "\(base)-\(n)"
        }
        return (meetingsDir.appendingPathComponent("\(candidate).md"), candidate)
    }

    // ─── Atomic write (temp file + rename) ──────────────────────────────────

    private func atomicWrite(_ contents: String, to url: URL) throws {
        // `Data.write(.atomic)` already does write-temp-then-rename on the
        // same volume — the same pattern the UI's prefs.ts uses (ADR-0014).
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    // ─── Local git (ADR-0015 §4 / ADR-0016) ─────────────────────────────────
    //
    // All best-effort: any failure logs and returns false. The .md is already
    // written, so a meeting is never "lost" because git misbehaved.
    //
    //   1. If <vault>/.git is absent → `git init` + set a LOCAL identity so
    //      commits never fail on a machine with no global git config.
    //   2. Ensure <vault>/.gitignore excludes `.speakers/` (rule #5 forward
    //      safety) — created only if missing; never clobber an existing one.
    //   3. `git add meetings/<file>` (+ .gitignore if we just made it) then
    //      `git commit -m "feat(meeting): add <slug>"`.
    //
    // NO remote is added and nothing is pushed — purely local versioning.

    // Privacy isolation (CLAUDE.md rules #1/#3, flagged by a privacy audit):
    // `-c core.hooksPath=/dev/null` disables any user-global git hook
    // (core.hooksPath / ~/.git/hooks / init.templateDir) from firing during
    // Hark's vault writes. Hark adds no remote and never pushes, so this is
    // defense-in-depth — but a privacy-first tool must keep its git fully
    // isolated from user-global config so no user-authored hook can run (and
    // potentially touch the network) inside a Hark commit. Prepended to every
    // invocation for consistency; it changes none of Hark's own behavior
    // (local identity, no remote, no push all unchanged).
    private static let hooksOff = ["-c", "core.hooksPath=/dev/null"]

    private func gitCommit(fileURL: URL, slug: String) -> Bool {
        let vault = vaultRoot.path
        let h = Self.hooksOff
        let gitDir = vaultRoot.appendingPathComponent(".git", isDirectory: true)

        if !FileManager.default.fileExists(atPath: gitDir.path) {
            guard runGit(h + ["-C", vault, "init"]).ok else {
                eprint("harkd: vault git init failed; wrote meeting without commit")
                return false
            }
            // LOCAL identity only — never touch global config (ADR-0015 §4:
            // "never clobber an existing repo or config"). On a fresh repo
            // there's nothing to clobber; on an existing one we skip init
            // entirely (the guard above), so we never overwrite user config.
            _ = runGit(h + ["-C", vault, "config", "user.name", "Hark"])
            _ = runGit(h + ["-C", vault, "config", "user.email", "hark@localhost"])
        }

        ensureGitignore(vault: vault)

        let relPath = "meetings/\(fileURL.lastPathComponent)"
        guard runGit(h + ["-C", vault, "add", relPath, ".gitignore"]).ok else {
            eprint("harkd: vault git add failed; meeting written but uncommitted")
            return false
        }
        let commit = runGit(h + ["-C", vault, "commit", "-m", "feat(meeting): add \(slug)"])
        if !commit.ok {
            eprint("harkd: vault git commit failed (status \(commit.status)); meeting written but uncommitted")
            return false
        }
        return true
    }

    /// Create `<vault>/.gitignore` with a `.speakers/` rule if it doesn't
    /// exist; if it exists but lacks the rule, append it. Never rewrites
    /// unrelated lines. Rule #5 forward-safety: embeddings must never enter
    /// a repo the user might later push.
    private func ensureGitignore(vault: String) {
        let url = vaultRoot.appendingPathComponent(".gitignore")
        let rule = ".speakers/"
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? nil
        if let existing {
            let hasRule = existing
                .split(separator: "\n")
                .contains { $0.trimmingCharacters(in: .whitespaces) == rule }
            if hasRule { return }
            let sep = existing.hasSuffix("\n") ? "" : "\n"
            let appended = existing + sep + "\(rule)\n"
            try? Data(appended.utf8).write(to: url, options: .atomic)
        } else {
            let header = "# Hark vault — voice embeddings stay local (CLAUDE.md rule #5)\n"
            try? Data((header + "\(rule)\n").utf8).write(to: url, options: .atomic)
        }
    }

    /// Run a git subprocess synchronously. Returns (ok, exit status). stdout /
    /// stderr are discarded — we never surface git's text (which could echo a
    /// path) beyond a status code in our own log line.
    private func runGit(_ args: [String]) -> (ok: Bool, status: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = args
        // Discard git's output so nothing leaks to our stderr; also keeps the
        // pipe from filling on a chatty subcommand.
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        // Callers prepend `core.hooksPath=/dev/null` (see `hooksOff`) so a
        // user's global git hooks can't fire during Hark's commit. We also
        // stay local: no remote configured, so commit can't push anyway.
        do {
            try proc.run()
            proc.waitUntilExit()
            return (proc.terminationStatus == 0, proc.terminationStatus)
        } catch {
            return (false, -1)
        }
    }

    // ─── Timestamp formatting ───────────────────────────────────────────────

    /// ISO-8601 with the machine's local UTC offset, e.g.
    /// `2026-06-01T14:32:07+07:00`. ADR-0015 front-matter `date`.
    static func iso8601Local(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]  // includes the offset
        f.timeZone = TimeZone.current
        return f.string(from: date)
    }

    /// `HH:MM:SS` wall-clock header for an utterance at `offset` seconds past
    /// the session start. Local time zone — matches the user's clock.
    static func clockOffset(from start: Date, plus offset: Double) -> String {
        let wall = start.addingTimeInterval(max(0, offset))
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm:ss"
        return f.string(from: wall)
    }

    /// Auto-derived v1 title: `Meeting YYYY-MM-DD HH:MM` (local). A user-
    /// editable title via the UI + capture.start is a deferred follow-up.
    static func autoTitle(forStart start: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "Meeting \(f.string(from: start))"
    }
}
