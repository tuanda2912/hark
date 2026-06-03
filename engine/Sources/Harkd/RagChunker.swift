// RagChunker — split a vault `.md` note into embeddable chunks for the vault-RAG
// index (Phase 6 slice 4b, ADR-0032/0033).
//
// The job: turn one markdown file into a list of overlapping, heading-aware text
// windows, each small enough for the embedder's context (multilingual-e5-small,
// 512 tokens) and each prefixed with its heading breadcrumb so a window carries
// the structural context it was cut from. We DO NOT embed raw YAML front-matter;
// title/date/tags are lifted into metadata instead (they're navigation, not prose,
// and embedding YAML keys pollutes the vector).
//
// Java analogue: a stateless utility — like a `@Component` parser with one pure
// `chunk(...)` method. Everything here is pure value→value, no actor, no I/O (the
// file READ happens in RagIndexer, which hands the string in), so the unit tests
// drive it deterministically with literal markdown and no filesystem.
//
// Token budget: we approximate token count by characters (~4 chars/token for the
// languages we target — EN/VI/TH). This is deliberately SIMPLE (ADR-0033 "keep it
// simple"): the embedder truncates at 512 tokens anyway, so a slightly-off char
// estimate only costs a touch of overlap precision, never correctness. We size the
// window WELL under the model's 512-token cap (≈ targetChars) so the heading
// breadcrumb prefix + e5 "passage: " prefix never push a window past truncation.
//
// Privacy: chunk text is vault content (rule #2). This file NEVER logs chunk text —
// it returns values to the caller. The contentHash is a digest, not the text.

import Foundation
import Crypto

/// One embeddable unit of a note. `chunkId` is a STABLE content-addressed key
/// (hash of notePath + charStart + the chunk's contentHash) so re-indexing an
/// unchanged region yields the same id — the index can diff by id, and a stable
/// id survives a note edit elsewhere in the file as long as this region's bytes
/// and offset didn't move. `text` is the embeddable payload (breadcrumb already
/// prepended); `headingPath` is the human breadcrumb retained for retrieval
/// display; char offsets locate the chunk in the ORIGINAL file body for the UI's
/// "open at" affordance (4c).
struct RagChunk: Sendable, Equatable {
    let chunkId: String
    /// Vault-relative POSIX path, e.g. "meetings/2026-06-01-1432.md". The index
    /// keys per-file state on this; never an absolute path (portable across a
    /// vault move, and nothing machine-specific lands in meta.jsonl).
    let notePath: String
    /// Heading breadcrumb, e.g. "Design > Risks". Empty for pre-heading prose.
    let headingPath: String
    /// Char offsets into the note BODY (front-matter stripped). For the UI's
    /// jump-to-source; the index stores them in meta.jsonl.
    let charStart: Int
    let charEnd: Int
    /// The embeddable text: the heading breadcrumb (if any) + the window prose.
    let text: String
    /// SHA-256 (hex) of `text`. Part of `chunkId` and stored in meta so an
    /// incremental re-index can tell whether THIS chunk's content actually moved.
    let contentHash: String
}

/// Lightweight note metadata lifted from YAML front-matter. Not embedded; kept so
/// 4c can show a note's title/date/tags alongside a hit, and so the indexer can
/// fold them into the breadcrumb if desired. Best-effort: a note with no/ malformed
/// front-matter yields all-nil/empty — never an error (we still index the body).
struct NoteFrontMatter: Sendable, Equatable {
    let title: String?
    let date: String?
    let tags: [String]
}

enum RagChunker {
    /// Target window size in CHARACTERS (≈ targetTokens × 4). 1600 chars ≈ 400
    /// tokens — comfortably inside e5's 512-token cap with room for the breadcrumb
    /// + "passage: " prefix the embedder prepends. Mid-range of the 256–512-token
    /// ask (ADR-0033).
    static let targetChars = 1600
    /// Overlap in characters between consecutive windows of the SAME section
    /// (~12% of target). Carries a sentence's tail into the next window so a fact
    /// straddling a cut boundary is still retrievable from at least one window.
    static let overlapChars = 200
    /// Don't emit a window shorter than this UNLESS it's a whole (small) section —
    /// avoids a sliver tail window of a few characters. A short section is still
    /// indexed in full (it's meaningful), but we won't split off a tiny remainder.
    static let minTailChars = 80

    /// Chunk a full note's raw markdown into embeddable windows + return the
    /// front-matter metadata. Pure: `rawMarkdown` in, chunks out.
    ///
    /// Pipeline:
    ///   1. strip YAML front-matter → metadata (title/date/tags) + body
    ///   2. heading-aware split: walk the body, tracking a heading-level stack so
    ///      each line knows its breadcrumb ("H1 > H2 > H3")
    ///   3. within each heading SECTION, pack the prose into ~targetChars windows
    ///      with ~overlapChars overlap, prepending the breadcrumb to each window
    ///   4. mint a stable chunkId per window
    static func chunk(notePath: String, rawMarkdown: String) -> (chunks: [RagChunk], frontMatter: NoteFrontMatter) {
        let (frontMatter, body, bodyOffset) = splitFrontMatter(rawMarkdown)
        let sections = splitIntoSections(body, bodyOffset: bodyOffset)

        var chunks: [RagChunk] = []
        for section in sections {
            let windows = packWindows(text: section.text,
                                      baseOffset: section.charStart,
                                      headingPath: section.headingPath)
            for w in windows {
                let breadcrumb = section.headingPath.isEmpty ? "" : section.headingPath + "\n\n"
                let embedText = breadcrumb + w.text
                let contentHash = sha256Hex(embedText)
                let chunkId = stableChunkId(notePath: notePath, charStart: w.charStart, contentHash: contentHash)
                chunks.append(RagChunk(
                    chunkId: chunkId,
                    notePath: notePath,
                    headingPath: section.headingPath,
                    charStart: w.charStart,
                    charEnd: w.charEnd,
                    text: embedText,
                    contentHash: contentHash))
            }
        }
        return (chunks, frontMatter)
    }

    // ─── Front-matter ───────────────────────────────────────────────────────

    /// Strip a leading YAML front-matter block (`---` … `---`) and parse the few
    /// keys we care about (title, date, tags). Returns the metadata, the BODY (with
    /// front-matter removed), and the char offset of the body within the ORIGINAL
    /// string — so chunk char offsets point into the real file, not the stripped
    /// body. A note with no front-matter is all body, offset 0.
    ///
    /// We hand-parse rather than pull a YAML dep: we only read three scalar/list
    /// keys, and a tolerant line scan never throws on the messy real-world YAML the
    /// external Obsidian sync produces. Anything we don't recognize is ignored.
    static func splitFrontMatter(_ raw: String) -> (NoteFrontMatter, body: String, bodyOffset: Int) {
        let lines = raw.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (NoteFrontMatter(title: nil, date: nil, tags: []), raw, 0)
        }
        // Find the closing fence.
        var closeIdx: Int? = nil
        for i in 1..<lines.count where lines[i].trimmingCharacters(in: .whitespaces) == "---" {
            closeIdx = i
            break
        }
        guard let close = closeIdx else {
            // Unterminated front-matter: treat the whole thing as body (tolerant).
            return (NoteFrontMatter(title: nil, date: nil, tags: []), raw, 0)
        }

        var title: String? = nil
        var date: String? = nil
        var tags: [String] = []
        var i = 1
        while i < close {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let v = scalarValue(trimmed, key: "title") { title = v }
            else if let v = scalarValue(trimmed, key: "date") { date = v }
            else if trimmed == "tags:" {
                // Block list form: subsequent `- tag` lines.
                var j = i + 1
                while j < close {
                    let t = lines[j].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix("- ") else { break }
                    tags.append(unquote(String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces)))
                    j += 1
                }
                i = j
                continue
            } else if let v = scalarValue(trimmed, key: "tags") {
                // Flow list form: `tags: [a, b]` or `tags: a, b`.
                tags = parseFlowList(v)
            }
            i += 1
        }

        // Body offset = byte/char index just past the closing fence's newline.
        // Each of lines[0...close] contributed its content + a "\n" join char.
        var offset = 0
        for k in 0...close { offset += lines[k].count + 1 }   // +1 for the "\n"
        // Guard against an off-by-one past end (file ending exactly at the fence).
        let chars = Array(raw)
        if offset > chars.count { offset = chars.count }
        let body = String(chars[offset...])
        return (NoteFrontMatter(title: title, date: date, tags: tags), body, offset)
    }

    private static func scalarValue(_ line: String, key: String) -> String? {
        let prefix = key + ":"
        guard line.hasPrefix(prefix) else { return nil }
        let v = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : unquote(v)
    }

    private static func parseFlowList(_ v: String) -> [String] {
        var s = v
        if s.hasPrefix("[") && s.hasSuffix("]") { s = String(s.dropFirst().dropLast()) }
        return s.split(separator: ",")
            .map { unquote($0.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
    }

    private static func unquote(_ s: String) -> String {
        var v = s
        if (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")), v.count >= 2 {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    // ─── Heading-aware section split ──────────────────────────────────────────

    /// One contiguous run of prose under a single heading breadcrumb. `text` is the
    /// section body WITHOUT its own heading line (the breadcrumb carries it).
    /// `charStart` is the offset of `text` in the ORIGINAL file.
    struct Section: Equatable {
        let headingPath: String
        let text: String
        let charStart: Int
    }

    /// Walk the body line by line. An ATX heading (`#`…`######` at column 0) opens a
    /// new section and updates the heading stack at that level (trimming deeper
    /// levels). The breadcrumb is the live stack joined by " > ". Lines between
    /// headings accumulate into the current section. Fenced code blocks (``` …```)
    /// are passed through verbatim and NOT scanned for headings (a `#` inside code
    /// is a comment, not a heading).
    static func splitIntoSections(_ body: String, bodyOffset: Int) -> [Section] {
        var sections: [Section] = []
        var stack: [(level: Int, title: String)] = []
        var currentLines: [String] = []
        var currentStartOffset = bodyOffset
        var scanOffset = bodyOffset
        var inFence = false

        func breadcrumb() -> String {
            stack.map { $0.title }.joined(separator: " > ")
        }
        func flush() {
            let text = currentLines.joined(separator: "\n")
            // Only emit sections with real prose (something past whitespace).
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sections.append(Section(headingPath: breadcrumb(), text: text, charStart: currentStartOffset))
            }
            currentLines.removeAll(keepingCapacity: true)
        }

        let lines = body.components(separatedBy: "\n")
        for (idx, line) in lines.enumerated() {
            let lineLen = line.count + (idx < lines.count - 1 ? 1 : 0)   // +1 for the join "\n"
            let fenceToggle = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if fenceToggle { inFence.toggle() }

            if !inFence && !fenceToggle, let (level, title) = headingOf(line) {
                // Close the section that was accumulating before this heading.
                flush()
                // Pop the stack to the parent level, then push this heading.
                while let last = stack.last, last.level >= level { stack.removeLast() }
                stack.append((level, title))
                // New section's prose starts AFTER this heading line.
                currentStartOffset = scanOffset + lineLen
            } else {
                if currentLines.isEmpty { currentStartOffset = scanOffset }
                currentLines.append(line)
            }
            scanOffset += lineLen
        }
        flush()
        return sections
    }

    /// Parse an ATX heading line → (level 1–6, title). Returns nil for non-headings.
    /// Requires `#`+ then a space (so "#tag" / "#!/bin" don't count) at column 0.
    static func headingOf(_ line: String) -> (level: Int, title: String)? {
        guard line.first == "#" else { return nil }
        var level = 0
        var idx = line.startIndex
        while idx < line.endIndex, line[idx] == "#", level < 7 {
            level += 1
            idx = line.index(after: idx)
        }
        guard level >= 1 && level <= 6 else { return nil }
        guard idx < line.endIndex, line[idx] == " " else { return nil }
        let title = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }
        return (level, title)
    }

    // ─── Window packing ───────────────────────────────────────────────────────

    /// A packed window of a section's prose, with absolute char offsets.
    struct Window: Equatable {
        let text: String
        let charStart: Int
        let charEnd: Int
    }

    /// Pack one section's text into ~targetChars windows with ~overlapChars overlap.
    /// We slide a char window forward by (target − overlap) each step, preferring to
    /// END a window at a sentence/paragraph boundary near the target so a window
    /// doesn't split mid-word. `baseOffset` maps window positions to the real file.
    ///
    /// A section shorter than `targetChars` becomes a single window (no overlap).
    static func packWindows(text: String, baseOffset: Int, headingPath: String) -> [Window] {
        let trimmedLeading = text.drop(while: { $0 == "\n" })
        let leadDrop = text.count - trimmedLeading.count
        let chars = Array(text)
        let n = chars.count
        if n == 0 { return [] }

        // Whole-section fast path.
        if n <= targetChars {
            let body = String(chars).trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { return [] }
            // Recompute trimmed bounds for accurate offsets.
            let (s, e) = trimmedBounds(chars)
            return [Window(text: String(chars[s..<e]),
                           charStart: baseOffset + s,
                           charEnd: baseOffset + e)]
        }

        var windows: [Window] = []
        var start = leadDrop
        let step = max(1, targetChars - overlapChars)
        while start < n {
            var end = min(start + targetChars, n)
            // Try to extend/retract `end` to a nearby boundary (sentence end or
            // blank line) so we cut cleanly. Only search within the last 20% of
            // the window to avoid drastically shrinking it.
            if end < n {
                if let boundary = nearestBoundary(chars, around: end, slack: targetChars / 5) {
                    end = boundary
                }
            }
            let (s, e) = trimmedBounds(Array(chars[start..<end]))
            let absS = start + s
            let absE = start + e
            if absE > absS {
                let wText = String(chars[absS..<absE])
                if !wText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    windows.append(Window(text: wText,
                                          charStart: baseOffset + absS,
                                          charEnd: baseOffset + absE))
                }
            }
            if end >= n { break }
            // Advance; if the remaining tail is tiny, fold it into THIS window by
            // breaking (the next iteration would emit a sliver).
            let next = start + step
            if n - next < minTailChars { break }
            start = next
        }
        return windows
    }

    /// Find a clean break (after a sentence terminator + space, or a blank line)
    /// near `idx`, searching `±slack` chars. Prefers the closest paragraph break,
    /// then the closest sentence end; nil if none found (caller keeps the hard cut).
    private static func nearestBoundary(_ chars: [Char], around idx: Int, slack: Int) -> Int? {
        let lo = max(1, idx - slack)
        let hi = min(chars.count, idx + slack)
        var bestSentence: Int? = nil
        // Scan the window once; record the boundary closest to idx.
        var i = lo
        while i < hi {
            // Paragraph break: "\n\n" → break right after it (highest priority,
            // return immediately when within a tighter band around idx).
            if chars[i] == "\n", i + 1 < hi, chars[i + 1] == "\n" {
                return i + 2 <= chars.count ? i + 2 : chars.count
            }
            // Sentence end: . ! ? followed by whitespace.
            if (chars[i] == "." || chars[i] == "!" || chars[i] == "?"),
               i + 1 < chars.count, chars[i + 1] == " " || chars[i + 1] == "\n" {
                if bestSentence == nil || abs((i + 1) - idx) < abs(bestSentence! - idx) {
                    bestSentence = i + 1
                }
            }
            i += 1
        }
        return bestSentence
    }

    private typealias Char = Character

    /// Trim leading/trailing whitespace from a char slice, returning the inclusive
    /// start / exclusive end of the non-whitespace span. (Used to compute accurate
    /// char offsets without allocating intermediate strings for the bounds.)
    private static func trimmedBounds(_ chars: [Character]) -> (Int, Int) {
        var s = 0
        var e = chars.count
        let ws = CharacterSet.whitespacesAndNewlines
        while s < e, chars[s].unicodeScalars.allSatisfy({ ws.contains($0) }) { s += 1 }
        while e > s, chars[e - 1].unicodeScalars.allSatisfy({ ws.contains($0) }) { e -= 1 }
        return (s, e)
    }

    // ─── Stable ids + hashing ───────────────────────────────────────────────

    /// Stable chunk id: a SHA-256 of "notePath\u{1f}charStart\u{1f}contentHash",
    /// hex, truncated to 24 chars (96 bits — collision-safe at ≤50k chunks). The
    /// unit separator avoids any field-boundary ambiguity. Deterministic so the
    /// same region re-chunks to the same id (incremental diffing by id).
    static func stableChunkId(notePath: String, charStart: Int, contentHash: String) -> String {
        let key = "\(notePath)\u{1f}\(charStart)\u{1f}\(contentHash)"
        return String(sha256Hex(key).prefix(24))
    }

    /// SHA-256 of a string's UTF-8, lowercase hex. Used for both the per-chunk
    /// content hash and (by the indexer) the whole-file hash. swift-crypto's
    /// `SHA256` ships transitively via swift-transformers/Hub — no new dependency.
    static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of arbitrary bytes (the whole-file gate hash). Same encoding.
    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
