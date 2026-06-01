# ADR-0020: Post-save speaker relabeling (in-app speaker rename)

- **Date:** 2026-06-01
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Diarization auto-assigns `Speaker N` labels in a post-stop batch pass (see ADR-0017,
offline pipeline). On real meetings these labels skew: multiple distinct people
collapse onto one label — pronounced when capturing a single mixed audio channel.
On the 2026-06-01 test clips, a two-person interview rendered ~28 of 31 lines as
`Speaker 1`. Users need to correct this by assigning real names ("Alice", "Bob").

The tempting fix — pin the speaker count (`HARK_DIAR_NUM_SPEAKERS=2`) — was rejected:
it breaks any meeting whose true count differs (a 5-person standup crushed into 2
clusters is strictly worse). A clustering-threshold tune (`HARK_DIAR_THRESHOLD`) is
count-agnostic but risks overfitting to the only test material we have (one 2-person
clip) and can't be validated for N>2 without more recordings. Neither gives the user
recourse when the diarizer is *confidently wrong*.

The count-proof fix is user relabeling — correct the labels regardless of how many
speakers there are. A constraint surfaced while designing: the **live transcript
carries no speaker labels at all** (`segment.final` ships `speaker: nil`); labels
exist only *after* the stop-time diarization pass, by which point the meeting markdown
is already written to the vault. So relabeling is necessarily a **post-save** operation.

## Decision

The meeting is saved immediately on `capture.stop` (unchanged — never risk losing a
recording). The engine retains the just-saved meeting's structured data in memory
(`SavedMeetingSnapshot`). A new UI→engine command `speaker.rename {session_id,
names:{label:name}}` lets the user assign real names from the roster the meeting-saved
card already shows; the engine **re-renders the same markdown file from the retained
structured data** (not find/replace) with the new labels and **re-commits** it to git.
MVP scope: only the most-recently-saved meeting (the one whose card is showing) is
renameable.

## Alternatives considered

- **Pin speaker count (`HARK_DIAR_NUM_SPEAKERS`)** — force the diarizer to N clusters.
  - ✅ Trivially fixes the 2-person clip.
  - ❌ Breaks every meeting with a different true count.
  - **Why rejected:** not count-proof; the user explicitly flagged multi-person meetings.
- **Clustering-threshold tune only (`HARK_DIAR_THRESHOLD`)** — count-agnostic sensitivity knob.
  - ✅ Improves separation for any N; no count assumption.
  - ❌ Can't validate for N>2 with current test material; risks silent regression on
    multi-person meetings; still no user recourse when the split is wrong-but-confident.
  - **Why rejected as the *sole* fix:** complementary, not sufficient. Worth doing later
    once we have 3–4 person test clips to validate against.
- **Live relabel during the meeting** — rename from the live caption stream.
  - ❌ Architecturally impossible: no labels exist live (`speaker: nil` until the
    post-stop pass).
  - **Why rejected:** precluded by the pipeline shape.
- **Defer the save until names are assigned** (`meeting.ready` → name → commit once).
  - ✅ Single git commit per meeting.
  - ❌ Introduces a "pending unsaved meeting" state that risks losing the recording if
    the app closes; adds latency and state.
  - **Why rejected:** robustness (always-save-on-stop) beats a tidier git history.
- **No in-app feature — edit the markdown in your own editor.**
  - ✅ Already works; the vault is plain markdown in git.
  - ❌ Poor UX; no roster/color context; doesn't feed future enrollment.
  - **Why rejected as the only answer:** in-app rename is the on-ramp. Manual editing
    remains a valid escape hatch and is unaffected.
- **Find/replace rewrite of the saved file.**
  - ❌ Fragile — a transcript line literally containing "Speaker 1" would be corrupted.
  - **Why rejected:** re-rendering from retained structured data is clean and idempotent.

## Consequences

**Positive**
- **Count-proof:** works identically for 2 or 20 speakers; no count assumption, no
  overfitting risk.
- **Robust:** the meeting is always saved on stop; rename is an optional refinement.
- **Vault-sacred:** rename re-renders + re-commits (recoverable history), is
  user-initiated, and writes only the meeting's own file at its stored path. Audited:
  the wire payload carries no path and cannot redirect the write (`session_id` is an
  equality guard; the engine uses the stored snapshot's `vaultPath`).
- **Local-only:** names live in the vault + the in-memory snapshot; never sent anywhere.
  `meeting.saved` still broadcasts anonymous labels (`matchedName: nil`).
- **Reuses existing surfaces:** the toast roster (UI) and the `VaultWriter`
  render→write→git-commit path (engine).

**Negative / tradeoffs accepted**
- MVP renames only the **most-recently-saved** meeting (engine holds one snapshot in
  memory). Renaming an arbitrary past meeting needs a meeting browser — deferred.
  (Manual markdown edit remains available meanwhile.)
- **Two git commits** per renamed meeting (save, then rename) rather than one.
- **No positive "renamed ✓" confirmation frame** — the UI is optimistic and keys off
  `ack`; only failures surface via `error`. Acceptable for MVP; a correlation `id` or a
  `meeting.updated` frame can add confirmation later.
- The underlying **diarization skew is unchanged** — relabeling corrects the *output*,
  it doesn't improve the clustering. Threshold tuning (with real multi-speaker clips)
  and enrollment remain complementary future work.

**What needs to remain true**
- The engine retains enough structured data post-save to re-render the file identically
  except for labels.
- The vault stays plain markdown in a local git repo, so re-render + re-commit is the
  natural mechanism.

## Open questions

- Auto-recognize known speakers across meetings (enrollment, `vault/.speakers/*.json`)
  — deferred to Phase 5.1.
- Renaming arbitrary past meetings (needs a meeting browser + persisting/reloading the
  snapshot, or re-parsing the saved file).
- A success-confirmation frame (`meeting.updated`) vs the current optimistic + `ack`.
- Reconcile the `error.code` catalog and the stale `segment.final` `speaker` example in
  `docs/design/08-websocket-api-contract.md` (flagged by the wire review; out of scope
  here).

## References

- ADR-0009 (utterance-id reconciliation), ADR-0015 (transcript→vault persistence),
  ADR-0016 (diarization), ADR-0017 (offline diarization pipeline),
  ADR-0019 (region-based finalization)
- `docs/design/08-websocket-api-contract.md` — `speaker.rename` frame (supersedes the
  `speaker.tag` sketch)
- Wire-symmetry verification + privacy audit (this session)
