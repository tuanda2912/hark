// RagIndexer — the vault-RAG index coordinator (Phase 6 slice 4b, ADR-0032/0033).
//
// Owns the whole indexing lifecycle and keeps it OFF the live transcription path:
//   - cold build on open (index every `.md` once),
//   - an FSEvents watcher on the vault root (dedicated DispatchQueue, NOT the main
//     thread, NOT the audio thread) with a ~30 s debounce + content-hash gate so a
//     burst of saves coalesces into one re-index and unchanged files are skipped,
//   - a manual `rebuild()` entry point,
//   - graceful degradation: if the embedder isn't loaded, indexing is simply
//     skipped (logged once) — ONLY RAG is affected, capture/ASR are untouched.
//
// WHY a separate coordinator (not folded into RagIndex): the actor RagIndex is a
// pure store. The indexer holds the messy edges — the C FSEvents stream (which
// demands a DispatchQueue + a callback), the debounce timer, the chunker, and the
// embedder. It bridges those into the index actor via `await`. Java analogue: a
// `@Service` that wires a file-watcher + a batch job around a repository.
//
// Concurrency model:
//   FSEvents callback (DispatchQueue) → records dirty/deleted paths under a lock →
//   (re)arms a 30 s debounce timer on the SAME queue → on fire, hops into an async
//   `Task` that drains the dirty set and re-indexes each file via the embedder +
//   index actor. The lock guards ONLY the small dirty-set + timer state; all heavy
//   work (read → chunk → embed → store → persist) is async, off the FSEvents queue.
//
// Privacy (rules #2/#4): the vault is READ-ONLY to this type — it only reads `.md`
// files and writes the index to app-support (HarkPaths.indexDir()), never the
// vault. It NEVER logs chunk text — log lines are counts, paths' last components,
// and state only.

import Foundation
import CoreServices
import HarkCore

/// Index build state surfaced to the UI via `rag.index_status` (slice 4c consumes).
enum RagIndexState: String, Sendable {
    case idle
    case building
    case ready
}

/// What the indexer reports to its owner (the EngineSession) so the session can
/// emit the `rag.index_status` wire frame. `@Sendable` because it's called from the
/// indexer's async tasks. `total` is the cold-build denominator or nil for an
/// incremental single-file update.
typealias RagStatusSink = @Sendable (_ state: RagIndexState, _ indexedCount: Int, _ total: Int?) -> Void

@available(macOS 14.4, *)
actor RagIndexer {
    private let index: RagIndex
    private let embedder: TextEmbedder?
    private let vaultRoot: URL
    private let statusSink: RagStatusSink?

    /// FSEvents debounce (ADR-0033 ~30 s). A long debounce is deliberate: indexing
    /// is background, the user isn't waiting on it, and coalescing a save-storm
    /// (Obsidian sync writing many files) into one pass keeps the ANE off the live
    /// path. Configurable for tests via the initializer.
    private let debounceSeconds: Double

    /// Whether a build is currently running (so overlapping triggers coalesce into
    /// the in-flight build rather than racing the index actor).
    private var buildInFlight = false
    /// Set true when the embedder is nil and we've logged the degraded notice once.
    private var loggedNoEmbedder = false

    // ─── FSEvents + debounce state (guarded by `watchLock`) ──────────────────
    //
    // The FSEvents callback is a C function pointer; it can't capture `self`
    // directly as an actor. We bridge through a small `@unchecked Sendable` box
    // (FSWatcher) that holds a DispatchQueue + a weak hop back into this actor.
    private var watcher: FSWatcher?

    init(index: RagIndex,
         embedder: TextEmbedder?,
         vaultRoot: URL,
         debounceSeconds: Double = 30,
         statusSink: RagStatusSink? = nil) {
        self.index = index
        self.embedder = embedder
        self.vaultRoot = vaultRoot
        self.debounceSeconds = debounceSeconds
        self.statusSink = statusSink
    }

    // ─── Public lifecycle ─────────────────────────────────────────────────────

    /// Open the index: load from disk (rebuild-gated), then cold-build if needed,
    /// then start the FSEvents watcher. Safe to call once at daemon startup AFTER
    /// the embedder load attempt; degrades gracefully if the embedder is nil.
    func start() async {
        let outcome = await index.loadFromDisk()
        switch outcome {
        case .loaded(let count):
            eprint("rag: index loaded from disk (\(count) chunks)")
            statusSink?(.ready, count, nil)
            // Reconcile against the live vault: index new/changed files, drop notes
            // that vanished while the engine was down. Cheap when nothing changed
            // (every file hits the hash gate).
            await reconcile(reason: "startup reconcile")
        case .empty:
            eprint("rag: no index on disk — cold build")
            await fullBuild(reason: "cold build")
        case .rebuildRequired(let reason):
            eprint("rag: index rebuild required — \(reason)")
            await fullBuild(reason: "rebuild: \(reason)")
        }
        startWatcher()
    }

    /// Manual full rebuild entry point (e.g. a future Settings "Reindex vault"
    /// button via a wire frame). Drops the in-memory index and re-indexes the whole
    /// vault. No-op-degrades if the embedder is unavailable.
    func rebuild() async {
        await index.reset()
        await fullBuild(reason: "manual rebuild")
    }

    /// Stop the watcher (graceful shutdown). The index's last persisted state is on
    /// disk; nothing to flush here beyond stopping the stream.
    func stop() {
        watcher?.stop()
        watcher = nil
    }

    deinit {
        // If the indexer is dropped without an explicit stop() (e.g. a test letting
        // it go out of scope, or daemon shutdown), tear the FSEvents watcher down
        // here — otherwise its stream dangles into process teardown and SIGSEGVs.
        // FSWatcher.stop() is idempotent and balances its own self-retain, after
        // which the watcher deallocs cleanly.
        watcher?.stop()
    }

    // ─── Query (delegates to the index actor, then reads the vault) ─────────────

    /// Embed the query (`.query`), rank the top-K vectors, then RECOVER each hit's
    /// text LIVE from the vault at the stored char offsets. Throws
    /// `RagError.unavailable` when the embedder isn't loaded — the handler maps that
    /// to a `RAG_UNAVAILABLE` wire error. An empty index returns [] (not an error):
    /// "no results" is a valid answer.
    ///
    /// OFFSET-ONLY (decision 2026-06-03): the index never persists note text, so the
    /// snippet is sliced from the vault file at retrieve time. We over-fetch the
    /// ranked hits (k unchanged at the search layer) and skip any hit whose source is
    /// no longer trustworthy, so a skip never silently shrinks below an available
    /// honest result set:
    ///   - file MISSING (deleted since indexing) → skip the chunk.
    ///   - file CHANGED (live whole-file hash != the note's recorded hash) → skip:
    ///     the offsets may now point at moved text; dropping is honest, returning a
    ///     wrong slice is not. The 30 s watcher will re-index it shortly.
    /// The vault is READ-ONLY here (a single `Data(contentsOf:)` per distinct note,
    /// cached within the call; zero writes).
    func retrieve(query: String, k: Int) async throws -> [RagRetrievedChunk] {
        guard let embedder = embedder else { throw RagError.unavailable }
        let vector = try await embedder.embed(query, kind: .query)
        let hits = await index.search(queryVector: vector, k: k)
        return await recoverText(for: hits)
    }

    /// For each ranked hit: resolve `notePath` against the vault root (read-only),
    /// validate freshness via the whole-file hash gate, and slice `[charStart,
    /// charEnd)` Character-safe + clamped. Missing/changed files are skipped. File
    /// reads + hashes are memoized per note so K hits in the same note cost one read.
    private func recoverText(for hits: [RagSearchHit]) async -> [RagRetrievedChunk] {
        guard !hits.isEmpty else { return [] }

        // notePath → (file Characters, or nil if missing/stale/unreadable). A note
        // is read + hash-checked at most ONCE per retrieve.
        var fileCache: [String: [Character]?] = [:]
        var out: [RagRetrievedChunk] = []
        out.reserveCapacity(hits.count)

        for hit in hits {
            let note = hit.meta.notePath
            let chars: [Character]?
            if let cached = fileCache[note] {
                chars = cached
            } else {
                chars = await loadVaultNoteIfFresh(notePath: note)
                fileCache[note] = chars
            }
            guard let fileChars = chars else { continue }   // missing / changed / unreadable → skip

            guard let text = Self.slice(fileChars, from: hit.meta.charStart, to: hit.meta.charEnd) else {
                continue   // offsets out of any usable range → skip
            }
            out.append(RagRetrievedChunk(
                text: text,
                notePath: note,
                headingPath: hit.meta.headingPath,
                charStart: hit.meta.charStart,
                charEnd: hit.meta.charEnd,
                score: hit.score))
        }
        return out
    }

    /// Read a vault note (read-only) and return its Characters IF it's still fresh,
    /// else nil. Freshness gate: the live whole-file SHA-256 must equal the hash
    /// recorded for the note at index time (the same gate the watcher uses). Returns
    /// nil on: file missing, unreadable, non-UTF8, not in the index, or hash mismatch
    /// (edited since indexing). NEVER logs file contents.
    ///
    /// The note is split into `[Character]` (extended grapheme clusters) because the
    /// chunker measures its char offsets the same way (`Array(raw)` / `String.count`)
    /// — so a stored `charStart`/`charEnd` indexes the SAME unit here, and the slice
    /// recovers exactly the embedded window.
    private func loadVaultNoteIfFresh(notePath: String) async -> [Character]? {
        let url = vaultRoot.appendingPathComponent(notePath)
        guard let data = try? Data(contentsOf: url) else { return nil }   // missing / unreadable
        let liveHash = RagChunker.sha256Hex(data)
        guard let recorded = await index.fileContentHash(notePath: notePath),
              recorded == liveHash else {
            return nil   // changed since index (or no longer indexed) → skip
        }
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return Array(text)
    }

    /// Slice `[start, end)` from a note's Characters, clamped to the file length,
    /// returning nil if the resulting range is empty. Character-based to match the
    /// chunker's offset basis. Clamps defensively so out-of-range offsets (e.g. a
    /// last-millisecond edit that slipped the hash gate) can never crash or read out
    /// of bounds — at worst it returns a clamped window.
    static func slice(_ chars: [Character], from start: Int, to end: Int) -> String? {
        let n = chars.count
        let lo = max(0, min(start, n))
        let hi = max(lo, min(end, n))
        guard hi > lo else { return nil }
        return String(chars[lo..<hi])
    }

    enum RagError: Error { case unavailable }

    // ─── Build / reconcile ──────────────────────────────────────────────────

    /// Re-index every `.md` in the vault, pruning notes no longer present. Skips
    /// unchanged files via the per-file hash gate (so a rebuild after a small edit
    /// only re-embeds the changed files). Emits `building` status with a running
    /// count, `ready` at the end. Degrades to a logged no-op without an embedder.
    private func fullBuild(reason: String) async {
        guard embedder != nil else { degradeNoEmbedder(); return }
        guard !buildInFlight else { return }
        buildInFlight = true
        defer { buildInFlight = false }

        let files = enumerateMarkdown()
        let total = files.count
        eprint("rag: \(reason) — \(total) markdown file(s)")
        statusSink?(.building, 0, total)

        var done = 0
        var present = Set<String>()
        for url in files {
            let rel = relativePath(url)
            present.insert(rel)
            await indexOne(url: url, relativePath: rel)
            done += 1
            // Progress every few files (don't spam the UI; the throttle is coarse).
            if done % 5 == 0 || done == total {
                statusSink?(.building, done, total)
            }
        }

        // Prune notes that disappeared from the vault while we were down.
        let stale = await index.indexedNotePaths().subtracting(present)
        for rel in stale { await index.removeFile(notePath: rel) }
        if !stale.isEmpty { eprint("rag: pruned \(stale.count) stale note(s)") }

        await persistQuietly(reason: reason)
        let count = await index.chunkCount
        statusSink?(.ready, count, total)
        eprint("rag: \(reason) done — \(count) chunk(s) across \(present.count) note(s)")
    }

    /// Reconcile after a disk-loaded index: index new/changed files (hash-gated),
    /// prune vanished ones. Lighter than `fullBuild` only in that the loaded index
    /// is kept — the hash gate makes unchanged files free.
    private func reconcile(reason: String) async {
        guard embedder != nil else { degradeNoEmbedder(); return }
        guard !buildInFlight else { return }
        buildInFlight = true
        defer { buildInFlight = false }

        let files = enumerateMarkdown()
        var present = Set<String>()
        var changed = 0
        statusSink?(.building, 0, files.count)
        for url in files {
            let rel = relativePath(url)
            present.insert(rel)
            if await indexOne(url: url, relativePath: rel) { changed += 1 }
        }
        let stale = await index.indexedNotePaths().subtracting(present)
        for rel in stale { await index.removeFile(notePath: rel) }
        if changed > 0 || !stale.isEmpty {
            await persistQuietly(reason: reason)
            eprint("rag: \(reason) — \(changed) changed, \(stale.count) pruned")
        }
        let count = await index.chunkCount
        statusSink?(.ready, count, nil)
    }

    /// Index ONE file if its content changed (hash gate). Returns true if it was
    /// (re)indexed, false if skipped as unchanged or unreadable. Reads the file
    /// (vault read-only), hashes it, chunks it, embeds each chunk as `.passage`,
    /// and replaces the note's rows in the index. Best-effort per file: a single
    /// bad/unreadable file is logged-and-skipped, never aborting the build.
    @discardableResult
    private func indexOne(url: URL, relativePath rel: String) async -> Bool {
        guard let embedder = embedder else { return false }
        guard let data = try? Data(contentsOf: url) else { return false }
        let fileHash = RagChunker.sha256Hex(data)
        if await index.isFileUnchanged(notePath: rel, fileContentHash: fileHash) {
            return false   // hash gate: unchanged, skip
        }
        guard let raw = String(data: data, encoding: .utf8) else {
            // Non-UTF8 (e.g. a binary mis-named .md) — skip, but record the hash so
            // we don't retry it every event.
            await index.replaceFile(notePath: rel, fileContentHash: fileHash, chunks: [], vectors: [])
            return false
        }

        let (chunks, _) = RagChunker.chunk(notePath: rel, rawMarkdown: raw)
        var metas: [RagChunkMeta] = []
        var vectors: [[Float]] = []
        metas.reserveCapacity(chunks.count)
        vectors.reserveCapacity(chunks.count)
        for c in chunks {
            do {
                // The chunk text is embedded TRANSIENTLY here and then dropped — only
                // the vector + the offset-only meta are persisted (decision
                // 2026-06-03). The text is recovered live from the vault at retrieve
                // time via charStart/charEnd. `c.text` does not escape this loop.
                let v = try await embedder.embed(c.text, kind: .passage)
                metas.append(RagChunkMeta(
                    chunkId: c.chunkId, notePath: c.notePath, headingPath: c.headingPath,
                    charStart: c.charStart, charEnd: c.charEnd, contentHash: c.contentHash))
                vectors.append(v)
            } catch {
                // One chunk failed to embed (e.g. empty after trim) — skip it; the
                // rest of the note still indexes. Never logs the chunk text.
                continue
            }
        }
        await index.replaceFile(notePath: rel, fileContentHash: fileHash, chunks: metas, vectors: vectors)
        return true
    }

    private func persistQuietly(reason: String) async {
        do {
            try await index.persist()
        } catch {
            eprint("rag: index persist failed (\(type(of: error))); index kept in memory, will retry next build")
        }
    }

    private func degradeNoEmbedder() {
        if !loggedNoEmbedder {
            eprint("rag: embedder unavailable — vault RAG disabled this run (capture/transcription unaffected)")
            loggedNoEmbedder = true
        }
        statusSink?(.idle, 0, nil)
    }

    // ─── Incremental change handling (from the watcher) ────────────────────────

    /// Called (via the FSWatcher hop) after the debounce fires with the set of
    /// changed paths since the last drain. We re-stat each: a path that still
    /// exists + is `.md` is re-indexed (hash-gated); a path that's gone is removed.
    /// Coalesced: overlapping events for the same file collapse to one re-index.
    func handleDebouncedChanges(_ paths: Set<String>) async {
        guard embedder != nil else { degradeNoEmbedder(); return }
        guard !buildInFlight else {
            // A full build is running; it'll pick up everything. Drop these — the
            // build's enumeration is authoritative.
            return
        }
        buildInFlight = true
        defer { buildInFlight = false }

        var changed = 0
        var removed = 0
        let fm = FileManager.default
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard url.pathExtension.lowercased() == "md" else { continue }
            let rel = relativePath(url)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue {
                if await indexOne(url: url, relativePath: rel) { changed += 1 }
            } else {
                await index.removeFile(notePath: rel)
                removed += 1
            }
        }
        if changed > 0 || removed > 0 {
            await persistQuietly(reason: "incremental")
            let count = await index.chunkCount
            statusSink?(.ready, count, nil)
            eprint("rag: incremental — \(changed) changed, \(removed) removed (\(count) chunks)")
        }
    }

    // ─── FSEvents watcher ──────────────────────────────────────────────────────

    private func startWatcher() {
        guard watcher == nil else { return }
        // The watcher hops debounced changes back into THIS actor.
        let w = FSWatcher(path: vaultRoot.path, debounceSeconds: debounceSeconds) { [weak self] paths in
            Task { await self?.handleDebouncedChanges(paths) }
        }
        if w.start() {
            watcher = w
            eprint("rag: watching \(vaultRoot.path) (debounce \(Int(debounceSeconds))s)")
        } else {
            eprint("rag: FSEvents watcher failed to start; index will only update on rebuild")
        }
    }

    // ─── Vault enumeration + relative paths ─────────────────────────────────

    /// All `.md` files under the vault, EXCLUDING dot-directories (`.git`,
    /// `.speakers`, `.audio`, `.obsidian`) — those are vault internals, not notes.
    private func enumerateMarkdown() -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: vaultRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [URL] = []
        for case let url as URL in en {
            if url.pathExtension.lowercased() == "md" { out.append(url) }
        }
        return out.sorted { $0.path < $1.path }   // deterministic build order
    }

    /// Vault-relative POSIX path for a file URL (e.g. "meetings/2026-06-01.md").
    /// Falls back to the last component if the URL is somehow outside the vault.
    private func relativePath(_ url: URL) -> String {
        let root = vaultRoot.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return url.lastPathComponent
    }
}

// ─── FSWatcher — low-level FSEventStream bridge ───────────────────────────────
//
// A thin `@unchecked Sendable` box around a CoreServices FSEventStream. The C
// callback can't capture Swift context, so we pass `self` through the stream's
// `info` pointer (an Unmanaged<FSWatcher>) and bounce out to the Swift closure.
// All FSEvents work runs on a DEDICATED serial DispatchQueue — never the main
// queue, never the audio thread (the whole point: indexing stays off the live
// path). The debounce timer also lives on this queue, so the dirty-set is only
// touched from one queue and needs no extra lock.
//
// `@unchecked Sendable`: the mutable state (the dirty set + scheduled work item)
// is confined to `queue`; we never touch it from elsewhere. This is the same
// confinement discipline the project's other DispatchQueue bridges use.

@available(macOS 14.4, *)
final class FSWatcher: @unchecked Sendable {
    private let path: String
    private let debounceSeconds: Double
    private let onDebounced: (Set<String>) -> Void
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var dirty = Set<String>()
    private var pending: DispatchWorkItem?

    init(path: String, debounceSeconds: Double, onDebounced: @escaping (Set<String>) -> Void) {
        self.path = path
        self.debounceSeconds = debounceSeconds
        self.onDebounced = onDebounced
        self.queue = DispatchQueue(label: "com.hark.rag.fsevents")
    }

    /// Create + start the FSEventStream on the dedicated queue. Returns false if the
    /// stream couldn't be created (the indexer then relies on rebuild only).
    func start() -> Bool {
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        // Latency 1 s at the FSEvents layer (cheap coalescing) — our 30 s debounce
        // sits ON TOP of this. kFSEventStreamCreateFlagFileEvents gives per-file
        // paths (not just directory paths) so we know exactly which `.md` changed.
        // kFSEventStreamCreateFlagUseCFTypes is REQUIRED: without it the callback's
        // `eventPaths` is a raw `char **`, and `unsafeBitCast(... to: NSArray)` in
        // fsEventsCallback would read garbage → SIGSEGV the moment any file changes.
        // With it, eventPaths is a CFArray<CFString> the cast can read safely.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0,                      // FSEvents-layer latency (seconds)
            flags
        ) else {
            Unmanaged<FSWatcher>.fromOpaque(info).release()
            return false
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            Unmanaged<FSWatcher>.fromOpaque(info).release()
            return false
        }
        return true
    }

    func stop() {
        queue.sync {
            pending?.cancel()
            pending = nil
            if let stream = stream {
                FSEventStreamStop(stream)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
                // Balance start()'s `passRetained(self)`. The C stream context held
                // the only extra +1 (context `release: nil`), so once the stream is
                // invalidated we MUST release it — otherwise `self` leaks and its
                // FSEventStream is never fully torn down, which SIGSEGVs at process
                // teardown. Guarded by `if let stream` so it runs exactly once.
                Unmanaged.passUnretained(self).release()
            }
        }
    }

    /// Called from the C callback (already on `queue`). Records the changed paths
    /// and (re)arms the debounce timer — each new event pushes the fire time out, so
    /// a burst of saves fires ONCE, `debounceSeconds` after the last event.
    fileprivate func recordChanges(_ paths: [String]) {
        for p in paths { dirty.insert(p) }
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let batch = self.dirty
            self.dirty.removeAll(keepingCapacity: true)
            self.pending = nil
            guard !batch.isEmpty else { return }
            self.onDebounced(batch)
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounceSeconds, execute: work)
    }
}

/// FSEventStream C callback. Recovers the `FSWatcher` from `info` and forwards the
/// changed paths. Runs on the watcher's dispatch queue.
@available(macOS 14.4, *)
private func fsEventsCallback(
    _ stream: ConstFSEventStreamRef,
    _ info: UnsafeMutableRawPointer?,
    _ numEvents: Int,
    _ eventPaths: UnsafeMutableRawPointer,
    _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info = info else { return }
    let watcher = Unmanaged<FSWatcher>.fromOpaque(info).takeUnretainedValue()
    guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }
    watcher.recordChanges(paths)
}
