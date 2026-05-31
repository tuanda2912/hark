---
name: test-tap
description: Runs Hark's on-device Core Audio Process Tap capture test (the hark-capture CLI). Use this skill whenever you need to verify system-audio capture works, exercise the tap backend, or debug a "no audio / 0 frames / isRunning=0 / permission denied" capture problem — even if the user just says "test capture", "does the tap work?", or "check the mic/system audio". It encodes the exact build → sign → launch-via-open → read-log recipe and the footguns (run-by-path breaks TCC; isExclusive stops the device starting) that took an entire debugging session to find. Needs real Apple-Silicon hardware.
---

Verify Core Audio Process Tap system-audio capture end to end on a real Mac. This is the standalone capture check (the `hark-capture` CLI writing a WAV) — for the live daemon path use the `smoke-harkd` skill instead.

## Why this skill exists

Process Taps on macOS 14.4+ are gated by a TCC service (`kTCCServiceAudioCapture`) that is **distinct from Microphone and Screen Recording**, and the grant only sticks for a **stable signed identity attributed by LaunchServices**. Get any step wrong and *every Core Audio call returns `noErr` while the tap is fed silence* — no error to chase. The recipe below is the one that actually works; the failure table maps each silent-failure signature to its cause. Full story: [ADR-0011](../../../docs/decisions/0011-process-tap-system-audio-gotchas.md).

This can only be validated on real M-series hardware (CI / non-Mac can't grant TCC or run the HAL). If you're not on such a machine, say so rather than faking a result.

## Procedure

Run from the repo root. Have audio playing through the current output device (built-in speakers or Bluetooth — both work).

1. **Build** the engine:
   ```bash
   cd engine && swift build -c release
   ```

2. **Sign** `hark-capture` into a bundle (a stable identity is what TCC remembers — an ad-hoc/unsigned binary is silently denied):
   ```bash
   ./scripts/sign-dev-bundle.sh "Apple Development: you@example.com (TEAMID)" hark-capture
   ```
   Find your identity with `security find-identity -v -p codesigning`. A **free** Apple Development cert is enough (it needs the Apple WWDR G3 intermediate installed, or `find-identity` shows 0 identities).

3. **Launch via `open`** — never run the Mach-O by path. TCC attributes the audio-capture grant to the *LaunchServices-launched app*; running the binary directly attributes to your terminal and the grant never lands.
   ```bash
   rm -f /tmp/tap.log /tmp/tap.wav
   open -W \
     --env HARK_CAPTURE_BACKEND=tap --env HARK_ENABLE_TCC_SPI=1 --env HARK_TAP_DEBUG=1 \
     --stdout /tmp/tap.log --stderr /tmp/tap.log \
     "engine/.build/HarkCapture.app" \
     --args --system-only --duration 12 -o /tmp/tap.wav
   ```
   On first run, grant the audio-capture prompt for the bundle. (`HARK_ENABLE_TCC_SPI=1` is the dev-only path that requests the permission; production uses the public `NSAudioCaptureUsageDescription` path.)

4. **Read the log** and confirm success:
   ```bash
   cat /tmp/tap.log
   ```
   A healthy run shows:
   - `TCC audio-capture ... authorized`
   - `aggregate state: isAlive=1 isRunning=1 inputStreams=1 activeSubDevices=1`
   - `ioproc call #1 frames=512` (and #2…#5)
   - `frames_written` climbing and `peak` > 0
   - a `/tmp/tap.wav` larger than 44 bytes (`afinfo /tmp/tap.wav` to confirm real audio)

## Failure table (every one of these returns noErr)

| Symptom in the log | Cause | Fix |
|---|---|---|
| `missing permission` / `granted=false`, no prompt | Not signed, or launched by path (not `open`) → no stable TCC identity | Sign (step 2) + launch via `open` (step 3) |
| `isRunning=0` persists, `inputStreams=1` | Aggregate device never starts its IO cycle | A real **CFRunLoop** must run for HAL notifications (CLI has none by default), and **`isExclusive` must NOT be set** on the tap description (`isPrivate=true` is fine). See ADR-0011. |
| `inputStreams=0` | Tap didn't bind into the aggregate | Aggregate tap-list UID / config mismatch |
| all `status=0` but no `ioproc call` ever | The umbrella signature of the above | Walk the table top-down |

## Variations

- **Bluetooth check**: switch system output to Bluetooth headphones, play audio, rerun. The log's `aggregate clock/sub-device` should show the BT device UID; capture works without dropping the headphones from A2DP to HFP (we only tap rendered output, never the BT mic).
- **Privacy**: the tap is created `isPrivate=true` by default (visible only to this process). Validated on-device that this alone does NOT block the device from starting — `isExclusive` was the real blocker and is never set.

## Privacy

This captures live system audio. It stays local — written only to the WAV path you pass and never sent anywhere. Keep it that way; see the hard rules in [CLAUDE.md](../../../CLAUDE.md).
