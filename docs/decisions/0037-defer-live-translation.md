# ADR-0037: Defer live translation to the backlog — translation is an on-demand, post-stop action only

- **Date:** 2026-06-04
- **Status:** Accepted — implemented (on-device confirmation pending)
- **Deciders:** Dang Anh Tuan
- **Supersedes (in part):** [ADR-0035](0035-live-translation-arbitrary-target.md) — the *live* (translate-during-capture) portion. The post-stop, structured translation path it introduced is KEPT and is now the only translation surface.
- **Builds on:** [ADR-0036](0036-grow-in-place-finalization.md) (the structured per-utterance render that mirrors the original transcript), [ADR-0031](0031-llm-egress-redaction.md) / [ADR-0029](0029-llm-provider-in-main.md) (egress governance).

## Context

We shipped two flavours of *live* translation — translating captions AS THEY LAND:

- **§2 → English:** on-device, zero egress. The engine flips WhisperKit to
  `task: .translate`, so any spoken language shows up as English captions.
- **§3 → arbitrary target:** there is no on-device model for non-English targets
  (NLLB was deferred), so each finalized caption line was sent to the configured
  LLM (`LlmService.translateSegment`), with the translation shown under the
  original line (a bilingual live view). `LiveTranslationService` orchestrated it.

In practice live translation proved **expensive to iterate and brittle to use**:

1. **Hard to test.** Verifying it needs a real capture, a real model, and live
   speech — a slow loop, and timing-dependent (it interacts with the streaming
   finalization watermark, ADR-0019).
2. **Timeout-prone** on a small local model (the realistic M1/16 GB setup): per-line
   LLM calls during a live meeting either lag the captions or time out.
3. **Messy live view.** Interleaving a translated line under each original — while
   the finalization watermark retracts/supersedes lines (ADR-0009/0019) — produced
   a visually confusing, churny transcript. The user repeatedly hit half-translated
   / mis-ordered states.

Meanwhile the thing the user actually wants — **a faithful translated transcript in
the saved note** — is better served *after* the meeting stops, when the transcript
is clean, deduped, diarization-labeled, and stable. That path already exists
(ADR-0036's structured per-utterance render) and is cheap to test deterministically.

## Decision

**Remove live translation from the product and put it in the backlog. Translation
becomes an on-demand, post-stop action only.**

Concretely:

- **UI removed:** the `→ EN` toggle (§2) and the `→ translate…` arbitrary-target
  picker (§3) are gone from the controls bar; the per-line live `translation`
  binding is gone from the transcript; the auto-translate-on-stop trigger
  (`maybeAutoTranslateOnStop`) is gone.
- **Orchestrator removed:** `LiveTranslationService` is deleted, along with the
  renderer hooks that only it used — `EngineService.segmentFinalized$` and
  `EngineService.setSegmentTranslation`.
- **On-demand path is now canonical:** the Translate panel (opened from the
  saved-meeting card) is the single translation surface. It was rewired from the
  legacy whole-transcript *blob* path (`LlmService.translate` →
  `EngineService.writeTranslation` → engine `appendTranslation`) to the
  **structured background job** (`TranslationJobService` → `translateSegment`
  per utterance → `EngineService.writeTranslationLines` → engine
  `appendTranslationStructured`). The engine renders the `## Transcript — <lang>`
  section from its OWN retained per-utterance structure (label + wall-clock), a
  byte-for-byte structural mirror of the original (ADR-0036). Progress shows in the
  existing non-blocking banner; on completion the section is committed to the note.
- **Engine plumbing left DORMANT, not deleted** — so reviving live translation
  later is cheap. The engine still understands `capture.start`'s
  `translation:{…}` (the `task: .translate` path) and `translation.write`'s legacy
  `translation` blob; main still hosts `translateSegment` + the aggregated
  cloud-log. Nothing in the UI drives the live paths now: `capture.start` never
  sends `translateToEnglish`, and the panel uses the structured `lines` path.

## Why on-demand post-stop is the right shape

- **Faithful output.** The saved transcript is what users keep; the structured
  render (ADR-0036) mirrors speaker labels, wall-clock timestamps, and blockquote
  formatting. The blob path could not (it reconstructed timestamps and drifted
  line counts).
- **Cheaper, calmer egress.** A local model = zero egress; a cloud model redacts
  each line and records ONE aggregated metadata-only cloud-call entry (ADR-0031) —
  not one per line, and not during a live meeting where the user can't review it.
- **Deterministically testable.** The post-stop transcript is stable, so the path
  is covered by unit tests (engine: structured-translation + grow-in-place; the
  renderer job is a simple sequential loop).
- **Honest disclosure before commit.** The panel discloses local-vs-cloud egress
  (mirroring main's loopback test) before the user presses Translate.

## Consequences

**Positive** — simpler, calmer live transcript (no churny bilingual interleave); no
per-line LLM pressure during capture; the only translation output is the faithful,
mirrored, saved-note section; reduced live egress surface (no per-line cloud sends
mid-meeting); deterministic tests.

**Negative / accepted** — (1) **No real-time translated captions.** A user who
wanted to *read* a translation live no longer can; they translate after stopping.
Explicitly accepted — deferred, not abandoned. (2) **Dormant dead-ish code.** The
engine's `task: .translate` path, the legacy `translation` blob (`appendTranslation`
+ `LlmService.translate` + `EngineService.writeTranslation`), and `meetingSaved$`
remain but are now unused by the UI. Left in place deliberately to make revival
cheap; a later cleanup ADR may prune the legacy blob path if live translation isn't
revived. (3) **Cloud-log label.** The aggregated entry for the post-stop job still
uses the live-translation roll-up in main (`flushLiveTranslate`); the label is a
metadata string and accurate enough (translation egress), refine if it confuses.

## Backlog (when live translation returns)

- Ship an on-device non-English model (NLLB or Apple Translation) so §3 needs no
  cloud and no per-line LLM latency.
- Decouple live translation from the finalization watermark so the live view
  doesn't churn (translate only stable, committed lines, debounced).
- Re-introduce the `→ EN` / `→ target` controls + `LiveTranslationService` (git
  history has the removed implementation).

## Test / verification

- UI build green (`npm run build`, EXIT 0) after removal + rewire.
- Engine suite unchanged this turn (no engine edits) — the structured-translation
  + grow-in-place tests from ADR-0036 still pin the post-stop render.
- **Needs on-device confirmation:** capture a meeting in a non-English language →
  Stop → open Translate on the saved card → pick the target → the banner shows
  progress → the saved `.md` gains a `## Transcript — <lang>` section that mirrors
  the original's speaker labels + wall-clock timestamps. Confirm NO translate
  controls appear during capture.

## References

- ADR-0035 (live translation — the live portion this supersedes), ADR-0036
  (structured grow-in-place render reused here), ADR-0031 / ADR-0029 (egress
  governance), ADR-0019 / ADR-0009 (the finalization churn that made the live view
  hard).
- Removed: `ui/src/app/services/live-translation.service.ts`; `EngineService`
  `segmentFinalized$` + `setSegmentTranslation`; the controls-bar translate
  controls + auto-translate-on-stop in `app.component.{ts,html}`.
- Rewired: `ui/src/app/components/translate-panel.component.ts` (now launches
  `TranslationJobService`).
