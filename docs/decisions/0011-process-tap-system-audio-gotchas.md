# ADR-0011: Making Core Audio Process Taps actually capture system audio

- **Date:** 2026-05-31
- **Status:** Accepted (reaffirms and amends [ADR-0006](0006-phase-2-capture-architecture.md) §Decision 1)
- **Deciders:** Dang Anh Tuan

## Context

[ADR-0006](0006-phase-2-capture-architecture.md) chose **Core Audio Process Taps** for system-audio capture and explicitly flagged the risk: *"Process Tap creation is allowed for an unsigned binary... If a future macOS enforces entitlements we can't grant ourselves, revisit."* That risk came due.

On macOS 26, `hark-capture --system-only` produced a **0-byte WAV** — every Core Audio call returned `noErr`, no audio ever arrived. The same code path that "should" work per the WWDC 2024 docs simply delivered nothing, with **no error to debug**. This blocked the entire reason system capture exists: letting someone record a meeting while listening on **Bluetooth headphones**, so a private conversation isn't played out loud into the room.

We came within one session of abandoning Process Taps for a ScreenCaptureKit fallback (which we built and confirmed works — see Alternatives). This ADR records *why Process Taps appeared dead, how we proved they weren't, and the exact recipe that made them work*, so nobody re-litigates the API choice or re-suffers the four-hour debug.

This builds on [ADR-0007](0007-active-permission-request.md) (active permission requests) because one of the three root causes was a TCC service that ADR-0007's gate never knew to request.

## Decision

**Keep Core Audio Process Taps** (reaffirming ADR-0006). Getting them to deliver audio in a non-GUI process requires **all four** of the following — miss any one and you get `noErr` everywhere and silence:

1. **Request the `kTCCServiceAudioCapture` permission** — a *third* TCC service, distinct from Microphone and Screen Recording. It must be requested with a **stable code identity**: sign the binary (a free Apple Development cert is enough) and launch it so LaunchServices attributes the grant (`open` the `.app`, don't run the Mach-O by path). Production ships a signed `.app` with `NSAudioCaptureUsageDescription` and uses the public prompt; dev builds use the private TCC SPI behind `HARK_ENABLE_TCC_SPI=1`.
2. **Run a real `CFRunLoop`** on a dedicated thread and point `kAudioHardwarePropertyRunLoop` at it. `AudioDeviceStart` is *asynchronous*; the HAL delivers its start-completion on a run loop. A GUI app gets this free from its main run loop — a CLI/daemon does not.
3. **Build the aggregate device correctly**: the default **output device** as both `MainSubDevice` and the sole entry in `SubDeviceList` (it provides the clock), the tap in `TapList` with drift compensation, and **all boolean keys as real `CFBoolean`s** (Swift `true`/`false`, *not* `Int` `1`/`0` — a `CFNumber` there reads as false).
4. **Do NOT set `isPrivate` / `isExclusive` on the tap description.** On a global tap these flags let the tap *bind* but silently prevent the aggregate device from ever *starting*.

## The challenge — symptoms and how we resolved each

The failure was a stack of three independent bugs, each masking the next. Every layer returned success, so the only way through was **runtime diagnostics**, not reading more docs.

### Painpoint 1 — "0 frames, no error" (the silent TCC gate)

System capture returned `noErr` from every call and wrote silence. Root cause: Process Taps are gated by **`kTCCServiceAudioCapture`**, which is neither Microphone nor Screen Recording. ADR-0007's gate requested the wrong two permissions, so the prompt for the *right* one never appeared and the tap was fed nothing.

**Resolved by** requesting `kTCCServiceAudioCapture` explicitly. But the request *also* silently failed until the binary had a **stable signed identity** — an ad-hoc/unsigned binary has no identity for TCC to attribute or remember, so the request no-ops with no prompt. Fixed by signing with a free **Apple Development** certificate (which required importing the **Apple WWDR G3 intermediate** — only an expired 2023 cert was present, so `security find-identity` showed 0 identities) and launching via `open` so LaunchServices attributes the grant to the bundle, not to the parent terminal.

### Painpoint 2 — "permission granted, IOProc still never fires"

With permission now `authorized`, still 0 frames. This was the hard one, because *every* call — `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`, `AudioDeviceCreateIOProcIDWithBlock`, `AudioDeviceStart` — returned `noErr`, yet the IO callback was never invoked.

**Resolved by instrumentation, not theory.** We added a readback of the aggregate's real state right after `AudioDeviceStart`:

```
isAlive=1  inputStreams=1  activeSubDevices=1  isRunning=0
```

That single line ended the guessing. The device was **fully composed** (alive, tap bound as an input stream, output device attached as clock) but **never started its IO cycle** (`isRunning=0`, persisting for the full run). So this was a *start* problem, not a tap/permission/composition problem. Two root causes, both necessary:

- **No serviced run loop.** `AudioDeviceStart` only *requests* the start; the completion is delivered asynchronously on a `CFRunLoop`. Our `@main async` CLI parks in `dispatch_main()` — which drains the *dispatch queue* (timers fire) but runs **no `CFRunLoop`** — so the start completion was never serviced. Fixed by spinning a dedicated thread running `CFRunLoopRun()` and pointing `kAudioHardwarePropertyRunLoop` at it. (Setting that property to `NULL`, which the docs say makes the HAL use its own thread, was observed to be a **no-op on macOS 26** — only a genuinely running loop worked.)
- **The tap-description flags.** Even with a running loop, `isRunning` stayed 0 until we removed `isPrivate = true` and `isExclusive = false` from the `CATapDescription`. With them set, the tap bound (`inputStreams=1`) but the aggregate refused to run. Removing them — matching the known-good reference (AudioCap) — flipped `isRunning` `0 → 1` and the IOProc fired immediately (512 frames/cycle, real audio at peak ≈ 0.58).

### The lesson

The breakthrough was the `dbgAggregateState` readback. We burned four "obvious" single-shot fixes (aggregate clock, output-as-subdevice, dispatch queue, CFBoolean keys) by pattern-matching against the reference instead of measuring. The moment we read `kAudioDevicePropertyDeviceIsRunning` and saw a composed-but-not-running device, the search space collapsed. **When Core Audio returns `noErr` and does nothing, instrument the object state before changing more code.**

## Alternatives considered

- **Fall back to ScreenCaptureKit audio-only** (the mitigation ADR-0006 pre-authorized).
  - ✅ Pros: we *built* it and it **works today** — `SCStream` with `capturesAudio=true` reliably delivered PCM; lower OS floor (13+); no run-loop or TCC-SPI dance.
  - ❌ Cons: the "audio inside a display-capture framework" smell ADR-0006 already named — a hidden 2×2px video stream, SCK lifecycle cost, and Screen Recording permission for an audio feature.
  - **Why not chosen (but kept):** Process Taps are the right API and now proven to work. SCK is **retained as a selectable backend** (`HARK_CAPTURE_BACKEND` chooses; `tap` = Process Taps, default currently SCK) — a tested escape hatch if a future macOS breaks the tap path again. We are not throwing away working code.

- **Abandon system-audio capture, mic-only.**
  - ❌ Cons: defeats the product. Meeting transcription needs the *other* participants' audio.
  - **Why rejected:** Non-starter.

- **Per-process tap (`stereoMixdownOfProcesses:`) instead of global.**
  - The reference (AudioCap) taps one process. We need the **whole system mix** (any meeting app), so we use `stereoGlobalTapButExcludeProcesses: []`. The global form works with the same recipe; per-process stays available for a future "capture only Zoom" feature.

## Consequences

**Positive:**
- The clean, Apple-intended API for system audio — no fake video stream.
- **Bluetooth headphones work without an A2DP→HFP downgrade.** We tap only the *rendered output* and never open the BT microphone, so the headphones stay in hi-fi output mode. This is the entire user-facing reason the saga mattered, and Process Taps are *better* than SCK for it.
- A working, signed, on-device dev-test path (free Apple ID) for the privacy-sensitive audio permission.
- A reusable diagnostic (`HARK_TAP_DEBUG=1` → aggregate state readback) for the next Core Audio mystery.

**Tradeoffs accepted:**
- **More moving parts than SCK:** a dedicated HAL run-loop thread (needed for the long-lived `harkd` daemon anyway), a private TCC SPI for dev builds, and the free-cert + WWDR-G3 + `open`-launch ritual.
- **The tap is no longer marked private** (`isPrivate` dropped). This does **not** violate the "audio never leaves the machine" rule — the capture still flows only to our IOProc and only to the local vault — but another *local* process could, in principle, enumerate the tap while it exists. Low surface, local-only, and flagged below as a thing to tighten.
- **macOS-version sensitivity confirmed real:** the `NULL`-run-loop no-op shows behavior shifts between releases. The SCK fallback is our insurance.

**Must remain true:**
- The free Apple Development cert can still acquire `kTCCServiceAudioCapture` for a locally-signed `.app`. If Apple gates taps behind a paid-account-only entitlement, revisit (mitigation: SCK backend already in place).
- A non-GUI process can set `kAudioHardwarePropertyRunLoop` to its own running loop. If a future macOS locks this, `harkd` needs a different HAL-notification strategy.

## Open questions

- **Minimal-fix bisect not completed.** The working config has *both* the dedicated run loop *and* no `isPrivate`/`isExclusive`. We A/B-confirmed that removing the tap flags was the final flip (run loop present in both runs), but did **not** separately confirm the run loop is strictly necessary once the flags are gone. The run loop is kept regardless — it's correct practice for a daemon servicing HAL notifications — but the strict-necessity question is open.
- **Can we restore tap privacy?** We removed `isPrivate` *and* `isExclusive` together. If `isExclusive = false` was the real blocker, `isPrivate = true` might be restorable — worth a privacy-auditor follow-up to regain tap isolation without losing capture.
- **Default backend.** Process Taps now work; SCK is currently the default with `tap` opt-in. Whether to flip the default to Process Taps (and demote SCK to fallback-only) is a separate decision once the tap path has more on-device mileage.

## References

- [AudioCap](https://github.com/insidegui/AudioCap) by Guilherme Rambo — the known-good reference (per-process tap); our `CATapDescription` + aggregate config matches it after the fix.
- WWDC 2024 session 10160 — "What's new in Core Audio" (Process Taps intro)
- Apple docs: `CATapDescription`, `AudioHardwareCreateProcessTap`, `kAudioHardwarePropertyRunLoop`, `kAudioDevicePropertyDeviceIsRunning`
- Amends: [ADR-0006](0006-phase-2-capture-architecture.md) §Decision 1; relates to [ADR-0007](0007-active-permission-request.md)
- Implementation: `engine/Sources/HarkCapture/CoreAudioProcessTap.swift`, `engine/Sources/HarkCapture/PermissionGate.swift`, `engine/scripts/sign-dev-bundle.sh`
