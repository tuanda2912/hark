# ADR-0035: Live translation to an arbitrary target language — per-segment LLM (opt-in), defer local MT model + Apple Translation

- **Date:** 2026-06-03
- **Status:** Proposed (recommendation pending sign-off — no code yet)
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

## Consequences

**Positive** — no new model/dependency/process; reuses the provider + egress governance + the
existing translation wire/UI; local model ⇒ zero egress; works immediately with any configured model.
**Negative / accepted** — cloud + this mode = per-segment egress/cost (mitigated: opt-in, disclosed,
finalized-only, local recommended); latency on cloud; live arbitrary translations aren't persisted
(use §1). Quality is the LLM's (generally strong) rather than a dedicated MT model.

## Test plan (for the eventual implementation — this ADR ships NO code)

**I (Claude) can test, automated/headless:**
- The main per-segment `translate` path (unit/build typecheck; it's a near-clone of `llm.translate`).
- Egress discipline via the **privacy-auditor** (cloud redacts each segment, metadata-only log,
  local zero-egress) — same gate §1 passed.
- The renderer orchestration logic (finalized-only gating, filling `segment.translation`) — build +
  logic review; a non-Electron unit check if a runner exists.
- Full `npm run build` + the engine test suite (no engine change expected for Option C).

**Needs YOU (live audio + eyes + a configured model — I can't do headlessly):**
- The actual live experience: toggle on, pick a target, **speak/play non-English audio**, and
  confirm translated captions appear under the originals in the chosen language.
- Latency feel (is finalized-segment translation "live enough"?) and a real local-model run
  (Ollama) confirming zero egress in the cloud-activity log.

**Done = both:** the automated gates green AND your on-device confirmation. Per your standing note,
nothing gets marked done on the build alone.

## References

- ADR-0029 (egress chokepoint in main), ADR-0031 (redaction + metadata-only log), the BACKLOG
  "Translation" section (§1/§2 shipped; §3 here). §2 (live → English) — `EngineSession`
  `liveTranslateToEnglish`.
- [Apple `TranslationSession`](https://developer.apple.com/documentation/translation/translationsession)
  (SwiftUI-vended; macOS Sonoma+). [NLLB-200 CoreML (`cstr/nllb-200-coreml-256`)](https://huggingface.co/cstr/nllb-200-coreml-256)
  (~3.2 GB). [`facebook/nllb-200-distilled-600M`](https://huggingface.co/facebook/nllb-200-distilled-600M).
