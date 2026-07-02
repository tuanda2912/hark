# ADR-0039: Spill continuous capture audio to a temp WAV for the diarization pass

- **Date:** 2026-07-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

The offline diarization pass (ADR-0016) needs the **whole meeting's** continuous
16 kHz mono Float32 PCM at stop — every mixed frame batch including silence, so its
sample timeline maps 1:1 to the wall-clock session time the transcript segments are
emitted against. That shared time axis is what makes the max-overlap speaker
assignment correct.

ADR-0016 §5 held this in a live `[Float]` buffer (`sessionAudio`) in the
`EngineSession` actor, growing for the whole meeting and freed only at
`capture.stop`. That grows **~3.75 MiB/min (~225 MiB at 1 hr)**, and worse, Swift's
`Array` amortized-doubling means a transient **~2× spike toward ~450 MiB** during
the reallocation as the backing store doubles. On long meetings this fills RAM and
pushes the machine into swap — which also drags the live transcription latency
budget (< 1.5 s spoken → visible) it shares the actor with. The original
declaration comment already named the fix ("spill-to-temp-WAV is the escape hatch")
but never built it.

Prior related decisions: ADR-0016 (offline diarization), ADR-0027 (privacy &
data-control model), ADR-0028 (opt-in meeting-audio persistence — a *different*,
persistent artifact; see the reconciliation below).

## Decision

**Stream the continuous capture audio to a temp WAV during capture; read it back
once at stop.** Concretely:

- A new `SessionAudioSpill` opens one temp WAV per session (only when a diarizer is
  attached — else it'd be wasted I/O) at `capture.start`. Frames are **appended as
  they arrive on the actor** (the same actor-executor placement the old
  `append(contentsOf:)` had — never the audio pump thread), so harkd's in-RAM
  footprint for captured audio stays **flat** (only the OS write buffer, not the
  whole recording).
- **Format matches the captured stream losslessly:** 16 kHz, mono, **32-bit IEEE
  float** PCM (WAV format code 3, 32 bits/sample). Deliberately *not*
  `HarkCore.WAVWriter`, which is 16-bit integer (format 1) and would quantize —
  read-back must return the exact `[Float]` the old in-RAM buffer held so
  diarization quality is byte-identical. The writer emits a 44-byte header with
  placeholder sizes and **patches the RIFF + data chunk sizes on finalize** (seek
  back, rewrite), the same streaming seek-and-patch shape `WAVWriter` uses.
- **Location (hard rule #2):** `~/Library/Application Support/Hark/tmp/`
  (`HarkPaths.appSupportDir()/tmp/`), one uniquely-named file per session
  (`harkd-spill-<uuid>.wav`). **Never** the vault, **never** networked.
- **At stop**, `flushOnStop` detaches the spill, finalizes it, and reads it back
  fully **once, transiently** into `[Float]` — feeding both the diarizer
  (`OfflineDiarizerManager.process(audio:)` takes the whole array) and, when
  `keep_audio` is on, the existing `AudioStore` vault write. The `diarizer != nil`
  gating and the `keep_audio` behavior are **identical** to before. The whole
  buffer is materialized only for this stop, not held for the meeting.
- **Secure-delete** the temp file after both consumers finish at stop, on abnormal
  teardown (`deinit`), and via a **startup sweep** that purges any spill a prior
  crashed session left behind. Secure-delete = best-effort zero-overwrite (bounded
  1 MiB chunks) then unlink.

## Alternatives considered

- **Keep the full recording in a live `[Float]` (status quo, ADR-0016 §5).**
  - ✅ Simplest; no disk I/O; read-back is free.
  - ❌ **This is the leak** — ~225 MiB/hr resident, ~2× transient reallocation
    spikes, swap on long meetings, and it competes for RAM with the live path.
  - **Why rejected:** it's the exact bug this ADR fixes.

- **Online / chunked diarization** (diarize incrementally during capture, discard
  audio as it's consumed).
  - ✅ Would remove the need to retain the whole meeting at all.
  - ❌ Materially more work; ADR-0025 already deferred *live* diarization for v1,
    and incremental clustering carries a real **speaker-clustering quality risk**
    (global VBx clustering over the whole meeting is what makes the current
    assignment accurate on rapid back-and-forth).
  - **Why rejected/deferred:** out of scope for a memory fix; revisit if the
    transient at-stop read-back itself becomes a problem.

- **Compress the spill (AAC/Opus) instead of Float32 WAV.**
  - ✅ ~10× smaller on disk.
  - ❌ Adds an encode/decode path and would lossily alter the samples the diarizer
    (and, when opted in, the persisted vault audio) sees.
  - **Why rejected:** the win here is RAM, not disk; WAV keeps the samples exact
    and the code trivial. (Compression for the *persistent* keep-audio artifact is
    already a tracked ADR-0028 optimization, separately.)

- **Spill under the vault instead of app-support.**
  - ❌ Violates the storage rule — this is transient, rebuildable, secure-deleted
    scratch, not user content.
  - **Why rejected:** see the privacy analysis below.

## Privacy analysis

Raw audio now touches disk where before it lived only in RAM — so this is a
threat-model decision, reconciled explicitly with the hard rules:

- **Hard rule #2** permits app data under `~/Library/Application Support/Hark/`, and
  *forbids* transcripts/audio/PII **outside the vault**. The spill is **transient,
  rebuildable scratch** for the diarization pass — not a durable user artifact — so
  app-support is exactly where it belongs (same class as the model cache and the RAG
  index in `HarkPaths`). It is **never** written to the vault and **never**
  networked.
- **Reconciliation with ADR-0028** (which *rejected* app-support for meeting audio):
  no contradiction. ADR-0028 concerns the **persistent, user-facing** keep-audio
  artifact — that is durable user content and correctly lives in `vault/.audio/`,
  gitignored, opt-in, deletable. This ADR concerns an **ephemeral** buffer that is
  **secure-deleted before the stop flush returns**. Different lifetime, different
  class, different home. The two coexist: the spill is read back and, *if*
  `keep_audio` is on, its samples are written to the vault by `AudioStore` exactly
  as before — the persistent copy's policy is unchanged.
- **Lifetime is bounded three ways:** secure-deleted after diarization at
  `capture.stop`; secure-deleted on abnormal teardown via the actor's `deinit`;
  and a startup sweep purges any spill orphaned by a crash. So even a hard crash
  mid-meeting leaves at most one file that the *next* launch erases.
- **Logging (rule #3):** no path that leaks meeting content and never the samples —
  log lines carry a session uuid + sample/byte counts + purge counts only.
- **Secure-delete is best-effort, and we say so honestly:** on APFS (copy-on-write,
  SSD wear-levelling) the OS offers no primitive to guarantee the original physical
  blocks are erased. The zero-overwrite is defense-in-depth; the real guarantees are
  that the file lived only in local app-support, never left the machine, and is gone
  from the filesystem namespace before the process exits.

## Consequences

**Positive**
- harkd's in-RAM footprint for captured audio is now **flat** regardless of meeting
  length — no ~225 MiB/hr growth, no ~2× reallocation spike, no swap pressure on the
  actor that also runs the live latency-critical path.
- Diarization quality and the `keep_audio` behavior are **unchanged** — the read-back
  reconstructs the exact Float32 samples the old buffer held.
- Fully inside the privacy model: local app-support only, never vault, never
  networked, secure-deleted on stop/crash/startup.

**Negative / tradeoffs accepted**
- Raw audio touches disk during the meeting (previously RAM-only). Mitigated by
  app-support-only placement + triple secure-delete + honest best-effort-wipe
  caveat above.
- A **transient full read-back at stop** briefly materializes the whole meeting as
  `[Float]` (~225 MiB at 1 hr) to hand to the diarizer, which needs the full array.
  This is a one-shot allocation at stop, off the live path — the win is not holding
  it for the *whole meeting*. If this at-stop spike itself ever bites, the follow-up
  is chunked/online diarization (deferred above).
- Per-frame file writes on the actor add I/O the old `append` didn't. It's off the
  audio pump (the actor bounces frames in via a Task) and sequential appends to a
  local file are cheap, so this doesn't touch the audio callback or the RTF budget.

**What needs to be true for this to remain the right call**
- The diarizer keeps requiring the **full** buffer at stop. If FluidAudio grows a
  streaming/file-input API, we can drop the transient read-back entirely.
- App-support stays the sanctioned home for rebuildable scratch (it is, per rule #2
  and `HarkPaths`).

## Open questions

- Streaming the spill *into* the diarizer without a full `[Float]` read-back (needs
  a FluidAudio file/chunk-input API) — would remove the last at-stop RAM spike.
- Whether `finalizedUtterances` (the minor secondary in-RAM grower) is worth the
  same treatment — left alone here, out of scope.

## References

- ADR-0016 (offline diarization — the §5 memory bound this supersedes), ADR-0025
  (no live diarization v1), ADR-0027 (privacy & data-control model), ADR-0028 (opt-in
  meeting-audio persistence — the *persistent* artifact, distinct from this spill)
- `engine/Sources/Harkd/SessionAudioSpill.swift`,
  `engine/Sources/Harkd/EngineSession.swift` (`ingestFrames`, `flushOnStop`,
  `startCapture`, `deinit`), `engine/Sources/Harkd/HarkdCommand.swift` (startup sweep)
- `engine/Sources/HarkCore/HarkPaths.swift` (app-support base),
  `engine/Sources/HarkCore/WAVWriter.swift` (the Int16 sibling; format contrast)
