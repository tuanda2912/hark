# ADR-0002: macOS-only scope for v1 (drop Windows / Linux / mobile)

- **Date:** 2026-05-24
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

The original Hark plan included a future Windows v2 reusing the engine as a shared library, with iOS/Android as long-tail ambitions. That plan shaped the entire stack: a **Rust engine** was chosen specifically because it compiles to a portable shared library, the data model was abstracted for multi-platform reuse, and library choices avoided Apple-only tools (no WhisperKit, no Core ML pyannote ports).

Reality check: cross-platform shipping is a force multiplier of complexity, not a feature. The developer is one person doing this in evenings and weekends. Every cross-platform abstraction costs design time, build time, test time, and dependency-choice freedom. Meanwhile, the primary user (the developer themselves) is on macOS, the target persona's pain (compliance-bound knowledge workers) is heavily Mac-skewed in 2026, and Apple Silicon has reached the point where the on-device ASR story is genuinely production-grade.

## Decision

**Hark v1 is macOS-only.** Windows, Linux, iOS, and Android are out of scope — not "deferred to v2," not "we'll think about it later." Out. Removed from the roadmap, removed from architecture trade-offs, removed from library-selection criteria.

Apple Silicon (M-series) is the target hardware. Intel Macs are refused at install with a clear error message — we won't pretend to support hardware we won't test on.

## Alternatives considered

- **Keep the original cross-platform plan (Rust engine, Mac v1 → Windows v2).**
  - ✅ Pros: Bigger eventual market. Single engine codebase to maintain. Lets the developer learn Rust as a side benefit.
  - ❌ Cons: Rust engine adds ~3–4 weeks of language ramp. Forces avoiding Apple's best tools (WhisperKit on ANE is ~30–40% faster than whisper.cpp Metal on M-series; ScreenCaptureKit + AVAudioEngine are first-party APIs with no FFI tax). Adds complexity throughout the stack just to preserve future optionality that may never be exercised.
  - **Why rejected:** "Future portability" is a hypothesis, not a requirement. Building for it costs concrete time today against a benefit that's speculative and 6+ months away. The deciding factor: the primary user is on a Mac, the moment of value is daily Mac use, and a Windows v2 would be a *different product* (different audio APIs, different compliance environment, different UX expectations) — sharing an engine wouldn't save as much as we'd hoped.

- **Web app (PWA) with on-device WASM transcription.**
  - ✅ Pros: One codebase, runs everywhere with a browser.
  - ❌ Cons: WASM Whisper performance is ~5x slower than native ANE. Browser audio capture APIs can't capture system audio (only mic). Background tabs get throttled. The trust story is harder ("trust your browser" is harder than "trust this signed binary"). UI quirks across Chromium/Safari/Firefox.
  - **Why rejected:** can't capture system audio, which kills the primary use case (transcribing Zoom/Teams meetings).

- **iOS / iPadOS first.**
  - ✅ Pros: Apple developer experience is strong, distribution via App Store is straightforward.
  - ❌ Cons: iOS doesn't expose system audio capture for arbitrary apps (no equivalent to ScreenCaptureKit's system audio path). Meeting audio is locked inside Zoom/Teams. Hardware-keyboard hotkey UX is poor.
  - **Why rejected:** mobile is not where the work meetings happen.

## Consequences

**Positive:**
- Free to pick the best Apple-platform tools: WhisperKit on ANE, ScreenCaptureKit, AVAudioEngine, FluidAudio (CoreML pyannote), Swift NIO. See [ADR-0003](0003-swift-whisperkit-engine.md).
- Removes ~3–4 weeks of Rust ramp from the timeline (6–8 weeks → 5–7 weeks).
- Removes the entire cross-platform abstraction layer from the architecture.
- Simpler code signing, simpler dependency management, simpler test matrix.
- A single, polished platform implementation beats two mediocre ones.

**Negative / tradeoffs accepted:**
- Forecloses the Windows/Linux user segments — likely 70%+ of the addressable market if Hark ever goes commercial.
- Developer loses the "learn Rust" side benefit. Swift becomes the new learning project.
- If a Windows user begs for the product, the answer is "no" with no transition path. Accepted.

**Assumptions that must hold:**
- The primary user (compliance-bound knowledge worker) skews Mac. If field testing shows otherwise, this whole ADR needs revisiting.
- macOS continues to support local-first patterns (no future OS lockdown that forces transcription through Apple's cloud services).
- WhisperKit + ANE performance stays competitive with cloud ASR. If Apple stops investing in on-device ML, the trust differentiator weakens.

## Open questions

- If v1 succeeds, is the next move (a) a Linux port for the privacy-conscious dev crowd, (b) an iOS companion for note review only, or (c) a polished v1.5 Mac-native rewrite? Defer until we have v1 dogfood data.

## References

- [Project handoff doc](../../meetingmind-handoff.md) — "Goals" section
- Supersedes the implicit "cross-platform via Rust engine" assumption in the original project draft
- Enables [ADR-0003](0003-swift-whisperkit-engine.md) (Swift engine pivot) and [ADR-0001](0001-electron-over-tauri.md) (Electron over Tauri)
