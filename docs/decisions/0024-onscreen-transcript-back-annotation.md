# ADR-0024: On-screen transcript speaker back-annotation at stop

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Diarization is **offline** (ADR-0017): it runs as a batch pass at `capture.stop`, not
live. So every live `segment.final` ships `speaker: null` — during a meeting the engine
genuinely doesn't know who's speaking. At stop the engine labels the utterances, writes
them to the vault markdown, and broadcasts `meeting.saved` (the speaker **roster**) — but it
never sent the **per-line** labels back to the on-screen transcript. Result (user-reported):
the Attendees panel and the saved `.md` show names, but the transcript pane stays
speaker-less, diverging from the design (where every line is attributed —
`01-mw-dark` shows "ALICE CHEN · …" per line). The live view also shows partial/duplicate
churn that the saved file doesn't.

## Decision

Add an additive engine→UI frame **`meeting.transcript`** `{ session_id, utterances:
[{ id, t_start, text, speaker }] }`, emitted at stop **just before `meeting.saved`**, carrying
the **same deduped, "Speaker N"-labeled utterances written to the vault**. The UI **replaces**
its live transcript with this set, so:

- every line shows its speaker, colored consistently with the Attendees roster (a single
  centralized `speakerColorFor(label)` mapping drives both surfaces);
- the messy live partials/duplicates are replaced by the clean final — the on-screen
  transcript now matches the saved markdown exactly;
- **renames propagate**: renaming "Speaker 1" → "Alice" (tagging modal / saved card)
  optimistically relabels + recolors every transcript line spoken by Speaker 1.

Honest behavior preserved: **during** capture the transcript has no speaker labels (we don't
know yet); **at** stop it becomes fully attributed. `meeting.saved` stays the roster source;
`meeting.transcript` is the per-line source.

## Alternatives considered

- **Re-emit `segment.final` with speakers in place** (patch the existing on-screen segments).
  - ❌ The deduped/labeled final set differs from the live `segment.final` stream (dedup +
    supersession collapse rows; ids don't line up). In-place patching is fragile.
  - **Why rejected:** a full replacement is clean and guarantees on-screen == saved file.
- **Live (streaming) diarization** — attribute speakers in real time.
  - ❌ Large engine change; we deliberately chose offline for ~2.5× lower DER (ADR-0017).
  - **Why rejected/deferred:** quality-driven offline stance stands; live attribution is a
    future option (BACKLOG / a new ADR if pursued).
- **Carry the labels only in the roster** (status quo).
  - ❌ Leaves the transcript unattributed — the actual gap.

## Consequences

**Positive**
- The transcript matches the design (per-line speakers) and the saved file (deduped + labeled).
- Renames relabel the transcript live; Attendees + transcript colors agree.
- Stop cleans up the live partial/dup churn automatically.

**Negative / tradeoffs accepted**
- The live transcript still has no speakers until stop — inherent to offline diarization.
- `meeting.transcript` carries no per-line `t_end`; the UI synthesizes `tEnd = tStart`, so a
  bookmark landing exactly on a labeled line's start won't show as pinned post-stop (minor;
  bookmark persistence is itself a BACKLOG item). Fix later by adding `t_end` to the frame or
  deriving it from the next utterance's start.
- The frame isn't snapshot-replayed to a client that connects after stop — it's an
  active-session back-annotation (acceptable; the saved file is the durable record).

**What needs to remain true**
- Diarization stays offline (if live diarization lands, revisit this whole flow).
- The frame keeps reusing the exact deduped/labeled vault set — never a re-derived set.

## Open questions

- Add `t_end` per utterance for post-stop bookmark-pin fidelity?
- Cross-meeting speaker recognition (Phase 5.1 enrollment) so the transcript shows real
  names without a per-meeting rename.

## References

- ADR-0017 (offline diarization pipeline), ADR-0020 (speaker rename), ADR-0009 (utterance ids)
- `docs/design/08-websocket-api-contract.md` — `meeting.transcript` frame
- Design: `hark-docs/docs/design/ui/screenshots/01-mw-dark.png` (per-line speakers)
- Engine: `WireProtocol.swift`, `EngineSession.swift`. UI: `engine.types.ts`,
  `engine.service.ts`, `app.component.*`, `attendees-panel.component.ts`
