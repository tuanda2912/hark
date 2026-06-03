# ADR-0035: Live translation to an arbitrary target language — per-segment LLM (opt-in), defer local MT model + Apple Translation

- **Date:** 2026-06-03
- **Status:** Accepted — Option C implemented (automated gates green; on-device confirmation pending)
- **Deciders:** Dang Anh Tuan

## Context

Translation §1 (end-of-meeting, [`llm.translate`]) and §2 (live → English, WhisperKit `task:.translate`)
shipped. The remaining piece is **§3: LIVE translation to an ARBITRARY target** — e.g. a Thai
meeting showing live **Vietnamese** captions, or English → live Thai. Two facts narrow it:

- **End-of-meeting → any language is ALREADY solved by §1** (the LLM translates the whole saved
  transcript to any language the user picks). So §3 is *only* about the **live, real-time,
  per-segment** case.
- **Live → English is ALREADY solved by §2** (free, on-device, single Whisper decode). §3 is about
  targets **other than English**, which Whisper's `.translate` can't produce.

So §3 = "as the meeting runs, show each finalized line translated into a chosen non-English
language." That's genuinely hard on-device, and there's no clean winner — hence this ADR.

The wire + UI are **half-ready**: `capture.start.translation` carries `{enabled, mode, target_lang}`,
`segment.translation` exists on the wire, and `TranscriptLine` already renders a translation under
the original. What's missing is the translation *engine* for non-English targets.

## Options

### A. Local MT model in the engine — NLLB-200 (CoreML, ANE), like the RAG embedder
- ✅ Zero egress (on-device), arbitrary language pairs (200 languages), engine-native (CoreML/ANE,
  same model-cache pattern as the embedder/Whisper).
- ❌ **~3.2 GB** (`cstr/nllb-200-coreml-256`: 1.5 GB encoder + 1.7 GB decoder) — 5× the speech model,
  28× the RAG embedder. Autoregressive seq2seq ⇒ **per-segment decode latency** (real-time concern).
  Another model to convert/host/quantize/validate. Disproportionate weight for a secondary feature.

### B. Apple Translation framework (`TranslationSession`)
- ✅ Free, on-device, system-shared models, **available on macOS Sonoma (14.4 — our floor)**, no
  model to ship.
- ❌ **Architecturally incompatible (the blocker):** `TranslationSession` is a *purely SwiftUI* API —
  it can only be obtained from a SwiftUI view via the `.translationTask` modifier; it has **no
  standalone initializer**. Hark has **no SwiftUI** anywhere: the engine is a headless Swift-NIO
  daemon, the UI is Electron/Angular. Using it would mean bolting a hidden SwiftUI/NSApplication
  host onto the daemon (or a third helper process) purely to vend a session — a large, awkward
  architectural change for one feature. (Open question: verify whether macOS 26 added a non-UI
  initializer before reconsidering — the available docs say SwiftUI-only.)

### C. Per-segment translation via the ALREADY-configured LLM (reuse §1's path)
- ✅ **Zero new infrastructure** — reuses the provider layer, the egress governance (ADR-0031), and
  the `segment.translation` + `TranscriptLine` plumbing. Works *today* with whatever model the user
  configured. **A LOCAL model (Ollama/llama.cpp) ⇒ zero egress**, which fits the local-first ethos
  and avoids per-segment cost. Arbitrary target (the LLM handles any language).
- ❌ A CLOUD model ⇒ **per-segment egress + cost + per-segment redaction** — unacceptable as a silent
  default. LLM round-trip ⇒ latency (acceptable on FINALIZED segments via a local model; sloppy for
  cloud). So it must be **opt-in + egress-disclosed**, and is best paired with a local model.

## Decision (recommended)

**Implement §3 as Option C — opt-in per-segment LLM translation of FINALIZED segments — and DEFER
A and B.**

- A live **"Translate live → <lang>"** toggle (distinct from §2's `→ EN`) turns it on. When on, each
  **finalized** segment (never partials — bounds the call count) is sent to translate via the
  existing main `llm` path, and the result fills `segment.translation`, shown under the original by
  `TranscriptLine` (bilingual live view).
- **Orchestrated in the renderer → main** (the egress chokepoint), exactly like §1: cloud redacts
  the segment first + logs metadata-only; **local model = zero egress**. The engine stays
  network-free (it only emits the original text; it does NOT translate for arbitrary targets).
- **Egress honesty:** the toggle's copy states plainly that with a CLOUD model each line is sent to
  the model as it's finalized (redacted), and **recommends a local model** for zero-egress live
  translation. This is an *opt-in HQ/live mode*, never a silent default.
- **Persistence:** the saved transcript stays the ORIGINAL (the engine owns it); live arbitrary
  translations are a live-view nicety. To keep a translated copy, the user runs §1 (end-of-meeting →
  any language) — already shipped. (A future enhancement could persist per-segment translations.)

**Defer A (NLLB):** revisit only if users want *offline* arbitrary-target live translation without
running a local LLM — then weigh the ~3.2 GB (quantize first) + the seq2seq latency. **Defer B
(Apple Translation):** blocked by the SwiftUI-only API in Hark's architecture; revisit only if a
non-UI `TranslationSession` initializer is confirmed on a future macOS we're willing to floor at.

Rationale: §3 is a secondary, advanced feature; Option C ships it with the LEAST new weight, reuses
the audited egress path, honors local-first (local model = zero egress), and avoids a 3.2 GB model
or a SwiftUI host. End-of-meeting arbitrary-target (the more common ask) is already covered by §1.

## Implementation notes (as built)

- **Renderer-orchestrated, engine untouched.** A new `LiveTranslationService`
  (renderer) listens on `EngineService.segmentFinalized$` — fired ONLY on
  `segment.final`, never partials, never the post-stop `meeting.transcript` swap
  — and for each finalized line calls main's new `llm.translateSegment`, then
  writes the result back via `EngineService.setSegmentTranslation` (fills
  `segment.translation`, shown under the original by `TranscriptLine`). The Swift
  engine has NO change: it still emits only the original text. No new model is
  shipped (contrast Option A's NLLB).
- **Egress chokepoint reuse.** `translateSegment` forks identically to
  `summarize`/`translate`: LOCAL (loopback) → send the line as-is, zero egress;
  CLOUD → `redact(line, knownNames)` first. `knownNames` is empty live
  (diarization is post-stop), so the regex detectors do the scrubbing. Privacy
  audit: PASS (matches the previously-audited path line-for-line).
- **Aggregated cloud-log (not per-line).** Live translation can fire hundreds of
  times per meeting; one cloud-log row per line would flood the 500-entry cap
  (evicting summary/qa records) and churn the JSON file on every line. So
  per-segment egress is **rolled up in memory** (`recordLiveTranslate`) and
  flushed as ONE metadata-only `translate-live` entry (`flushLiveTranslate`) —
  summed in/out chars + redaction total + a line COUNT in `detail`, never
  content. Flushed on: provider/model/egress change, a 50-line threshold, the
  renderer's stop signal (capture stop / toggle off), before any other LLM
  action (chronological ordering), and `before-quit`.
  - *Accepted gap (LOW):* a hard crash between flushes drops ≤~49 lines' worth of
    *metadata* from the local egress ledger — the egress already happened over
    the wire; only the local accounting is lost. No content is ever at risk.
- **Per-line cloud egress is the accepted cost.** A cloud model means one
  redacted round-trip per finalized line (volume + cost). This is OPT-IN and
  egress-disclosed: the picker shows `↑ cloud · redacted` vs `on-device` and the
  tooltip states it plainly; a LOCAL model is recommended and surfaced. Never a
  silent default.
- **Mutual exclusion + UI lock.** §3 (a non-English target picker) is mutually
  exclusive with §2 (`→ EN`, on-device) — choosing one clears the other — and is
  locked during capture (chosen before Start), matching §2 for consistency. The
  lock is a UX choice, NOT a privacy requirement (every line sent goes through
  the same redact-on-cloud fork regardless); `LiveTranslationService` is
  deliberately *capable* of mid-meeting toggling, so enabling that later is a
  template change, not a service change.
- **English excluded from the §3 picker.** English is the §2 on-device path
  (free, zero-egress, strictly better); the §3 list is non-English only. Lines
  the engine detects as already in the target language are skipped (the model
  would just echo them).

## Consequences

**Positive** — no new model/dependency/process; reuses the provider + egress governance + the
existing translation wire/UI; local model ⇒ zero egress; works immediately with any configured model.
**Negative / accepted** — cloud + this mode = per-segment egress/cost (mitigated: opt-in, disclosed,
finalized-only, local recommended); latency on cloud; live arbitrary translations aren't persisted
(use §1). Quality is the LLM's (generally strong) rather than a dedicated MT model.

## Test plan / results

**Automated gates — DONE (green):**
- `npm run build` — renderer AOT typecheck + main `tsc` both compile clean.
- **privacy-auditor: PASS** — `translateSegment`'s egress fork matches the audited
  `summarize`/`translate` (cloud redacts each line, local zero-egress); the aggregated
  `translate-live` cloud-log entry is metadata-only and still discloses volume; nothing persists
  outside allowed surfaces; no new socket/dependency/telemetry; engine unchanged. Three LOW notes,
  all folded into "Implementation notes" above (none blocking).
- Logic review of the renderer orchestration (finalized-only gating, dedupe-by-utterance-id,
  fill `segment.translation`, mutual exclusion with §2). No UI unit-test runner exists in the
  project (no jest/vitest), so the build's AOT typecheck is the automated ceiling here.

**Needs the user (live audio + eyes + a configured model — not doable headlessly):**
- The actual live experience: pick a non-English target, **speak/play audio**, confirm translated
  captions appear under the originals in the chosen language.
- Latency feel (is finalized-segment translation "live enough"?) and a real local-model run
  (Ollama) confirming `on-device` + zero new cloud-log egress; a cloud run confirming the
  `↑ cloud · redacted` hint + one aggregated `translate-live` log entry on stop.

**Done = both:** the automated gates (green) AND on-device confirmation (pending). Per the standing
note, this is NOT marked shipped on the build alone.

## References

- ADR-0029 (egress chokepoint in main), ADR-0031 (redaction + metadata-only log), the BACKLOG
  "Translation" section (§1/§2 shipped; §3 here). §2 (live → English) — `EngineSession`
  `liveTranslateToEnglish`.
- [Apple `TranslationSession`](https://developer.apple.com/documentation/translation/translationsession)
  (SwiftUI-vended; macOS Sonoma+). [NLLB-200 CoreML (`cstr/nllb-200-coreml-256`)](https://huggingface.co/cstr/nllb-200-coreml-256)
  (~3.2 GB). [`facebook/nllb-200-distilled-600M`](https://huggingface.co/facebook/nllb-200-distilled-600M).
