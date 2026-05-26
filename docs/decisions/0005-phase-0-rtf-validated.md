# ADR-0005: Phase 0 RTF validated — proceed with planned stack

- **Date:** 2026-05-26
- **Status:** Accepted
- **Deciders:** Quynh Anh

## Context

Phase 0 of the project plan exists as a single go/no-go experiment: measure whether WhisperKit `large-v3-turbo` running on the Apple Neural Engine can hit the **RTF < 0.5** target on the developer's actual hardware with a representative audio sample.

This was the gate for every downstream assumption in [ADR-0002](0002-macos-only-scope.md) (macOS-only scope), [ADR-0003](0003-swift-whisperkit-engine.md) (Swift + WhisperKit engine), and [ADR-0004](0004-no-cloud-asr.md) (no cloud ASR). If Phase 0 failed, all three would have needed reopening — likely with a fallback to Q5 quantization, a smaller model, or in the worst case revisiting the cloud-ASR rejection.

## Decision

**Proceed with the planned stack. No fallback needed.** Phase 1 (Swift engine batch mode) is unblocked.

## The numbers

Measured on `engine/Results/` from two consecutive runs of the harness in [`engine/Sources/HarkBench/main.swift`](../../engine/Sources/HarkBench/main.swift).

| Metric | Measured | Threshold | Margin |
|---|---|---|---|
| RTF avg | **0.0747** | < 0.50 | 6.7× under |
| RTF p50 | 0.0789 | — | — |
| RTF p95 | 0.0828 | < 0.50 | 6.0× under |
| RTF p99 | 0.0835 | — | — |
| Cold start | 1.67s (warm cache); 2.22s (first launch) | ≤ 5.0s | 3.0× under |

**Runtime context:**
- Hardware: Apple **M4**, 16 GB RAM, macOS 26.5.0, thermal state "nominal" at start
- Model: `large-v3-v20240930_626MB` (WhisperKit turbo CoreML bundle, Argmax)
- Audio: 255-second English public-domain LibriVox sample (`short-stories-0269-272-john-chapman-american-pioneer.mp3`)
- Windows: 46 sliding 30s windows with 5s hop (production setting)
- WhisperKit version: pinned `from: "1.0.0"` via `argmaxinc/argmax-oss-swift` umbrella package

## What this validates

- **WhisperKit on the Apple Neural Engine** delivers ~13× real-time on M4. The ANE acceleration thesis was correct.
- **The live-caption latency budget** (spoken word → visible text ≤ 1.5s) has massive headroom. A 5-second audio chunk transcribes in ~375 ms wall-clock; VAD, diarization, translation, vault writes, and UI render can all sit comfortably inside the remaining budget.
- **Cold-start spec** is met by 3× margin even on a freshly-launched process.
- **Backpressure rule** (drop oldest unprocessed segment if RTF > 1) becomes a defensive fallback rather than a routine path.

## What this does NOT validate

Be honest about scope:

1. **English-only sample.** Thai ↔ English code-switching (the developer's actual use case) is unmeasured. Rare token paths in Whisper can be 1.5–2× slower per word; code-switch may have worse WER. Even a 3× slowdown would still pass with 2× margin under threshold, so this is not a stack-blocker, but it's an open performance question for v1.
2. **WER unmeasured.** Phase 0 measured speed only. Accuracy on real meeting audio (noisy, multi-speaker, code-switch) is a Phase 1+ concern, gated by the WER targets in [vault/docs/qa/10-performance-benchmarks.md](~/Documents/vault/hark/docs/qa/10-performance-benchmarks.md) §"Benchmark 4".
3. **One hardware data point.** M4 is the current top of the line. M1 base (8 GB RAM, oldest still-supported Apple Silicon) may run 2–3× slower → estimated RTF ~0.15–0.22, which still passes by 2× margin. Worth a sanity check during Phase 7 hardening, not a blocker now.
4. **One audio case.** The full perf spec lists 5 fixture cases (clean / noisy / code-switch / 3-speaker / cold start). Phase 0 validated case 1. The others get measured naturally during Phase 1+ dogfooding on real meetings.

## Alternatives that would have been considered on FAIL

Recording these so future-us understands what was on the table if the verdict had gone the other way:

- **Q5_K_M quantization** of large-v3-turbo (~3% WER loss for ~30% speed gain)
- **Drop to medium model** (Whisper medium ~3GB → ~750 MB CoreML, ~15% WER worse on technical English)
- **Force ANE-only compute units** (potentially faster, less flexible)
- **Revisit cloud ASR** as a last resort (would invalidate the entire product thesis — see [ADR-0004](0004-no-cloud-asr.md))

None of these are on the table. Filed for posterity in case future hardware or library regressions force a re-evaluation.

## Consequences

**Positive:**
- All downstream phases unblocked. No re-architecture needed.
- High confidence in the stack we've documented across CLAUDE.md, the handoff doc, and ADRs 0001–0004.
- Future ADRs can cite this as the empirical foundation rather than re-litigating the WhisperKit choice.

**Negative / tradeoffs accepted:**
- Continued dependence on WhisperKit's continued maintenance by Argmax. If they abandon the project, we'd need to fork or migrate to MLX-Whisper. Risk acknowledged, not mitigated today.

**Assumptions that must hold:**
- Future macOS releases continue to support WhisperKit's CoreML bundle pattern and ANE access for third-party apps. No signal Apple intends otherwise.
- Real meeting audio (noisy conference rooms, code-switching) doesn't cause a >5× performance cliff vs. clean LibriVox. If Phase 1 dogfooding reveals it does, this ADR gets revisited.

## References

- Raw results: `engine/Results/2026-05-26T092104-21cfbe4.json`, `engine/Results/2026-05-26T092425-21cfbe4.json`
- Harness source: `engine/Sources/HarkBench/main.swift`
- Performance spec: [vault/docs/qa/10-performance-benchmarks.md](~/Documents/vault/hark/docs/qa/10-performance-benchmarks.md)
- Validates assumptions in [ADR-0002](0002-macos-only-scope.md), [ADR-0003](0003-swift-whisperkit-engine.md), [ADR-0004](0004-no-cloud-asr.md)
