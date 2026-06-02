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
        let committed = gitCommit(fileURL: fileURL, slug: finalSlug,
                                  message: "feat(meeting): add \(finalSlug)")

        return Result(fileURL: fileURL, slug: finalSlug, committed: committed)
    }

    /// RE-RENDER an already-written meeting in place and (best-effort) git-commit
    /// the change. Used by the post-save speaker-rename path: diarization labels
    /// live only in the saved markdown, so renaming re-renders that same file with
    /// the user's display names. Mirrors `write`'s render→atomicWrite→commit core,
    /// but writes to the EXISTING `fileURL` (overwrite, hard rule #4: this is the
    /// meeting's OWN file, never another) and takes a caller-supplied commit
    /// message. Does NOT touch `uniqueFileURL` — no second file is ever created.
    ///
    /// - Throws: only on the FILE write (atomic write). Git failures are swallowed
    ///   and reported via `Result.committed == false` — same contract as `write`.
    func rewrite(
        fileURL: URL,
        title: String,
        sessionStart: Date,
        durationSec: Double,
        attendees: [String],
        utterances: [Utterance],
        commitMessage: String
    ) throws -> Result {
        let markdown = renderMarkdown(
            title: title,
            sessionStart: sessionStart,
            durationSec: durationSec,
            attendees: attendees,
            utterances: utterances
        )
        try atomicWrite(markdown, to: fileURL)
        let slug = fileURL.deletingPathExtension().lastPathComponent
        let committed = gitCommit(fileURL: fileURL, slug: slug, message: commitMessage)
        return Result(fileURL: fileURL, slug: slug, committed: committed)
    }

    /// APPEND-OR-REPLACE a `## Summary` section in an already-written meeting file
    /// and (best-effort) git-commit the change (ADR-0031 §6). The summary is
    /// generated in the Electron main process and handed in as plain markdown — this
    /// method only persists it; no model is ever called here. Centralizes the vault
    /// write + git-commit in the one owner (hard rule #4), like `rewrite`.
    ///
    /// IDEMPOTENT: if the file already carries a `## Summary` section (re-summarize),
    /// its body is REPLACED in place; otherwise a new `## Summary` section is appended
    /// after the existing content. Never duplicates the heading. The merge itself is
    /// the PURE, unit-tested `mergeSummarySection` (so the live path and the tests
    /// share one definition); this method only does read → merge → atomicWrite →
    /// commit, writing to the EXISTING `fileURL` (overwrite, hard rule #4 — the
    /// meeting's OWN file, never another, never a new one).
    ///
    /// - Throws: only on the FILE I/O (read of the existing file / atomic write).
    ///   Git failures are swallowed and reported via `Result.committed == false` —
    ///   same best-effort-commit contract as `write` / `rewrite`: the `.md` is the
    ///   durable artefact, so a missing commit must not fail the summary save.
    func appendSummary(
        to fileURL: URL,
        summary: String,
        commitMessage: String
    ) throws -> Result {
        let existing = try String(contentsOf: fileURL, encoding: .utf8)
        let merged = Self.mergeSummarySection(into: existing, summary: summary)
        try atomicWrite(merged, to: fileURL)
        let slug = fileURL.deletingPathExtension().lastPathComponent
        let committed = gitCommit(fileURL: fileURL, slug: slug, message: commitMessage)
        return Result(fileURL: fileURL, slug: slug, committed: committed)
    }

    /// PURE append-or-replace of a `## Summary` section in a meeting markdown body.
    /// No I/O, no state — unit-tested directly so the live `appendSummary` path and
    /// the regression suite share one definition of "merge the summary."
    ///
    ///   - If `## Summary` is ABSENT: append a new section after the existing
    ///     content (trimming trailing blank lines first, then one blank line, the
    ///     heading, a blank line, the body) so the file ends with exactly one
    ///     trailing newline.
    ///   - If `## Summary` is PRESENT: REPLACE its body (everything from the heading
    ///     up to the NEXT `## ` heading at column 0, or end-of-file) with the new
    ///     body, leaving everything before the heading and any following sections
    ///     untouched. This is what makes a re-summarize idempotent — no duplicate
    ///     `## Summary` heading, no stacked bodies.
    ///
    /// `summary` is the markdown body only (no heading); it's trimmed of surrounding
    /// whitespace and rendered under a freshly-emitted `## Summary` heading.
    static func mergeSummarySection(into existing: String, summary: String) -> String {
        let heading = "## Summary"
        let body = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let section = "\(heading)\n\n\(body)\n"

        let lines = existing.components(separatedBy: "\n")
        // Find the `## Summary` heading line (exact match on the trimmed line, so a
        // `### Summary` subheading or a quoted "## Summary" in the body doesn't match).
        guard let headingIdx = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == heading
        }) else {
            // ABSENT → append. Drop trailing blank lines from the existing content,
            // then separate with one blank line so the section reads cleanly.
            var trimmed = existing
            while trimmed.hasSuffix("\n") { trimmed.removeLast() }
            if trimmed.isEmpty { return section }
            return trimmed + "\n\n" + section
        }

        // PRESENT → replace the section body. The section runs from the heading up
        // to (but not including) the next top-level `## ` heading, or end-of-file.
        var endIdx = lines.count
        if headingIdx + 1 < lines.count {
            for i in (headingIdx + 1)..<lines.count where lines[i].hasPrefix("## ") {
                endIdx = i
                break
            }
        }

        let before = lines[..<headingIdx]            // content above the section
        let after = lines[endIdx...]                 // following sections, if any

        var out = before.joined(separator: "\n")
        // Keep exactly one blank line between prior content and the section.
        if !out.isEmpty {
            while out.hasSuffix("\n") { out.removeLast() }
            out += "\n\n"
        }
        out += section
        if !after.isEmpty {
            // `section` already ends in "\n"; add one blank line before the next
            // section, then re-join the tail verbatim.
            out += "\n" + after.joined(separator: "\n")
        }
        return out
    }

    // ─── Markdown rendering (ADR-0015 §1, design doc 07) ────────────────────

    // `internal` (not `private`) so the rename re-render path's regression tests
    // can assert the output carries the new names in both the front-matter
    // `attendees:` line and the `> **Name** ·` headers. Pure value→string.
    func renderMarkdown(
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

    private func gitCommit(fileURL: URL, slug: String, message: String) -> Bool {
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
        let commit = runGit(h + ["-C", vault, "commit", "-m", message])
        if !commit.ok {
            eprint("harkd: vault git commit failed (status \(commit.status)); meeting written but uncommitted")
            return false
        }
        return true
    }

    /// Instance shim onto the shared static helper — `gitCommit` knows only the
    /// vault path string, while `ensureSpeakersGitignored` works in URLs (so the
    /// store, which injects its own vault root, can call the same code).
    private func ensureGitignore(vault: String) {
        Self.ensureSpeakersGitignored(vaultRoot: vaultRoot)
    }

    /// Ensure `<vaultRoot>/.gitignore` excludes `.speakers/`: create the file
    /// with the rule if it's missing, append the rule if the file exists but
    /// lacks it, and do nothing if it's already there. Never rewrites unrelated
    /// lines. Rule #5 forward-safety: voice embeddings must never enter a repo
    /// the user might later push.
    ///
    /// `static` + `vaultRoot:`-parameterized (not bound to `VaultWriter`'s
    /// hardcoded root) so `SpeakerStore` — which writes `.speakers/` under its
    /// own injectable root — can assert the ignore rule the moment it creates
    /// that directory, regardless of whether a meeting was ever saved first.
    /// Idempotent, so calling it from both sites can't duplicate the rule.
    static func ensureSpeakersGitignored(vaultRoot: URL) {
        ensureGitignoreRule(
            vaultRoot: vaultRoot, rule: ".speakers/",
            header: "# Hark vault — voice embeddings stay local (CLAUDE.md rule #5)\n")
    }

    /// Ensure `<vaultRoot>/.gitignore` excludes `.audio/` (ADR-0027 / rule #2):
    /// opt-in meeting audio must never travel a vault git remote. Same idempotent
    /// create-or-append semantics + `vaultRoot:` parameterization as
    /// `ensureSpeakersGitignored`, so `EngineSession`'s audio-persist path can
    /// assert the rule the moment it creates `.audio/`, regardless of call order.
    /// Calling both helpers can't duplicate or clobber lines — each only adds its
    /// own missing rule.
    static func ensureAudioGitignored(vaultRoot: URL) {
        ensureGitignoreRule(
            vaultRoot: vaultRoot, rule: ".audio/",
            header: "# Hark vault — meeting audio stays local (ADR-0027 / CLAUDE.md rule #2)\n")
    }

    /// Shared core for the two gitignore self-assertions above: create the
    /// `.gitignore` with `header` + `rule` when missing, append `rule` when the
    /// file exists but lacks it, do nothing when it's already present. Never
    /// rewrites unrelated lines; idempotent by construction.
    private static func ensureGitignoreRule(vaultRoot: URL, rule: String, header: String) {
        let url = vaultRoot.appendingPathComponent(".gitignore")
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
