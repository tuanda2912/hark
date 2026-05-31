---
name: smoke-harkd
description: Runs the live end-to-end smoke test of Hark's streaming daemon (harkd) over its WebSocket — capture → VAD → WhisperKit → segment frames. Use this skill whenever you need to verify the live transcription path works, test harkd after engine changes, or debug "no port file / can't connect / websocat: invalid port number / no segments" — even if the user just says "test harkd", "does live transcription work?", or "smoke the engine". Encodes the sign → open-launch → parse-the-JSON-port → websocat → capture.start recipe and the footguns (engine.port is JSON not a bare number; run via open not by path). Needs real Apple-Silicon hardware.
---

Verify the full live product loop: system audio → Process Tap → energy VAD → sliding window → WhisperKit → WebSocket `segment.partial`/`segment.final`. This drives the actual daemon the UI talks to. For the standalone capture-layer check (no daemon, just a WAV) use the `test-tap` skill; the TCC/signing footguns there apply here too.

## Why this skill exists

harkd is a long-lived daemon that the Electron UI spawns. Two things bite people every time: (1) the discovery file `engine.port` is **JSON** (`{pid,port,version}`), so `cat`-ing it straight into a URL yields `invalid port number`; and (2) like all Process Tap work, harkd must be **signed and launched via `open`** for the audio-capture grant to attribute correctly. harkd also now serves (and writes the port file) *before* the model finishes loading, so `capture.start` can briefly return a recoverable `ENGINE_WARMING_UP`. See [ADR-0012](../../../docs/decisions/0012-harkd-lazy-permissions-startup.md) and [ADR-0011](../../../docs/decisions/0011-process-tap-system-audio-gotchas.md).

Real M-series hardware only. Requires `websocat` (`brew install websocat`).

## Procedure

Run from the repo root, with audio playing.

1. **Build + sign harkd** (own bundle id `com.hark.daemon.dev`):
   ```bash
   cd engine && swift build -c release
   ./scripts/sign-dev-bundle.sh "Apple Development: you@example.com (TEAMID)" harkd
   ```

2. **Kill any stale daemon** so you don't test an old binary (the port file would point at its pid):
   ```bash
   pkill -f Harkd.app; sleep 1
   ```

3. **Launch via `open`** (no `-W` — it's a daemon that stays up). Logs to a file so you can read them:
   ```bash
   rm -f /tmp/harkd.log
   open --env HARK_CAPTURE_BACKEND=tap --env HARK_ENABLE_TCC_SPI=1 --env HARK_TAP_DEBUG=1 \
     --stdout /tmp/harkd.log --stderr /tmp/harkd.log \
     "engine/.build/Harkd.app"
   ```
   Grant the audio-capture prompt for "Harkd" on first run (separate grant from hark-capture — different bundle id).

4. **Get the port — parse the JSON, never `cat` it raw**:
   ```bash
   PORT=$(plutil -extract port raw ~/Library/Application\ Support/Hark/engine.port)
   # or, sidestep the file entirely — grab the URL harkd logged on startup:
   #   websocat "$(grep -o 'ws://127.0.0.1:[0-9]*/v1' /tmp/harkd.log | head -1)"
   ```
   The port file appears within ~2s now (before the model load), so if it's missing, harkd hasn't started — check `/tmp/harkd.log`.

5. **Connect and start a capture** (system-only isolates the tap):
   ```bash
   websocat "ws://127.0.0.1:$PORT/v1"
   ```
   then paste and send:
   ```json
   {"v":1,"type":"capture.start","payload":{"sources":{"mic":false,"system":true}}}
   ```

6. **Watch the frame stream.** A healthy run shows, in order:
   - `meta.hello` (its `model_loaded` may be `"(loading)"` if you connected during the model load)
   - `meta.ready` once the model is loaded (then `capture.start` will succeed)
   - `ack` → `capture.started` (session_id, vad)
   - `meta.heartbeat` with `rtf_current` < 0.5 and `ring_buffer_fill_sec` climbing
   - `segment.partial` frames with transcribed text, then `segment.final` with the **same `utterance_id`** + a `segment_id` (proves the utterance-ledger replace-in-place, ADR-0009)

   Also confirm in `/tmp/harkd.log`: `isRunning=1` and `ioproc call #…` (the capture layer is live).

## Failure table

| Symptom | Cause | Fix |
|---|---|---|
| `websocat: invalid port number` | `cat`-ed the JSON port file into the URL | Parse the `port` field (step 4) |
| No `engine.port` | harkd not started (or crashed) | Read `/tmp/harkd.log`; relaunch (step 3) |
| `engine.port` shows an old `pid` | Stale daemon owns the file | `pkill -f Harkd.app`, relaunch |
| `error ENGINE_WARMING_UP` | `capture.start` arrived before the model loaded | Wait for `meta.ready`, resend |
| Connects, `capture.started`, but no segments + `peak=0` in the log | Capture layer is silent | Diagnose with the `test-tap` skill's failure table |

## Privacy

The WebSocket binds `127.0.0.1` only (loopback, no auth — acceptable because only same-machine processes can connect). Transcript text flows over that socket and to the vault, never off-machine. See [CLAUDE.md](../../../CLAUDE.md).
