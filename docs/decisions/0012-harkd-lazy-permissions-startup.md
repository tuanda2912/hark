# ADR-0012: harkd defers capture permissions and serves before loading the model

- **Date:** 2026-05-31
- **Status:** Accepted (amends [ADR-0006](0006-phase-2-capture-architecture.md) §Decision 3 for the daemon)
- **Deciders:** Quynh Anh

## Context

`harkd` is the long-lived daemon the Electron UI spawns. It inherited
`hark-capture`'s **fail-fast permission preflight** ([ADR-0006](0006-phase-2-capture-architecture.md) §3,
[ADR-0007](0007-active-permission-request.md)): on startup it called
`PermissionGate.ensureGranted()` (Microphone **and** Screen Recording) and, on
any miss, printed a report and `throw ExitCode(3)`. It also wrote the
`engine.port` discovery file **last**, after a slow model load.

While validating the Process Tap live path (see [ADR-0011](0011-process-tap-system-audio-gotchas.md)),
three coupled problems surfaced on first run:

1. **Grant → nothing happens → manual relaunch.** harkd fired the Screen
   Recording prompt, immediately re-checked (still ungranted — macOS only
   honors a Screen Recording grant after a process *restart*), and exited. By
   the time the user clicked *Allow*, harkd was already gone. The grant had no
   process to land in.
2. **It demanded the wrong permission.** With the Process Tap backend,
   system-audio capture needs `kTCCServiceAudioCapture` — **not** Screen
   Recording. harkd was dying over a permission the chosen backend never uses.
3. **The port file appeared late.** It was written only after the (cold, ~90s
   on M1) model load, so the UI / a manual client couldn't discover harkd until
   the model was ready — and a manual `cat` of the file during load returned
   empty.

A fail-fast preflight is correct for a *scriptable CLI* (its original ADR-0006
§3 rationale). It is wrong for a *UI-spawned daemon*.

## Decision

`harkd` no longer gates on permissions at startup. Specifically:

1. **No startup permission gate.** harkd needs no capture permission merely to
   boot and serve. The `ensureGranted()` + `exit(3)` is removed.
2. **Serve before loading the model.** Bind the WebSocket server and write the
   `engine.port` file **first**, so the daemon is discoverable immediately. Load
   WhisperKit *behind* the running server (NIO keeps serving during the
   `await`). `capture.start` arriving before the model is ready is rejected with
   a **recoverable** `ENGINE_WARMING_UP` error; the model is injected via
   `EngineSession.attachModel(...)` when ready.
3. **Acquire permissions lazily at `capture.start`, per requested source.**
   Microphone via `PermissionGate.requestMicrophone()` (only when the mic source
   is on); system audio via the Process Tap backend's existing TCC request. Both
   grant **live** (no relaunch), so capture proceeds in the same process.
4. **Report, never exit.** A denied permission becomes a recoverable WS error
   frame (e.g. `MIC_DENIED`), not a process exit — so the UI can guide the user.

`hark-capture` (the CLI) keeps its fail-fast preflight — that UX is right for a
scriptable one-shot tool.

## Alternatives considered

- **Keep the fail-fast startup preflight** (status quo from ADR-0006 §3).
  - ✅ Simple; one place to reason about permissions.
  - ❌ For a daemon: grant → exit → manual relaunch; demands Screen Recording
    even for the tap backend; couples discoverability to model load.
  - **Why rejected:** it's a CLI philosophy applied to a daemon. The relaunch
    requirement is exactly the UX wart we set out to remove.

- **Request-and-wait at startup** (block the daemon until granted).
  - ❌ Screen Recording can't be granted without a process restart anyway, so a
    wait loop can't fix it; blocking a daemon on a modal grant is hostile to the
    UI that spawns it.
  - **Why rejected:** doesn't solve the restart-gated permission, wrong shape
    for a daemon.

- **Request all permissions at startup, but non-fatal.**
  - ✅ One prompt site; simpler than per-source lazy logic.
  - ❌ Prompts for the mic even when a session only captures system audio;
    still the wrong layer (permission is a capture-time concern, not a boot
    concern).
  - **Why rejected:** lazy per-source requests at `capture.start` are both more
    correct and better UX.

## Consequences

**Positive:**
- **Grant-and-continue.** The user grants once at capture time and capture
  proceeds in the same process — no relaunch. (Validated live: Bluetooth
  system audio → segments, 2026-05-31.)
- **Instant discoverability.** The port file is written before the model load,
  so the UI can connect immediately and show a "warming up" state.
- **Correct permission per backend.** Process Taps no longer drag in a Screen
  Recording requirement they don't use.
- **Daemon-appropriate failure mode.** Permission problems are recoverable WS
  errors the UI can act on, not a silent child-process death (what the Phase 5
  Electron spawn needs).

**Tradeoffs accepted:**
- `capture.start` can return `ENGINE_WARMING_UP` during a cold model load; the
  client must retry. The UI should surface this as a transient "warming up"
  state. A server-pushed readiness frame is not yet implemented (clients retry).
- The WS server accepts connections before the model is ready; correctness
  relies on the `capture.start` readiness gate.

**Must remain true:**
- Capture-time permission requests grant **live**. Mic and the
  `kTCCServiceAudioCapture` tap permission do. **Screen Recording does not** (it
  needs a restart) — so the ScreenCaptureKit backend still cannot
  grant-and-continue. This is another reason to prefer Process Taps as the
  default (see [ADR-0011](0011-process-tap-system-audio-gotchas.md) open-Q #18).

## Open questions

- **Readiness push frame.** A `meta.ready` (or updated `meta.hello`) broadcast
  when the model attaches would let the UI start capture without polling /
  retrying on `ENGINE_WARMING_UP`. Deferred until the Phase 4 UI needs it.
- **Packaged-app permission UX** (Phase 5). In the shipped Electron app, harkd
  is a child process; the audio-capture grant must attribute to the signed app
  bundle. The onboarding flow should drive the first grant. Tracked with
  [ADR-0011](0011-process-tap-system-audio-gotchas.md) #18.

## References

- Amends: [ADR-0006](0006-phase-2-capture-architecture.md) §Decision 3 (daemon only; CLI keeps fail-fast)
- Relates to: [ADR-0007](0007-active-permission-request.md) (active permission request), [ADR-0011](0011-process-tap-system-audio-gotchas.md) (Process Tap capture)
- Implementation: `engine/Sources/Harkd/HarkdCommand.swift`, `engine/Sources/Harkd/EngineSession.swift`, `engine/Sources/HarkCapture/PermissionGate.swift`
