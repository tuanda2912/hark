# ADR-0017: Diarization pipeline — offline `OfflineDiarizerManager` (VBx), not the streaming manager

- **Date:** 2026-06-01
- **Status:** Accepted
- **Supersedes:** [ADR-0016](0016-phase-5-diarization.md) **pipeline choice only** (§2 "offline pass via `performCompleteDiarization`"). Everything else in ADR-0016 stands — offline-at-stop, anonymous "Speaker N" in v1, the engine owns the vault write, full-session audio in RAM.
- **Deciders:** Dang Anh Tuan

## Context

[ADR-0016](0016-phase-5-diarization.md) committed Hark to **FluidAudio**, **offline**, **post-meeting** diarization run at `capture.stop`. It also named a specific entry point: §2 says "run FluidAudio's `performCompleteDiarization` over the full session audio." That call drives FluidAudio's **streaming** `DiarizerManager` — the path built for *live* diarization, which processes audio in fixed **10 s non-overlapping chunks**. ADR-0016 was right about the *shape* (offline at stop) but reached for the *streaming* engine to do it.

On-device that engine produced visibly wrong attribution: **69 diarization segments for 239 utterances**, with rapid speaker back-and-forth collapsing into single coarse ~5–10 s segments, so short utterances inherited one speaker label. The cause is structural, not a tuning miss: within a 10 s chunk the streaming manager emits one cluster decision, and a quick A→B→A exchange inside that window is flattened. FluidAudio's own docs call this path the **"legacy online diarizer"** whose **"most common source of error is incorrect labeling,"** and flag it as weak on overlapping speech, short utterances, and similar voices.

FluidAudio ships a second, separate engine for exactly the batch-at-stop case Hark is in: **`OfflineDiarizerManager`**, a VBx pipeline (overlapping windows → VBx **global** clustering → powerset / overlap-aware segmentation → exclusive-segment reconstruction). Since Hark already diarizes only *after* stop, with the full audio in RAM, using the streaming engine bought nothing and cost ~2.5× the error.

## Decision

Switch the at-stop diarization pass from FluidAudio's **streaming `DiarizerManager`** (`performCompleteDiarization`) to its **offline `OfflineDiarizerManager`** — VBx global clustering over overlapping windows, with powerset/overlap-aware segmentation and exclusive-segment reconstruction.

This changes **only** the engine entry point inside ADR-0016 §2. The rest of ADR-0016 is unchanged: offline pass at `capture.stop`, anonymous "Speaker N" labels in v1, the Swift engine as sole vault writer emitting `meeting.saved`, and full-session audio retained in RAM as mono 16 kHz `Float`. Same library, same dependency, same pin.

## Why (verified against primary sources)

- **Structural fit.** The streaming manager's 10 s non-overlapping chunking is a live-streaming design; it cannot do global clustering across the meeting or reason about overlap. The offline pipeline's overlapping windows + VBx global clustering + overlap-aware segmentation is the architecture that actually handles short utterances and back-and-forth. We are at stop, with the whole recording in hand — the offline engine is the matched tool.
- **Accuracy (FluidAudio's own AMI SDM benchmark, same scoring protocol across rows, so intra-library-comparable):** offline VBx ≈ **10.6 % DER** (full AMI) / **12.0 %** (subset), VoxConverse **15.07 %**; the streaming path ≈ **26.2 % DER** on full AMI SDM. **~2.5× error reduction**, same library, same models.
- **Speed is a non-issue.** The offline pipeline runs **~60–70× realtime** on Apple Silicon (M4 Pro reported) — a 1-hour meeting diarizes in ~1 minute. For a batch-at-stop pass, that is free.
- **Licensing is clean.** FluidAudio is Apache-2.0 and its re-hosted CoreML weights are **non-gated** (MIT/Apache-2.0) — shippable in an MIT app. Models still cache under `~/Library/Application Support/Hark/` per rule #2, same as WhisperKit ([ADR-0003](0003-swift-whisperkit-engine.md)).

This is the *opposite* of over-engineering: it is a **manager swap inside an existing dependency** that cuts error ~2.5×. The over-engineered path would have been bolting on a parallel ONNX or PyTorch stack (below).

## Alternatives considered

- **Tune the streaming chunk knobs** — keep `DiarizerManager`, adjust chunk/threshold settings.
  - ✅ Pros: no code-path change.
  - ❌ Cons: tuning the wrong tool. 10 s non-overlapping chunks structurally can't recover sub-chunk back-and-forth or overlap regardless of thresholds.
  - **Why rejected:** can't beat the offline pipeline's overlap-aware global clustering by tuning a streaming engine; the ceiling is the architecture.

- **sherpa-onnx (ONNX diarization).** A separate ONNX-runtime diarization stack.
  - ✅ Pros: mature project; clustering-based offline diarization.
  - ❌ Cons: uses the **same underlying models** (pyannote segmentation + WeSpeaker/CAM++ embeddings) as FluidAudio, but forces vendoring an ONNX C library, writing a Swift bridge, and shipping the ONNX runtime — for **no accuracy gain**.
  - **Why rejected:** all the integration cost, none of the upside. Over-engineered against a manager swap we already own.

- **pyannote.audio 3.1 directly.** The reference diarization toolkit.
  - ✅ Pros: state-of-the-art; FluidAudio wraps its segmentation model anyway.
  - ❌ Cons: Python/PyTorch — **not shippable as-is** in a Swift sidecar — and **HF-gated weights**, a licensing/distribution headache for an MIT app.
  - **Why rejected:** unshippable runtime + gated weights. FluidAudio already gives us pyannote's segmentation model in CoreML, ungated.

- **NVIDIA Sortformer.** Transformer diarization.
  - ❌ Cons: **streaming-only**, hard cap of **4 speakers**, official ONNX export broken/open.
  - **Why rejected:** wrong tool for batch; the speaker cap and broken export are disqualifying.

- **DIY per-utterance embedding + nearest-centroid assignment.** Embed each final segment, assign to the nearest speaker centroid.
  - ❌ Cons: a known anti-pattern — short-utterance embeddings are unreliable; this reinvents VBx, worse.
  - **Why rejected:** we'd be rebuilding the offline pipeline by hand and losing.

- **Apple native frameworks.** Speech / SoundAnalysis.
  - **Why rejected:** no speaker diarization exists in Apple's frameworks.

- **Cloud diarization.** Send audio to a hosted diarizer.
  - **Why rejected:** disqualified by the local-first threat model ([CLAUDE.md](../../CLAUDE.md) rule #1; [ADR-0004](0004-no-cloud-asr.md)). Audio never leaves the machine.

## Consequences

**Positive:**
- ~2.5× lower diarization error on the metric that matters (DER), same library, same dependency pin — the 69-segments-for-239-utterances failure goes away.
- The fix is a localized engine change: swap the manager and the assignment input; the wire contract, vault format, RAM-audio strategy, and the rest of ADR-0016 are untouched.
- No new dependency, no new license surface, no new network socket.

**Tradeoffs accepted:**
- The offline pipeline is heavier per pass than a streaming chunk — but at ~60–70× realtime, irrelevant for batch-at-stop.
- We rely on FluidAudio's `OfflineDiarizerManager` API surface; a future major version could reshape it. Same exposure we already accept for the streaming API.

**Must remain true / revisit trigger:**
- The offline engine stays a **post-stop** pass off the live caption path — diarization never contends with WhisperKit on the ANE during capture ([ADR-0009](0009-utterance-id-overlap-rule-v2.md) contract intact).
- If dogfooding shows the offline pass too slow or too memory-hungry on real long meetings, revisit (the ADR-0016 spill-to-temp-WAV escape hatch still applies).

## Caveat — DER numbers are not cross-tool apples-to-apples

FluidAudio's headline DER uses a **lenient scoring protocol** (collar = 0.25 s, `ignoreOverlap = true`), so its absolute numbers are **not** directly comparable to pyannote's stricter protocol (which reports AMI SDM ≈ 22.7 %). Trust the **intra-FluidAudio** ranking — offline ≫ streaming, scored the *same way* — which is what this decision rests on. Treat any cross-tool absolute-DER comparison as **indicative only**, not a like-for-like leaderboard.

## Privacy / threat-model note

Unchanged from [ADR-0016](0016-phase-5-diarization.md). The offline pipeline is on-device CoreML / ANE; model weights cache in `~/Library/Application Support/Hark/` (rebuildable app-data, rule #2); v1 is anonymous "Speaker N", so embeddings are computed in-memory and discarded with the audio buffer — nothing on disk or wire (rule #5). First-run model download is public CoreML weights from HuggingFace over HTTPS, identical *in kind* to the WhisperKit precedent ([ADR-0003](0003-swift-whisperkit-engine.md)) and now ungated. **No audio leaves the device.**

## Open questions

- **Assignment rule against the new segments.** ADR-0016 §2's open question (time-overlap tie-break / partial-overlap / cross-talk) still stands, now resolved against the offline pipeline's overlap-aware segments — the exclusive-segment reconstruction should make this cleaner, but pin it against real 2–3-speaker audio.
- **`OfflineDiarizerManager` tuning knobs.** Window/overlap and VBx clustering parameters carry FluidAudio defaults; confirm the defaults hold up on real meeting audio before locking.

## References

- Hard rules: [CLAUDE.md](../../CLAUDE.md) (rules #1, #2, #5, #6); no-cloud-ASR: [ADR-0004](0004-no-cloud-asr.md); model-cache precedent: [ADR-0003](0003-swift-whisperkit-engine.md); live-path contract: [ADR-0009](0009-utterance-id-overlap-rule-v2.md)
- Supersedes pipeline choice in: [ADR-0016](0016-phase-5-diarization.md) §2
- FluidAudio AMI subset benchmark: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/BenchmarkAMISubset.md
- FluidAudio diarization getting-started (offline vs. legacy online): https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- FluidAudio README (license, models): https://github.com/FluidInference/FluidAudio/blob/main/README.md
- pyannote.audio: https://github.com/pyannote/pyannote-audio
- pyannote segmentation-3.0 (gated weights): https://huggingface.co/pyannote/segmentation-3.0
- sherpa-onnx speaker diarization: https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html
- NVIDIA streaming Sortformer (4-speaker, streaming-only): https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2
