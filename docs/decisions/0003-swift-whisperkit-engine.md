# ADR-0003: Swift + WhisperKit engine (over Rust + whisper.cpp)

- **Date:** 2026-05-24
- **Status:** Accepted
- **Deciders:** Quynh Anh

## Context

The original Hark plan called for a Rust engine using `whisper-rs` (whisper.cpp Metal bindings), `screencapturekit-rs`, `cpal`, `ort` for Silero VAD, and `axum` for the WebSocket server. The driving reason was Windows-portability — a Rust shared library could be reused for a future Windows v2.

That driver disappeared with [ADR-0002](0002-macos-only-scope.md): Hark v1 is macOS-only, no Windows v2 on the roadmap. The engine-language question reopened from scratch.

On Apple Silicon in 2026, the most performant on-device transcription stack uses the **Apple Neural Engine (ANE)**, not just Metal. WhisperKit (Argmax) is the production-quality Swift framework that targets ANE via Core ML, and it ships large-v3-turbo as a Core ML bundle. ScreenCaptureKit and AVAudioEngine are first-party Apple APIs. FluidAudio is a Swift port of pyannote running on ANE. The entire native stack is Swift.

## Decision

**The Hark engine is a Swift binary.** Specifically:

- **ASR:** WhisperKit with `large-v3-turbo` Core ML bundle, running on Apple Neural Engine
- **System audio capture:** ScreenCaptureKit (CoreAudio Process Taps on macOS 14.4+)
- **Microphone capture:** AVAudioEngine
- **VAD:** Silero CoreML
- **Diarization:** FluidAudio (CoreML pyannote port)
- **WebSocket server:** Swift NIO (or Vapor — pick at Phase 3)
- **Translation (local mode):** NLLB-200 distilled, Core ML bundle

The engine runs as a **separate sidecar binary** managed by the Electron main process — not in-process Node, not in-process Python. UI ↔ Engine communication is the JSON WebSocket contract in `docs/design/08-websocket-api-contract.md`.

## Alternatives considered

- **Rust engine (whisper-rs, cpal, screencapturekit-rs, ort, axum).** The original choice.
  - ✅ Pros: Cross-platform-ready, no GC pauses, single static binary, the developer wanted to learn Rust.
  - ❌ Cons: Without Windows reuse, the portability premium evaporates. whisper.cpp Metal is ~30–40% slower than WhisperKit ANE on M-series. `screencapturekit-rs` and other macOS Rust bindings lag Apple's API releases. FFI tax on every macOS-specific call. 3–4 week Rust ramp from zero.
  - **Why rejected:** the deciding factor (Windows reuse) is gone. What's left is a slower, less idiomatic stack that takes longer to ship. Best tool for the job is Swift now.

- **Pure Python engine (`faster-whisper`, `pyannote.audio`, `python-sounddevice`).**
  - ✅ Pros: Fastest prototype path, the developer is more fluent in Python than Swift.
  - ❌ Cons: Python packaging on macOS is genuinely painful (PyInstaller, py2app, signing dynamic libraries, virtualenv hell). GIL pauses during long sessions. CTranslate2 backend is fast but still trails CoreML/ANE. Distribution: ~1.5 GB Python runtime bundled.
  - **Why rejected:** packaging + distribution pain compounds over the project lifetime. A single signed Swift binary is *dramatically* simpler to ship and maintain.

- **In-process Node (Electron main thread runs everything via WASM / N-API).**
  - ✅ Pros: One codebase, one process, no IPC.
  - ❌ Cons: WhisperKit has no JavaScript bindings. WASM Whisper is ~5x slower than native ANE. Electron's main process holding a 1.5 GB model in memory would block UI responsiveness during GC cycles. Crash isolation lost — engine OOM kills the UI.
  - **Why rejected:** can't use the ANE, defeats the entire reason for picking WhisperKit.

- **MLX-Whisper** (Apple's MLX framework).
  - ✅ Pros: Native Apple Silicon, very fast.
  - ❌ Cons: Apple-Silicon-only by design (we accepted that, OK), but the API is less mature than WhisperKit for streaming use cases. Argmax (WhisperKit) ships pre-packaged Core ML bundles; MLX requires conversion.
  - **Why rejected:** WhisperKit is more turnkey for our use case. Reconsider for v1.5 if WhisperKit hits a wall.

## Consequences

**Positive:**
- ANE-accelerated transcription — fastest path to <1.5s latency, <0.5 RTF on M-series.
- First-party Apple APIs across capture + transcription — no FFI lag against macOS updates.
- One language for engine + capture + diarization + translation — single mental model, single signed binary.
- Crash isolation: engine in its own process; UI survives engine OOM/crash and can offer a restart.
- Permission model is cleaner: ScreenCapture permission is granted to a stable signed Swift binary, not re-prompted on Electron updates.
- Code sign + notarize is a single Xcode operation (when/if we ship signed builds — see [ADR-0002](0002-macos-only-scope.md) re deferred signing).

**Negative / tradeoffs accepted:**
- Developer has zero Swift experience. ~2–3 week ramp accepted as the cost of using the right tool. Mitigated by the [`swift-macos-expert` agent](../../.claude/agents/swift-macos-expert.md).
- We're tied to Apple's pace on WhisperKit / Core ML evolution. If Argmax abandons WhisperKit, we'd need to fork or migrate.
- The IPC layer (WebSocket between engine and Electron UI) is real work — not the simplification of "one process" we'd get with in-process Node.

**Assumptions that must hold:**
- WhisperKit on ANE actually delivers the performance the benchmarks promise on real, noisy meeting audio with Thai-English code-switching. Phase 0 measures this directly.
- Argmax continues to maintain WhisperKit and ship updated Core ML bundles for new Whisper releases.
- macOS continues to expose ScreenCaptureKit + CoreAudio Process Taps for system audio capture. (Apple has not signaled deprecation; risk is low but real.)

## Open questions

- Swift NIO or Vapor for the WebSocket server? Decide at Phase 3 — Swift NIO is lower-level / lighter; Vapor is full-framework / more batteries-included. For a single-endpoint local-only WebSocket, Swift NIO is probably right.
- Should the speaker matcher (cosine similarity against `.speakers/*.json`) live in the engine (Swift) or in the Electron UI (TypeScript)? Currently planned in the engine; reconsider if performance is non-issue (it will be — embeddings are tiny vectors).

## References

- Enabled by [ADR-0002](0002-macos-only-scope.md) (macOS-only scope cut the Rust justification)
- Stack details in [handoff doc](../../meetingmind-handoff.md) — "Stack" section
- Performance targets: [vault/docs/qa/10-performance-benchmarks.md](file:///Users/quynhanhquach/Documents/vault/hark/docs/qa/10-performance-benchmarks.md)
- Phase 0 will validate this ADR's central performance assumption
