# ADR-0007: Actively request TCC permissions on first run

- **Date:** 2026-05-26
- **Status:** Accepted
- **Supersedes:** [ADR-0006](0006-phase-2-capture-architecture.md) §3 ("Permission UX") only — the macOS-floor + Process Tap + mix-shape sections of ADR-0006 are unchanged.
- **Deciders:** Quynh Anh

## Context

ADR-0006 §3 chose a fail-fast preflight: `hark-capture` reads the TCC state with `AVCaptureDevice.authorizationStatus(for: .audio)` and `CGPreflightScreenCaptureAccess()`, prints a System-Settings hint, and exits 3 if anything is missing. The reasoning was that CLIs that block on GUI dialogs are hostile to scripting.

In practice, on first run, this produces a surprising experience: the user runs `hark-capture` once, sees only an error message, and has no way to grant the permission *through the app* the way every other macOS app behaves. macOS only fires the "App X wants to access your microphone" dialog when an app **requests** the permission (`AVCaptureDevice.requestAccess` / `CGRequestScreenCaptureAccess`) — never as a side effect of a preflight read.

The Phase 2 dogfooding session surfaced this immediately: the developer expected `hark-capture` to behave like other macOS apps and prompt on first launch.

## Decision

On startup, `hark-capture` **actively requests** any missing permissions instead of only reading TCC state. Concretely:

1. Read current state with the same preflight calls. If both already granted → continue.
2. If microphone is missing → call `AVCaptureDevice.requestAccess(for: .audio)`. This shows the system dialog and resolves with the user's choice.
3. If screen recording is missing → call `CGRequestScreenCaptureAccess()`. This shows the system dialog and returns immediately.
4. After requesting, re-check. If still missing (the user clicked Deny, or screen-recording grants require a relaunch), print the System-Settings hint and exit 3.

`--check-permissions` keeps the pure-preflight semantics — it must never trigger a prompt, because scripts call it.

## Alternatives considered

- **Keep fail-fast preflight** (the prior decision).
  - ❌ Cons: no first-run prompt, inconsistent with macOS app norms, every user has to read terminal output to understand what to do.
  - **Why rejected:** The "CLI shouldn't block on GUI dialogs" principle that motivated this is sound for *scripting* contexts, but the primary `hark-capture` user is the developer themselves running it interactively. The `--check-permissions` subcommand still satisfies the scripting case.

- **Just call the capture APIs and let them trigger prompts naturally** (e.g. `AVAudioEngine.start()` fires the mic prompt as a side effect).
  - ❌ Cons: opaque failure modes if the user denies — capture fails with `AudioHardwareError -1` instead of a clear message; partial WAVs get written before the failure surfaces.
  - **Why rejected:** Worst of both worlds — same UX as today but with worse error reporting.

- **Two-pass: prompt, then loop until granted.**
  - ❌ Cons: screen-recording grants don't take effect until the parent terminal app relaunches (TCC inherits parent process trust). A polling loop would spin forever; a long-sleep loop is fragile.
  - **Why rejected:** Re-run-after-grant is the only reliable pattern for screen recording. Documented as the second-run path.

## Consequences

**Positive:**
- First-run UX matches every other macOS app: system dialog appears, user clicks Allow, recording proceeds (mic) or user re-runs (screen recording).
- Failure messages remain clear because the post-request re-check still runs.
- `--check-permissions` keeps its pure semantics for scripts and CI.

**Tradeoffs accepted:**
- **Attribution caveat:** for an unsigned dev-built CLI, the TCC dialog attributes to the *parent terminal* (Terminal / iTerm / Ghostty / VS Code's integrated shell), not to `hark-capture`. The grant is recorded against the terminal's signing identity. This is intrinsic to macOS TCC and how it identifies callers; the only fix is to ship a signed `.app` bundle with its own identity. Apple Developer account is deferred per the 2026-05-24 resolution in the handoff doc, so we accept this for now.
- **Screen recording requires a relaunch** after first grant. The CLI prints a message saying so and exits non-zero with a re-run hint.
- The active request now blocks briefly on a dialog. Acceptable because it only happens at most once per binary lifetime per permission.

**Must remain true:**
- `AVCaptureDevice.requestAccess` and `CGRequestScreenCaptureAccess` continue to be the canonical TCC request APIs. Both have been stable since macOS 10.14 (mic) and 10.15 (screen capture); no signal Apple intends to deprecate either.

## Open questions

- **Terminal attribution polish.** When we eventually code-sign an app bundle (post-v1, when Apple Developer account is back in scope), the CLI may be embedded inside the `.app` and inherit its TCC identity. That's the moment to revisit attribution.
- **VS Code / Cursor integrated terminals** sometimes inherit a different TCC identity than the host editor. Worth a manual test row when we write the Phase 7 onboarding doc.

## References

- ADR-0006 §3 (superseded by this ADR; the rest of ADR-0006 stands)
- Apple TCC framework: `AVCaptureDevice.requestAccess`, `CGRequestScreenCaptureAccess`
- Phase 2 dogfooding feedback: 2026-05-26 conversation flagged the missing prompt
