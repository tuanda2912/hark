# ADR-0008: Phase 3 streaming architecture (harkd, Swift NIO, in-process capture, VAD-gated windowing)

- **Date:** 2026-05-27
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Phase 3 turns Hark's batch pipeline into a live one. The deliverable is a long-lived process that captures audio, runs Voice Activity Detection (VAD), feeds a sliding-window transcriber, and streams JSON segments over a localhost WebSocket. The Electron UI (Phase 4) will eventually spawn this process and consume its stream.

Four coupled decisions had to be answered together before code started — they share one context (the live pipeline) and inform the same data flow:

1. **Which WebSocket server library?** Open since [ADR-0003](0003-swift-whisperkit-engine.md).
2. **How does the engine consume captured audio?** Three options: in-process library, Unix socket between two binaries, or rolling chunk files.
3. **How is VAD integrated, and how is the sliding window driven?**
4. **What is the binary called?** Affects long-term mental model (CLI tool vs daemon).

Documenting together because they're tightly coupled. Future phases may revisit any independently; supersede with focused ADRs if so.

Builds on [ADR-0003](0003-swift-whisperkit-engine.md) (Swift engine), [ADR-0006](0006-phase-2-capture-architecture.md) (Phase 2 capture pipeline), and the WebSocket API contract in `vault/docs/design/08-websocket-api-contract.md`.

## Decision

1. **WebSocket server: Swift NIO** (`swift-nio`, `swift-nio-extras`) — direct, no HTTP framework overhead. Binds to ephemeral loopback port, writes the chosen port to `~/Library/Application Support/Hark/engine.port`.
2. **Capture data flow: in-process shared library.** `harkd` imports `HarkCapture` and `HarkCore`. No IPC between capture and transcription. `hark-capture` CLI stays as a separate batch tool.
3. **VAD: Silero CoreML, gating before WhisperKit.** Audio frames pass through Silero VAD; only frames inside detected speech regions accumulate into the sliding window. Production window setting: **30s window, 5s hop**, drop oldest unprocessed segment if RTF > 1.
4. **Binary name: `harkd`** — Unix daemon convention. This is the long-lived process the Electron UI will spawn in Phase 4. `hark-capture` and `hark-engine` remain as batch CLIs for testing.

## Decision 1 — WebSocket server: Swift NIO

### Chosen
**Swift NIO + NIOWebSocket** (`apple/swift-nio` and `apple/swift-nio-extras`). One channel handler chain for the WS upgrade + frame routing. ~150–250 lines of focused code.

### Alternatives considered

- **Vapor.**
  - ✅ Pros: turnkey WebSocket support, batteries-included.
  - ❌ Cons: drags in routing, middleware, environment loading, Leaf templating, Fluent ORM hooks — none of which we need for a single-endpoint localhost WS. ~15 transitive dependencies vs NIO's 3. Spin-up time matters because `harkd` is meant to start fast when the UI launches it.
  - **Why rejected:** the entire framework's value prop is "I'm building a web app." We're building a local sidecar. Wrong tool.

- **Foundation `URLSessionWebSocketTask`.**
  - ❌ Cons: client-only API. There is no Foundation-native WS server.
  - **Why rejected:** doesn't exist.

- **Third-party Starscream, etc.**
  - ❌ Cons: also client-only. NIO is the only sensible server-side option in the Swift ecosystem.

### Consequences

**Positive:**
- Direct control over the upgrade handshake, ping/pong, close codes, backpressure — all things we'll want to tune for the long-lived live-caption case.
- NIO is an Apple-maintained project, stable, well-documented.
- The chosen pieces (`NIOPosix`, `NIOHTTP1`, `NIOWebSocket`) are the minimum surface needed.

**Tradeoffs accepted:**
- More boilerplate than Vapor for the trivial first endpoint. Acceptable — the boilerplate is one-time and the trivial endpoint will accrete real complexity (heartbeats, message ack/error envelope, protocol-mismatch handling).

## Decision 2 — In-process shared library

### Chosen
`harkd` is a single Swift executable target that imports `HarkCapture` and `HarkCore` as libraries and runs the full pipeline (capture → VAD → window → WhisperKit → WS emit) in one process.

### Alternatives considered

- **Unix domain socket** between `hark-capture` (producer) and `hark-engine-stream` (consumer).
  - ✅ Pros: clean process separation; engine crash doesn't kill capture; pipeable.
  - ❌ Cons: IPC marshaling overhead (16 kHz mono Float32 → bytes → kernel → bytes → Float32), capture and engine have *correlated* lifecycles (both stop on user "stop recording"), and Phase 4's Electron UI is the natural place to put the process boundary (UI ↔ harkd).
  - **Why rejected:** two-process architecture inside the engine adds complexity without buying isolation that matters. The real isolation boundary is engine ↔ UI, which is already the WS contract.

- **Rolling chunk files** — `hark-capture` writes 5-second WAV chunks to a directory; `harkd` tails the directory.
  - ❌ Cons: disk I/O on the hot path, file rotation/cleanup logic, FSEvents lag, race conditions on chunk completion.
  - **Why rejected:** disk is in the critical path for nothing useful. Debuggability win is minor.

- **Refactor `hark-capture` CLI into `harkd` only** (delete the standalone CLI).
  - ❌ Cons: loses the batch-test path that Phase 2 just smoke-tested.
  - **Why rejected:** `hark-capture` is cheap to keep and useful for debugging audio capture in isolation. Both binaries import the same library.

### Consequences

**Positive:**
- Zero IPC tax on the hot path. Captured float buffers flow directly to VAD to WhisperKit.
- Single backpressure domain — if WhisperKit falls behind, the same actor can drop oldest audio without IPC negotiation.
- `HarkCapture` library remains pure (no CLI dependencies); the CLI and `harkd` are thin orchestrators.

**Tradeoffs accepted:**
- A `harkd` crash takes capture with it. Mitigated by Phase 4's UI restart logic (`meta.hello` reconnect, partial transcript preserved on disk). For Phase 3 itself: not a concern, the dev is the only consumer.

## Decision 3 — VAD-gated sliding window

### Chosen
**Silero VAD via CoreML**, applied to the resampled 16 kHz mono Float32 stream from `HarkCapture` before any WhisperKit call. Audio frames are tagged speech/silence; only speech frames accumulate into the sliding-window buffer. Window: **30s with 5s hop**, matching the production setting validated in Phase 0.

Sliding-window reconciliation: each new 5s hop produces a fresh 30s window. WhisperKit transcribes it. Segments in the *new* 5s tail are emitted as `segment.partial` first (so the UI sees live captions), then converted to `segment.final` when the next window confirms them. Segments in the older 25s are re-transcribed; if they change, the engine emits a *replacement* `segment.partial` with the same `utterance_id` so the UI can update in place.

Backpressure: if WhisperKit's wall-clock time per window exceeds the 5s hop budget (RTF > 1), drop the oldest unprocessed window and emit a `warning` with code `rtf_high`. Never queue unbounded.

### Alternatives considered

- **No VAD, always transcribe.**
  - ❌ Cons: wastes ANE cycles on silence (which Whisper would hallucinate captions for — well-documented behavior). Burns battery, fills the warning channel with low-confidence segments.
  - **Why rejected:** Silero VAD is cheap (<5ms per frame on ANE) and gates against a real problem.

- **VAD as post-processing** (transcribe everything, filter low-confidence later).
  - ❌ Cons: doesn't fix the hallucination on silence — Whisper *generates* text for silent input, post-filtering by confidence catches some but not all. Also wastes the compute.
  - **Why rejected:** same compute cost as no-VAD, weaker quality.

- **VAD inside WhisperKit's own segmenter.**
  - WhisperKit has built-in segmentation but it's chunk-level and not VAD-style. Doesn't replace what Silero provides at the input stage.
  - **Why rejected:** different layer of the pipeline; not a substitute.

### Consequences

**Positive:**
- ANE cycles spent only on speech. Important for sustained-session battery life and thermals.
- Cleaner UX: live captions don't flicker with hallucinated text during silence.
- Backpressure rule (drop oldest if RTF > 1) becomes defensive — Phase 0 showed RTF 0.075, we have ~6× margin, the rule should fire ~never on M-series.

**Tradeoffs accepted:**
- Silero CoreML model is a new dependency (~2 MB). Argmax does not bundle it with WhisperKit; we source it ourselves (HuggingFace `snakers4/silero-vad` has a community CoreML conversion, or convert from the ONNX original). Documented in the engine README.
- Silero is open-source (MIT). No license complications.

**Must remain true:**
- Silero VAD's speech/silence classification stays accurate at 16 kHz mono Float32 — the format our capture pipeline produces. (Silero's training distribution matches.)

## Decision 4 — Binary name: `harkd`

### Chosen
**`harkd`** — Unix daemon convention. Lowercase, no separator, trailing `d` signals "this is a long-lived process you start and forget about."

### Alternatives considered

- **`hark-engine-stream`** — parallel to `hark-engine` (batch).
  - ❌ Cons: cumbersome to type; "engine-stream" suggests it's an alternative engine when it's actually the *real* engine and `hark-engine` is the test tool.

- **`hark-server`** — descriptive.
  - ❌ Cons: "server" implies multi-client / network surface. This is a single-client localhost WS sidecar. Misleads expectations.

- **`hark`** — bare.
  - ❌ Cons: conflicts with the project's brand name as the user-facing app (the Electron UI is "Hark"). Reserving the bare name for the app shipped to users.

### Consequences

- **`harkd`** is what Phase 4's Electron main process spawns. Its lifecycle is tied to the UI session. Future ADR (Phase 4) will document the spawn / supervise / restart pattern.

## Open questions

1. **Silero CoreML model source.** Need to pin a specific CoreML bundle URL + checksum in the `harkd` README. The agent doing Phase 3 should research and document. If no canonical CoreML conversion exists, we either (a) ship the ONNX model and use ONNX Runtime Swift bindings, or (b) write a small `coremltools` conversion script. Both are acceptable; choose at implementation time.
2. **Engine port file format.** `engine.port` could be plain integer or JSON. Plain integer is simpler; JSON allows future fields (pid, build version) without format change. Lean toward JSON for forward compat.
3. **Replacement-segment ID semantics.** The UI contract says `segment.partial` with the same `utterance_id` replaces an earlier partial. Phase 1's batch engine generates fresh UUIDs per segment — Phase 3 must reuse UUIDs across window boundaries when a segment is being refined. Implementation detail, not an architectural question.

## References

- WebSocket message catalog: `vault/docs/design/08-websocket-api-contract.md`
- Phase 2 capture pipeline: [ADR-0006](0006-phase-2-capture-architecture.md), [ADR-0007](0007-active-permission-request.md)
- Performance budget: `vault/docs/qa/10-performance-benchmarks.md`
- WhisperKit + ANE validation: [ADR-0005](0005-phase-0-rtf-validated.md)
