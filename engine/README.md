# HarkEngine — Phase 0 RTF Benchmark

The go/no-go measurement for Hark's transcription stack. Loads
WhisperKit `large-v3-turbo` (the `large-v3-v20240930_626MB` Core ML bundle
from Argmax), feeds an audio file through it in production-shaped windows
(30 s window, 5 s hop), and reports Real-Time Factor.

**Pass criterion:** `rtf_avg < 0.5` on Apple Silicon.

If this fails on a real M-series Mac with a representative meeting sample,
the entire architecture from [ADR-0003](../docs/decisions/0003-swift-whisperkit-engine.md)
needs to be revisited before any further code is written.

## What this measures (and what it doesn't)

It measures:

- Wall-clock seconds per 30-second window, on **your** Mac, with **your** thermal state
- avg / p50 / p95 / p99 RTF across all windows of one file
- Cold-start time (first window includes the JIT-to-ANE compile cost)

It does **not** measure:

- Word Error Rate (WER) — speed only; quality is a separate benchmark
- End-to-end latency (spoken-word → visible-text) — requires the capture
  path + UI, not in scope for Phase 0
- Memory / CPU / battery — use Xcode Instruments for that
- Performance on noisy real-world meetings unless your fixture is one

A single number from a single file is a coarse signal. Trust the verdict
when (a) thermal state starts `nominal`, (b) the fixture is realistic
meeting-grade speech (not music, not silence), and (c) you can reproduce
the result across 2–3 runs.

## Prerequisites

- macOS **13.0 Ventura or newer** (floor set by `argmax-oss-swift` v1.0.0)
- Apple Silicon Mac (M1 or later) — Intel Macs are out of scope
- **Xcode Command Line Tools** — `xcode-select --install` is enough; the
  full Xcode is not required, SwiftPM works from the CLI
- ~2 GB free disk for the model download + build artifacts
- An internet connection on first run only (model download from
  HuggingFace; see "Network policy" below)

## One-time setup

```bash
cd engine
swift build -c release
```

First build pulls SwiftPM dependencies (`argmax-oss-swift` v1.0.0+) and
compiles them. Allow a few minutes. Subsequent builds are incremental.

The model is **not** downloaded at build time — it downloads on first
**run** because WhisperKit fetches it lazily. ~626 MB pulled from
`huggingface.co/argmaxinc/...` into `~/Documents/huggingface/models/`.
On a slow connection this is the longest single wait in the whole flow
(2–5 min on typical home internet). To avoid skewing thermal state on
your first real benchmark run, do a throwaway run first to warm the cache.

## How to run

```bash
swift run -c release hark-bench /path/to/sample.wav
```

Always use `-c release`. A debug build of WhisperKit is several times
slower and will give you garbage RTF numbers. (Roughly analogous to
benchmarking a Spring app without `-XX:+TieredCompilation` — the result
is technically a number but it's not the number you want.)

Get a fixture file: see [`Fixtures/README.md`](Fixtures/README.md).

### Interpreting the verdict

The harness prints one of:

```
PASS  RTF avg=0.273 < 0.50  (p95=0.331, cold=2.41s)
```

```
FAIL  RTF avg=0.612 >= 0.50  (p95=0.701, cold=2.18s)
```

A FAIL doesn't immediately mean the stack is wrong — sanity-check first:

- Did you run with `-c release`?
- Was `thermal_state_start` `nominal`? (If `fair`/`serious`, let the
  Mac cool down and rerun.)
- Was the fixture realistic? Music or pure silence skews things.
- Is anything else hammering the ANE (Final Cut, Xcode building, etc.)?

If those are clean and it still fails, ADR-0003's assumption is in
trouble. Document the result and revisit the decision.

### Output

- Pretty-printed JSON report to stdout
- A timestamped copy under `engine/Results/{ISO-date}-{git-sha}.json`
- Exit code `0` on PASS, `2` on FAIL, `1` on any error

## Network policy

The only network call this binary makes is **WhisperKit's model download
from HuggingFace on first run**. This is sanctioned in
[ADR-0003](../docs/decisions/0003-swift-whisperkit-engine.md) and noted
in the Hark hard rules ([CLAUDE.md](../CLAUDE.md), rule #6). No
telemetry, no analytics, no log shipping. The downloaded model lives
under `~/Documents/huggingface/models/argmaxinc/...` and can be deleted
to force a re-download.

## Pinned versions

| Component | Version | Source |
| --- | --- | --- |
| `argmax-oss-swift` (WhisperKit) | `1.0.0+` (SemVer-bound `< 2.0.0`) | https://github.com/argmaxinc/argmax-oss-swift |
| Model | `large-v3-v20240930_626MB` (the turbo variant) | huggingface.co/argmaxinc |
| Swift tools | 5.10+ | Xcode 15.3+ Command Line Tools |
| macOS minimum | 13.0 (Ventura) | inherited from argmax-oss-swift |

## Layout

```
engine/
├── Package.swift              SPM manifest
├── README.md                  this file
├── .gitignore                 ignores .build/, Results/*.json, audio fixtures
├── Sources/
│   └── HarkBench/
│       └── main.swift         the harness — single file is fine for Phase 0
├── Fixtures/
│   └── README.md              how to get a test audio file
└── Results/
    └── .gitkeep               output dir for run history (gitignored content)
```
