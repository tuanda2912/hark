# ADR-0006: Phase 2 capture architecture

- **Date:** 2026-05-26
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Phase 2 builds `hark-capture`: a CLI that records system audio (the meeting app's output) and microphone input into a single WAV file the Phase 1 engine can transcribe. This is the first phase where macOS permission prompts appear and the first phase whose architectural choices pin user-visible behavior (supported macOS versions, perms UX, mix output shape).

Three coupled questions had to be answered together before code started:

1. **Which system-audio capture API**, and therefore **what macOS floor**?
2. **How are mic and system audio combined** in the output WAV?
3. **How does the CLI handle missing TCC permissions** on first run?

They're documented together because they share one context (Phase 2 capture pipeline) and inform the same data flow. Future phases may revisit any of them independently; if so, supersede with a focused ADR.

This ADR builds on [ADR-0002](0002-macos-only-scope.md) (macOS-only scope) and [ADR-0003](0003-swift-whisperkit-engine.md) (Swift engine), and is unblocked by [ADR-0005](0005-phase-0-rtf-validated.md) (Phase 0 RTF passed, so the stack is committed).

## Decision

1. **macOS floor: 14.4+.** Use **Core Audio Process Taps** for system-audio capture.
2. **Mix output: 16 kHz mono PCM s16le WAV**, produced by summing resampled mic + system audio and applying a `tanh(x * 0.9)` soft-clip before Int16 conversion.
3. **Permissions: fail-fast.** On startup, preflight Microphone and Screen Recording TCC status. On any miss, print the exact System Settings path to grant access and exit code 3. No modal-style "wait for the user to grant" loop.

## Decision 1 — System-audio API and macOS floor

### Chosen
**Core Audio Process Taps** (Apple's `CATapDescription` + aggregate-device API, macOS 14.4+). The tap is attached to the default output device, captures the system's mixed audio stream, and delivers `AudioBufferList` chunks via a render callback.

### Alternatives considered

- **ScreenCaptureKit audio-only stream** (macOS 13+).
  - ✅ Pros: lower OS floor; one fewer Core Audio concept to learn; same API path that `SCStream` already uses for video.
  - ❌ Cons: SCK is structurally a *display capture* framework — using it for audio-only means configuring a hidden video stream, paying the SCK lifecycle cost, and accepting that audio comes through a content-capture API designed for screenshots. The mental model fights the use case.
  - **Why rejected:** The "audio inside a display-capture framework" shape is a smell. Process Taps are the API Apple built specifically for system-audio capture; using the right API is worth a 14.4 floor on a solo-dev pre-v1 product.

- **Prototype both, choose later.**
  - ✅ Pros: empirical comparison.
  - ❌ Cons: costs ~1 extra day for a decision whose tradeoff is already legible from the API surfaces.
  - **Why rejected:** Not enough uncertainty to justify the spike. If Process Taps turn out to require entitlements we can't get without a Developer account (deferred per the 2026-05-24 resolution in the handoff doc), we fall back to SCK and amend this ADR.

- **whisper.cpp-style virtual audio device (BlackHole, etc.).**
  - ❌ Cons: requires the user to install a kernel extension or audio loopback driver, then route their output through it. Violates the "just works after grant" UX bar.
  - **Why rejected:** Hard no on third-party kexts in a privacy-marketed product.

### Consequences

**Positive:**
- Cleaner code: Process Taps deliver audio directly, no fake video stream.
- Future-proof: Apple's stated direction for system-audio capture.
- Per-process tap is available if we ever want "only capture Zoom's audio" — a natural Phase 5+ extension.

**Tradeoffs accepted:**
- Cuts off macOS 13 (Ventura) users. Hark is solo-dev, no public users yet; the dev's own Mac runs 26.x. Worth the floor bump.
- Process Taps are newer and less StackOverflow'd. Apple's headers + WWDC 2024 session 10160 are the primary reference.

**Must remain true:**
- Process Tap creation is allowed for an unsigned binary built from source on the dev's own machine. If a future macOS enforces entitlements we can't grant ourselves, revisit. (Mitigation if so: fall back to SCK audio-only, supersede this ADR section.)

## Decision 2 — Mix output shape

### Chosen
Both sources are resampled to **16 kHz mono Float32**, time-aligned in a small ring buffer, summed sample-wise, soft-clipped via `tanh(x * 0.9)`, converted to Int16, and written as a single WAV (RIFF / `fmt ` / `data`, PCM s16le).

### Alternatives considered

- **Two-channel WAV** (L = mic, R = system audio).
  - ✅ Pros: preserves source separation for free; diarization (Phase 5) could exploit the channel split as a strong prior.
  - ❌ Cons: `hark-engine` currently expects mono input; we'd either downmix at read time (negating the win) or add a stereo ingest path (scope creep into Phase 1).
  - **Why rejected:** Phase 5 will use FluidAudio's voice-embedding diarization, which doesn't need pre-separated channels. The L/R trick would mostly help a *non-FluidAudio* diarizer we don't plan to build.

- **Two separate WAV files** (`session-mic.wav` + `session-system.wav`).
  - ✅ Pros: cleanest separation; trivial to inspect either stream alone.
  - ❌ Cons: doubles disk; the engine doesn't ingest pairs; the downstream Phase 3 streaming server would have to mix anyway, just later.
  - **Why rejected:** Pushes mixing complexity downstream without buying anything Phase 2 needs.

- **No soft-clip, hard clip at ±1.0.**
  - ❌ Cons: when both mic and system audio peak simultaneously (likely during loud meeting moments), hard clipping introduces audible distortion and tanks Whisper accuracy on that window.
  - **Why rejected:** soft-clip costs one `tanh` per sample — negligible at 16 kHz.

### Consequences

**Positive:**
- Drop-in compatible with the existing `hark-engine` mono path.
- One file per recording — simple to attach to vault entries, simple to re-run, simple to share.
- The summed/limited file is what the human hears anyway if they replay it.

**Tradeoffs accepted:**
- Loses source separation. If we ever want to diarize using channel identity rather than voice embeddings, we'd need to revisit. FluidAudio's embedding-based approach (per [ADR-0003](0003-swift-whisperkit-engine.md)) doesn't depend on it.
- A `tanh`-based limiter without look-ahead can mildly soften transients. Acceptable for speech; would be wrong for music.
- Echo loops (laptop speakers picked up by laptop mic) become indistinguishable from real overlap. Documented as a known limitation — users should wear headphones during meetings.

**Must remain true:**
- The engine's input contract stays "mono 16 kHz PCM s16le". If Phase 3+ adds stereo support, this decision should be revisited.

## Decision 3 — Permission UX

### Chosen
On startup, `hark-capture` checks:

1. **Microphone:** `AVCaptureDevice.authorizationStatus(for: .audio)` — must be `.authorized`.
2. **Screen Recording:** `CGPreflightScreenCaptureAccess()` — required for Process Taps in addition to mic.

If either is missing, print a message naming the exact missing permission and the exact System Settings pane, then exit with code 3 (distinct from generic error code 1). A `--check-permissions` subcommand performs the check without starting capture; useful for setup scripts.

### Alternatives considered

- **Trigger the prompt and wait.** Start capture, let the system dialog appear, block until granted/denied.
  - ✅ Pros: more discoverable for a first-time user.
  - ❌ Cons: couples a CLI's lifecycle to a modal dialog; awful for scripting and CI; the system prompt only fires once per binary identity, so subsequent runs after a "deny" silently fail with no actionable error.
  - **Why rejected:** CLIs that block on GUI dialogs are hostile to the rest of the toolchain. The UI app (Phase 4) is the right place for a guided-grant flow.

- **Skip preflight, let the API fail mid-capture.**
  - ❌ Cons: opaque failure modes ("AudioHardwareError -1" with no context); the partial-WAV-then-crash path corrupts output.
  - **Why rejected:** Worst of both worlds.

### Consequences

**Positive:**
- Predictable, scriptable, debuggable: `hark-capture --check-permissions; echo $?` is enough to gate a shell script.
- Clear error messages reduce support burden later.
- The Phase 4 Electron app can wrap this same binary and surface a guided onboarding flow on top of the same exit code.

**Tradeoffs accepted:**
- First-time users see an error before they see a recording. Mitigated by clear copy and the `--check-permissions` subcommand.

**Must remain true:**
- TCC pre-check APIs continue to exist for unsigned/dev builds. (They do today; Apple has only ever tightened post-grant, not pre-flight.)

## Open questions

- **Process Tap stability under sample-rate changes** (user plugs in / unplugs an audio interface mid-capture). Will instrument in Phase 2 and decide whether to surface as warning vs. fatal.
- **Mic device selection** — Phase 2 uses the system default input. A `--mic-device <name>` flag may land in Phase 7 hardening, not now.
- **Echo cancellation.** Out of scope; documented as a known limitation. May re-evaluate if Phase 4 dogfooding shows it hurts WER badly enough.

## References

- WWDC 2024 session 10160 — "What's new in Core Audio" (Process Taps intro)
- Apple developer docs: `CATapDescription`, `AudioHardwareCreateProcessTap`
- Builds on: [ADR-0002](0002-macos-only-scope.md), [ADR-0003](0003-swift-whisperkit-engine.md), [ADR-0005](0005-phase-0-rtf-validated.md)
- Phase 2 scope: [STATUS.md](../../STATUS.md), [meetingmind-handoff.md](../../meetingmind-handoff.md)
