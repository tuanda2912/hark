# HarkCapture — Phase 2 audio capture CLI

`hark-capture` records system audio + microphone into a single 16 kHz mono
WAV file the Hark engine can transcribe.

**Status:** in development — Phase 2. See [STATUS.md](../../../STATUS.md).
**Architecture decisions:** [ADR-0006](../../../docs/decisions/0006-phase-2-capture-architecture.md).

## Prerequisites

- macOS **14.4** or newer (Process Taps require it)
- Apple Silicon Mac
- Xcode Command Line Tools (`xcode-select --install`)
- Microphone + Screen Recording permission granted to the terminal app you
  launch `hark-capture` from

## One-time setup

```bash
cd engine
swift build -c release
```

Check permissions before recording:

```bash
swift run -c release hark-capture --check-permissions
```

Exit code 0 = both granted; exit code 3 = at least one missing (the CLI
prints exactly which one and where to grant it).

## How to run

```bash
# Record 60 seconds of mixed mic + system audio:
swift run -c release hark-capture --duration 60 --output /tmp/session.wav

# Record until ⌃C:
swift run -c release hark-capture --output /tmp/session.wav

# Mic only (useful when debugging the mic path):
swift run -c release hark-capture --mic-only --duration 10 --output /tmp/mic.wav

# System only (useful when debugging the Process Tap path):
swift run -c release hark-capture --system-only --duration 10 --output /tmp/sys.wav
```

Pipe directly into the Phase 1 engine for an end-to-end batch run:

```bash
swift run -c release hark-capture --duration 60 --output /tmp/cap.wav \
  && swift run -c release hark-engine /tmp/cap.wav --output /tmp/cap.json
```

## Output format

- Container: RIFF WAV (PCM s16le)
- Sample rate: 16 000 Hz
- Channels: 1 (mono)
- Bit depth: 16 (signed integer little-endian)

This matches the engine's expected input (see Phase 1).

## What's measured (stderr heartbeat)

Once per second:

```
{"elapsed_s":12,"frames_written":192000,"mic_underrun_frames":0,"system_underrun_frames":0,"peak":0.63}
```

`peak` is the loudest sample (after soft-clip) in [0, 1]. `*_underrun_frames`
counts how many output frames were filled with silence because a source
fell more than 500 ms behind.

## Known limitations (Phase 2)

- No echo cancellation: laptop speakers picked up by the laptop mic will
  appear in both streams. Wear headphones for clean recordings.
- Default input device only: `--mic-device` lands later if needed.
- Sample-rate changes mid-capture (plug/unplug an audio interface) are
  untested. Documented in [ADR-0006](../../../docs/decisions/0006-phase-2-capture-architecture.md)
  open questions.
