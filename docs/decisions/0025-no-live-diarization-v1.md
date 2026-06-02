# ADR-0025: No live speaker diarization in v1 — post-stop labeling + enrollment instead

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

We prototyped **live (streaming) speaker diarization** to paint provisional "who's
speaking now" labels on the transcript *during* recording — wrapping FluidAudio's
streaming `DiarizerManager` in a `LiveDiarizer` actor, teeing the live audio in 5 s/2 s
chunks, tagging emitted segments with provisional "Speaker A/B" labels, behind an opt-in
`capture.start` `live_diarization` flag with a tunable `HARK_LIVE_DIAR_THRESHOLD`.

On-device testing on **real meetings** failed it decisively:

- A live **5-person remote meeting (system audio)** collapsed **all** speakers into one
  (`provisional speakers=1`), even after lowering the clustering threshold from the 0.7
  default to 0.55 (and the knob was confirmed active in the logs).
- The tell-tale: the **accurate offline pass** (VBx) on the *same* audio also under-clustered
  badly — **2 speakers for 5 people**. When the *good* diarizer also collapses, the limiter
  is **the audio**, not the live threshold.

The root cause is fundamental, not a bug: a remote meeting captured via **system audio** is
**one mixed, VoIP-codec-compressed stream**. The codec smears the very voice characteristics
diarization relies on, and the participants are already blended into a single output. Cloud
tools (Teams, Meet, Zoom) appear to diarize live only because they ingest a **separate audio
stream per participant** from the meeting API — they are not separating a mixed stream. Hark
is local-first with no meeting-API/auto-join integration (out of scope per the handoff), so we
have only the mixed stream. Far-field in-person room audio (5 overlapping voices on one mic) is
similarly hard. FluidAudio itself flags its streaming diarizer as the weakest path
("struggles with overlapping speech with more than 2 speakers, similar-sounding speakers,
short utterances").

## Decision

**Do not ship live diarization in v1.** Speaker labels appear **only after `capture.stop`**,
from the accurate offline pass + the `meeting.transcript` back-annotation (ADR-0024). Speaker
**tagging is post-stop only** (already the case — there is no live roster to tag). This avoids
showing confidently-wrong live labels, which is worse than showing none.

Instead, invest in **speaker enrollment (Phase 5.1)**: when the user names a speaker post-stop,
store that speaker's voiceprint locally (`vault/.speakers/`, rule #5); in future meetings,
**after recording stops**, auto-recognize known voices by matching the offline embeddings. This
runs on the *accurate* offline pipeline (not the flaky live one) and delivers real
cross-meeting value.

The prototype is **preserved on the `experimental/live-diarization` branch** (commit
`b4fc64e`), not deleted — in case per-participant capture or materially better on-device
streaming diarization makes it viable later.

## Alternatives considered

- **FluidAudio streaming `DiarizerManager` live** (what we prototyped).
  - ❌ Collapses on real multi-party / mixed / remote audio (1 of 5 on-device); FluidAudio's
    weakest, heaviest online path. Also added a streaming-model load to startup.
  - **Why rejected:** doesn't work on the audio our users actually have.
- **Tune the live threshold harder** (lower `HARK_LIVE_DIAR_THRESHOLD`, expose `minSpeechDuration`).
  - ❌ The offline pass *also* got 2/5 on the same audio — the ceiling is the audio, not the knob.
  - **Why rejected:** diminishing returns against a fundamental limit.
- **Per-participant stream capture** (like Teams/Meet).
  - ❌ Requires meeting-API / auto-join integration — explicitly out of scope (handoff).
- **Other streaming models** (diart, Streaming Sortformer, sherpa-onnx).
  - ❌ New deps / ONNX runtime; and even our *offline* pass struggles on this audio class, so a
    different streaming model is unlikely to clear the same audio bar.

## Consequences

**Positive**
- Honest UX: no confidently-wrong live labels. Captions stay clean + fast during recording.
- Simpler engine; removes the streaming-model startup cost.
- Focus shifts to **enrollment**, which is achievable and genuinely valuable.

**Negative / tradeoffs accepted**
- No live "who's speaking" indicator. Accepted — accurate post-stop labels are the value, and
  live multi-party diarization isn't reliably solvable on-device today.

**What needs to remain true / revisit triggers**
- Revisit if (a) Hark ever gains per-participant capture, or (b) on-device streaming diarization
  improves enough to separate mixed/compressed multi-party audio. The prototype branch is the
  starting point.

## References

- ADR-0017 (offline diarization pipeline), ADR-0024 (post-stop transcript back-annotation),
  ADR-0016 (Phase 5 diarization; enrollment is Phase 5.1)
- `experimental/live-diarization` branch (`b4fc64e`) — preserved prototype
- On-device 5-person remote-meeting test, 2026-06-02 (`provisional speakers=1`, offline 2/5)
- `docs/BACKLOG.md` — speaker enrollment (now the active next step)
