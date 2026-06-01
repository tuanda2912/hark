# ADR-0018: Utterance supersession — a `segment.superseded` retraction signal

- **Date:** 2026-06-01
- **Status:** Accepted
- **Extends:** [ADR-0009](0009-utterance-id-overlap-rule-v2.md) — adds the retraction signal ADR-0009's identity rule never provided. ADR-0009's decision is unchanged.
- **Deciders:** Dang Anh Tuan

## Context

[ADR-0009](0009-utterance-id-overlap-rule-v2.md) settled how the engine assigns stable `utterance_id`s across WhisperKit re-segmentation passes: the max-denominator overlap rule mints a **fresh** `utterance_id` whenever a new segment's overlap with an existing entry drops below threshold. That rule's whole point is that **identity never drifts across content** — "Okay." can never silently mutate into a sentence about API security. It bought that guarantee by being willing to mint new IDs liberally.

But ADR-0009 stops there. It provides **no supersession or retraction signal**: when a later pass produces a longer, more-complete segment that *extends* an earlier short fragment of the same speech, the longer segment correctly gets its own fresh `utterance_id` (overlap-of-longer is small, so they don't match) — and the older short fragment's `utterance_id` is then **never retracted anywhere**. ADR-0009 §Consequences names this directly: "only the leftmost piece keeps the original UUID … the original entry becomes an orphan. The UI sees more `utterance_id`s." The orphan gets a synthetic closing `segment.final` on prune, but it is never *withdrawn*.

The consequence shows up on continuous-narration audio. A single spoken sentence surfaces as several overlapping, growing fragments, each finalized as a separate utterance — e.g. `"in Berlin with my partner,"` then `"I live in Berlin with my partner, and I have one younger brother."` — and post-stop diarization can even assign the fragments to **different speakers**. This is visible in **both** surfaces:

- **Live captions** — the engine only ever *adds* finals, and the UI segment map is **upsert-only** (it deletes a segment only on user Clear). Nothing tells it the short fragment was subsumed.
- **The saved meeting file** — the at-stop vault writer ([ADR-0016](0016-phase-5-diarization.md)) retains every final. A recently-added at-stop **exact-text** dedup cannot catch these: the fragments have different `utterance_id`s and are **prefix/superset variants**, not exact-text-equal.

The root cause is singular — the missing retraction signal — but it leaks into two places because two consumers (the live UI map and the at-stop writer) both treat finals as monotonic.

## Decision

Add one Engine→UI wire frame, **`segment.superseded`**, payload `{ utterance_id, superseded_by }` (snake_case on the wire, per the protocol convention). The engine emits it when a later, **time-overlapping**, more-complete re-segmentation supersedes an earlier fragment of the same speech: the engine **retracts** the older `utterance_id`, the UI **deletes** it from its segment map, and the at-stop vault writer **filters it out** of the retained set. One signal, applied at the source, fixes both surfaces.

**Supersession is gated on TIME-OVERLAP + a prefix/superset (extension) relationship — never on text similarity alone.** A new segment supersedes an older one only when their intervals overlap *and* the new text extends the old (the old is a prefix/subset of the new). This is precisely what protects legitimate **repeated phrases** — the same words spoken again at a *different, non-overlapping* time (common in e.g. language-lesson audio, call-and-response, drills): a non-overlapping repeat has **zero overlap** and is therefore **never** superseded. Text-equality is necessary-ish but never sufficient; the time gate is load-bearing.

The frame touches the validated live caption path **additively**: it is a new retraction message plus a UI delete. The partial→final lifecycle from ADR-0009 — partials upsert, `segment.final` is terminal — is **unchanged**. Supersession is a separate, later event about an already-finalized fragment, not a mutation of one.

## Alternatives considered

- **Write-only at-stop prefix/overlap collapse** — fold prefix/superset fragments together only in the vault writer, leaving the wire alone.
  - ✅ Pros: smallest change; no wire or UI work; fixes the saved file.
  - ❌ Cons: treats the symptom in **one of two places** — live captions stay fragmented and mis-attributed for the whole meeting; duplicates the overlap logic in the writer instead of at the source.
  - **Why rejected as the solution.** Acceptable only as a temporary half-measure: if a stopgap is needed before the frame lands, a write-only collapse is tolerable, but it is not the fix. The retraction signal is.

- **Text-similarity dedup without a time-overlap gate** — merge finals whose text is similar/contained regardless of when they occurred.
  - ✅ Pros: catches the fragments with simple string logic.
  - ❌ Cons: **eats legitimate repeats.** The same phrase at two different times — a teacher repeating a sentence, a chant, a drill — would be wrongly collapsed into one. This is the exact failure ADR-0009 §Alternatives flagged when it rejected a text-similarity tie-breaker.
  - **Why rejected.** Identity decisions in Hark are time-grounded by design; dropping the time gate trades one visible bug for a worse, silent one.

- **Change when `segment.final` is emitted** — defer or coalesce finals so fragments never get finalized separately.
  - ✅ Pros: no new frame.
  - ❌ Cons: reopens the **validated live partial/final lifecycle** ([ADR-0009](0009-utterance-id-overlap-rule-v2.md) assumption that `segment.final` is terminal), the riskiest surface to touch; and it still doesn't address the root cause — the missing retraction — it just hides it behind finalization timing.
  - **Why rejected.** Higher blast radius, wrong layer. The lifecycle stays locked; supersession is layered on top of it.

## Consequences

**Positive:**
- **Both surfaces fixed from one signal.** Live captions stop showing the same sentence as stacked overlapping fragments; the saved file retains one coherent utterance instead of prefix/superset duplicates — and the cross-speaker mis-attribution of orphan fragments goes away with them.
- **Additive to the locked live path.** A new retraction frame + a UI map delete. ADR-0009's partial→final contract and the max-denominator identity rule are untouched.
- **Legitimate repeats are safe by construction.** The time-overlap gate means a non-overlapping re-utterance of the same words is structurally exempt — no heuristic, no tuning, can wrongly merge them.
- **One consumer rule, two readers.** The engine decides supersession once; the UI delete and the writer filter both key off the same `superseded_by` relationship.

**Tradeoffs accepted:**
- **A new wire frame to keep in lockstep** — the Swift struct, the TS interface, and both handlers must agree (the standard four-edit-point cost for any frame).
- **A second utterance-identity mechanism alongside the overlap rule.** ADR-0009 mints fresh IDs to avoid drift; this ADR retracts some of those mints when they turn out to be subsumed fragments. The two must stay coherent: supersession only ever retracts an *older, contained* fragment in favour of a *newer, extending* one — never the reverse, and never across a non-overlap.
- **Retraction is forward-only and in-flight.** It applies to the live map and the at-write retained set; it does **not** rewrite history already committed to the vault (see Open questions / privacy note).

**Must remain true / revisit trigger:**
- The supersession gate stays **time-overlap AND prefix/superset** — never text-similarity alone. If that gate is ever loosened to text-only, this ADR is being violated and legitimate repeats will be eaten; that needs a new ADR and a hostile-input review.
- `segment.superseded` stays a **post-final** event about an already-emitted fragment. It must never become a way to mutate a live partial or retract a still-growing utterance — that would reopen the ADR-0009 lifecycle this ADR is careful not to touch.
- The retraction must be **idempotent and order-tolerant** on the UI side: a delete for an `utterance_id` the map no longer holds is a no-op, not an error.

## Privacy / threat-model note

No new persistence and no new network surface. `segment.superseded` carries only **two opaque `utterance_id`s** over the **existing localhost WebSocket** — no transcript text, no audio, no PII. Supersession only *removes* an in-flight fragment from the retained set; it never writes anything new, and it never touches vault files already committed (the vault stays immutable per [ADR-0015](0015-transcript-vault-persistence.md) §4 / [CLAUDE.md](../../CLAUDE.md) rule #4). Unchanged from prior ADRs: **nothing leaves the machine.**

## Open questions

- **Prefix/extension detection thresholds in the ledger.** The exact rule for declaring "the older fragment is a contained prefix/subset of the newer, overlapping one" needs tuning so genuine supersession is caught **without over-retracting** — too loose and we eat distinct adjacent utterances, too tight and fragments leak through to both surfaces again. Calibrate against real continuous-narration audio (the Berlin-sentence trace) plus a language-lesson/repeat trace as the negative control.
- **Retraction from already-written history.** Whether superseded IDs should also be withdrawn from meeting files already on disk is **out of scope**: vault files are immutable ([ADR-0015](0015-transcript-vault-persistence.md) §4, rule #4). This signal applies to the **in-flight** live map and the **at-write** retained set only. A retroactive rewrite would be a separate ADR with its own git-discipline review.
- **Interaction with diarization re-attribution.** Since superseded fragments are dropped before the at-stop diarization assignment ([ADR-0017](0017-diarization-offline-pipeline.md)), the cross-speaker split of fragments should resolve as a side effect; confirm against real 2–3-speaker audio that dropping the fragment never removes the only segment covering a span.

## References

- Extends and depends on: [ADR-0009](0009-utterance-id-overlap-rule-v2.md) — max-denominator overlap rule, fresh-ID mint, orphan finalization (the identity decisions this ADR adds a retraction signal to)
- Live-path lifecycle preserved: [ADR-0009](0009-utterance-id-overlap-rule-v2.md) §Assumptions (`segment.final` is terminal)
- At-stop vault writer the filter applies to: [ADR-0016](0016-phase-5-diarization.md) §4, [ADR-0017](0017-diarization-offline-pipeline.md)
- Vault immutability (no retroactive rewrite): [ADR-0015](0015-transcript-vault-persistence.md) §4; [CLAUDE.md](../../CLAUDE.md) rule #4
- Wire protocol / frame shape (snake_case, four edit points): `engine/Sources/Harkd/WireProtocol.swift`, `ui/src/app/services/engine.types.ts`, and the `add-wire-frame` discipline
- Identity rule + ledger this signal layers onto: `engine/Sources/Harkd/SlidingWindow.swift` (`UtteranceLedger`)
