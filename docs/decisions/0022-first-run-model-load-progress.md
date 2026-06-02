# ADR-0022: First-run model-load progress

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Now that Hark ships as a packaged app (ADR-0021), a fresh install hits a rough first
launch: the WhisperKit speech model (~626 MB) and the FluidAudio diarization CoreML
models download and compile during warm-up, and until now the engine emitted **nothing**
on the wire between `meta.hello {model_loaded: "(loading)"}` and the terminal `meta.ready`.
The user sees a frozen idle UI for what can be a couple of minutes — it looks hung.

An investigation into what progress the model loaders actually expose found an uneven
picture: **continuous fractions are available for the downloads** (WhisperKit's
`download(...progressCallback:)` gives a 0..1 `Progress.fractionCompleted`; FluidAudio's
`OfflineDiarizerModels.load(progressHandler:)` gives a byte-continuous download fraction +
a per-file compile fraction with an explicit phase enum), **but the WhisperKit ANE
compile/prewarm step — the slowest, most "hung-looking" part — exposes no progress API at
all** (no fraction, no per-stage callback).

## Decision

Add a purely additive engine→UI event, **`meta.model_progress`** with payload
`{ phase: string, fraction: Double?, detail: string }`:

- `phase` ∈ `downloading_speech` | `optimizing_speech` | `downloading_diarizer` |
  `optimizing_diarizer`.
- `fraction` is `0..1` for the download/compile phases that expose one; **`null` (JSON
  `null`, explicitly encoded) for the WhisperKit ANE compile**, where the UI shows a
  labeled **spinner**, not a fabricated percentage.
- `detail` is a short human label ("Downloading speech model", "Optimizing for Neural
  Engine", "Preparing speaker recognition").

Emission is **throttled** before crossing the actor boundary (emit on phase change, on
`fraction` delta ≥ 0.01, or ≥ 200 ms elapsed) so the high-frequency download callbacks
don't flood the actor with tasks. The last progress payload is **snapshot-replayed** to a
client that connects mid-download (after `meta.hello`), and **cleared on `meta.ready`**,
which stays the **terminal** readiness signal. The UI shows a full-screen **"Preparing
Hark…"** screen — a determinate bar when `fraction != null`, a labeled spinner when
`null` — gated behind an **~800 ms anti-flash delay** (revealing immediately if a progress
frame arrives) so warm-cache launches with fast warm-up don't flicker a loader.

This is **Slice 1** (the functional fix). The welcome/permission **onboarding screens**
(`Onboarding.jsx`) + a first-run prefs flag are **Slice 2**, deferred (BACKLOG).

## Alternatives considered

- **Fabricate a percentage for the ANE compile** (e.g. interpolate against an estimated
  duration).
  - ✅ A moving bar looks "smoother".
  - ❌ Dishonest; it would stall at a fake number or finish early, and the compile time
    varies wildly (M1 ~90 s vs M4 seconds).
  - **Why rejected:** an honest "Optimizing for Neural Engine…" spinner + elapsed time is
    truthful and still reassuring.
- **Spinner-only, no fractions at all** (ignore the download progress we can get).
  - ❌ Throws away the genuine 0..1 fraction the downloads expose — the bulk of the wait
    on a fresh install is the download, where a real bar is most reassuring.
  - **Why rejected:** use the real signal where it exists.
- **Poll a `meta.status` endpoint instead of pushing.**
  - ❌ The contract is push/event-based; polling adds round-trips and a client timer.
  - **Why rejected:** a pushed event fits the existing model and replays cleanly to late
    clients.
- **Always show the full-screen loader during warm-up (no anti-flash gate).**
  - ❌ Cached-model launches warm up in ~1–2 s; a full-screen loader would flash every
    launch.
  - **Why rejected:** the 800 ms grace (reveal-immediately-on-progress) keeps fast launches
    clean while still covering real downloads.

## Consequences

**Positive**
- First-run no longer looks hung: a real download bar, then an honest "optimizing" spinner.
- A UI that connects mid-download immediately sees the current phase (snapshot replay).
- Honest by construction — no faked progress where the API can't provide it.
- Purely additive: `meta.ready` semantics unchanged; throttled so it can't flood the actor.

**Negative / tradeoffs accepted**
- The **WhisperKit ANE compile** (often the longest single step on a cold M-series first
  run) is **phase-only** — we genuinely cannot put a number on it.
- Diarizer progress rides the same screen; since the diarizer is non-fatal, a failure there
  is labeled gently and doesn't block readiness, but the screen briefly shows it.
- Slice 1 is progress only — the trust/permission onboarding screens are still to come.

**What needs to remain true**
- The model loaders keep exposing their progress callbacks (WhisperKit `download`,
  FluidAudio `load(progressHandler:)`). A WhisperKit upgrade that changes the API needs a
  re-check.
- `meta.ready` stays the single terminal readiness signal.

## Open questions

- Real first-run timing (download smoothness, ANE-compile duration/cadence) needs
  on-device verification on an M-series Mac with models not yet cached — the unit tests
  cover the throttle decision + the null encoding, not the end-to-end timing.
- A "this is taking longer than usual" hint after N seconds on the indeterminate phase?
- **Slice 2:** welcome/permission walkthrough screens + a `hasCompletedOnboarding` prefs
  flag (BACKLOG → UI surfaces / Packaging).

## References

- ADR-0012 (lazy permissions / readiness gating), ADR-0021 (packaging)
- `docs/design/08-websocket-api-contract.md` — `meta.model_progress` frame
- `docs/BACKLOG.md` — onboarding screens + first-run UX (Slice 2)
- Engine: `WireProtocol.swift`, `EngineSession.swift`, `HarkCore/ModelLoader.swift`,
  `DiarizerLoader.swift`, `HarkdCommand.swift`. UI: `engine.types.ts`,
  `engine.service.ts`, `components/model-loading.component.ts`.
- swift-macos-expert + Explore investigations (session 2026-06-02)
