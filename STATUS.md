# Hark — Current Status

**Last updated:** 2026-06-03
**Current phase:** **Phase 6 (LLM + vault RAG) shipped.** Provider-agnostic LLM (meeting summary · this-meeting Q&A · vault-wide Q&A) + **pluggable retrieval** (built-in on-device RAG **and** external loopback MCP/HTTP backend), all behind the local-first egress governance. Phase 5 / 5.1 (offline diarization + speaker enrollment + privacy model) shipped. **Next:** ship-readiness (publish the embedder model, then packaging/notarization) · on-device LLM testing by the user · translation.
**Stack:** validated (Phase 0 RTF 0.075 on M4 — [ADR-0005](docs/decisions/0005-phase-0-rtf-validated.md))

> This file is the **session handoff** — the current-state snapshot. Read it first when resuming.
>
> **Deferred-work ledger:** [docs/BACKLOG.md](docs/BACKLOG.md) — every deliberate "better, but not now" cut, with context to finish it. When you defer something, add it there in the same turn.
>
> **History:** detailed Phase 0–5 build log archived at [docs/sessions/2026-06-01-phase5-diarization.md](docs/sessions/2026-06-01-phase5-diarization.md). Decision log: [docs/decisions/](docs/decisions/).

---

## Where we are right now

### ✅ Done — Phase 5.1 + Phase 6 (since 2026-06-01)

- **Phase 5.1 — speaker enrollment + privacy/data-control model** ([ADR-0026](docs/decisions/0026-speaker-enrollment.md), [ADR-0027](docs/decisions/0027-privacy-data-control-model.md); diarization stays post-stop per [ADR-0025](docs/decisions/0025-no-live-diarization-v1.md)). `speaker.rename` round-trip re-renders the saved vault file; **opt-in** `remember_speakers` gate stores voiceprints in `vault/.speakers/` (rule #5 — never networked); the on-screen transcript is **back-annotated** with speakers at stop ([ADR-0024](docs/decisions/0024-onscreen-transcript-back-annotation.md)). Privacy prefs (keep-audio / remember-speakers / sync intents, all default-off) + a prominent **README** "Your data & privacy" section.
- **Meeting audio persistence** ([ADR-0028](docs/decisions/0028-meeting-audio-persistence.md)) — opt-in `keep_audio` writes the meeting WAV to `vault/.audio/<id>.wav`. **Post-Meeting Review screen**: play the audio, click an utterance to seek, verify-by-ear speaker tagging. All screens now sit under a **persistent "Hark" titlebar**.
- **Phase 6 LLM — provider-agnostic** ([ADR-0029](docs/decisions/0029-llm-provider-layer-egress.md) layer · [ADR-0030](docs/decisions/0030-api-key-storage.md) keys · [ADR-0031](docs/decisions/0031-content-egress-redaction-log.md) egress). All LLM HTTP lives in **Electron main** (Anthropic-native + OpenAI-compatible → covers OpenAI/Gemini/OpenRouter cloud AND Ollama/LM Studio/llama.cpp local; raw `fetch`, no SDK). API key encrypted in macOS Keychain via `safeStorage`, never bridged to the renderer. **Egress governance:** cloud sends PII-**redacted** content + a metadata-only `cloud-calls.json` receipt; a **local (loopback) model = zero egress**. Engine stays network-free; CSP unchanged.
  - **Slice 2 — summary:** "Summarize" → `llm.summarize` (main) → "Save to note" writes `## Summary` to the vault **via the engine** (`summary.write`).
  - **Slice 3 — this-meeting Q&A:** the Ask panel answers from the current transcript (question + transcript redacted for cloud).
- **Vault-wide RAG — COMPLETE & pluggable** ([ADR-0032](docs/decisions/0032-vault-rag-architecture.md) built-in · [ADR-0033](docs/decisions/0033-pluggable-retrieval-backend.md) pluggable · [ADR-0034](docs/decisions/0034-external-retrieval-transport.md) external transport). The cloud model NEVER sees the vault: **local** retrieve → only the redacted top-K chunks + question leave (local LLM ⇒ zero egress). Two interchangeable backends, chosen at onboarding / Settings:
  - **Built-in (default):** engine **CoreML embedder** (`multilingual-e5-small`, 384-dim, ANE) + brute-force in-memory cosine over a flat file, **offset-only** (`meta.jsonl` holds pointers; snippets read **live from the vault** at retrieve, stale/deleted files skipped) + **FSEvents watcher** (30 s, content-hash). New `rag.retrieve`/`rag.results`/`rag.index_status` wire frames. Embedder loads **concurrently** with the speech model (no longer blocked behind the large-v3 compile).
  - **External:** a user-run **LOCAL** retrieval service — `src/main/rag/` is a hand-rolled (raw `fetch`, no SDK) loopback client with two transports: **plain HTTP** (`POST {query,k,scope}→{chunks}`) and **minimal MCP-over-HTTP** (`initialize`→`tools/call`, JSON or SSE). **Loopback-guarded** before every fetch + `redirect:'error'` (SSRF closed).
  - **Renderer:** `RetrievalService` hides the fork; the Ask panel gained a **this-meeting | vault** scope toggle and renders **real numbered source cards** (the empty `[1][2]` citations Slice 3 left). Settings → "Vault search" + an onboarding choice select the backend.
  - **Embedder hosting — DONE:** the int8 CoreML model (~113 MB) is published to
    `tuanda2912/hark-multilingual-e5-small-coreml` (public, MIT) and pinned in
    `EmbedderModels.swift`. The production first-run download path is **validated end-to-end with
    no env override** (clean run: download 24 s → ANE compile 6 s → cross-lingual + full retrieve
    tests pass; second run hits the cache). Built-in vault RAG is **shippable**.
  - **Verified:** live WS smoke (built-in, on-device, real embedder + real vault) · 12-check external-transport smoke (both HTTP + MCP, JSON + SSE) · 168 engine tests green · **privacy-audited PASS** (built-in 4a/4b/4c + external 7/7).

### ✅ Done — Phases 0–5 (condensed; full log in the session archive)

- **Phase 0–3** — RTF validated (0.075, M4); batch transcribe (`hark-engine`); capture (`hark-capture`: Process Taps + mic, 16 kHz mono); **`harkd`** streaming engine + loopback WebSocket; `utterance_id` v2 overlap rule ([ADR-0008](docs/decisions/0008-phase-3-streaming-architecture.md)/[0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md)/[0011](docs/decisions/0011-process-tap-system-audio-gotchas.md)/[0012](docs/decisions/0012-harkd-lazy-permissions-startup.md)).
- **Phase 4** — Electron + Angular 21 UI: live transcript + live-tail, menu-bar tray, Settings + prefs persistence ([ADR-0014](docs/decisions/0014-ui-preferences-persistence.md)), native Mac chrome, readiness gating, status banner, session language hint.
- **Phase 5** — **offline FluidAudio** diarization (`OfflineDiarizerManager`/VBx, [ADR-0016](docs/decisions/0016-phase-5-diarization.md)/[0017](docs/decisions/0017-diarization-offline-pipeline.md)); **engine writes** the diarized markdown to the vault + per-meeting local git ([ADR-0015](docs/decisions/0015-transcript-vault-persistence.md)); utterance **supersession** + at-stop dedup ([ADR-0018](docs/decisions/0018-utterance-supersession-signal.md)).

### ⏳ Next up

1. **On-device LLM testing (user).** Exercise summary / this-meeting Q&A / vault Q&A with a real API key (Anthropic / OpenAI-compatible) **or** a local Ollama (`baseUrl` → zero egress). Built-in vault RAG now works on a clean install (embedder hosted — see above); external RAG: a ~10-line local stub server proves the path (see BACKLOG / the 4c–external report).
2. **Translation** — **§1 (end-of-meeting transcript translation) SHIPPED** (`83687ad`): saved-card "Translate" → pick a language → `llm.translate` (cloud redacts / local zero-egress) → Save-to-note (`## Transcript — <lang>` via `translation.write`); privacy-audited. **Remaining:** §2 live → English (WhisperKit `task=.translate`, on-device, cheap) · §3 live → arbitrary target (MT model / Apple Translation / per-segment LLM — its own ADR). See BACKLOG.
3. **Phase 7 — packaging / notarization.** electron-builder + sign the Swift sidecar + hardened-runtime entitlements + `kTCCServiceAudioCapture` attribution. Onboarding flow polish.
4. **Polish / deferred** (all in BACKLOG): jump-to-source citations (chunks carry `note_path` + offsets); live index-status for the external backend; richer MCP (resources/streaming/SDK); a committed renderer/main **test runner** (only Swift + throwaway smokes today); transcript-readability finalization fix; clustering-threshold tuning; redaction NER + toggle.

---

## Resuming on a fresh Mac

1. **Xcode CLT:** `xcode-select --install` (full Xcode not required).
2. **Clone to canonical paths** (all docs use `~/Documents/...` so they resolve on any Mac):
   ```bash
   mkdir -p ~/Documents/project ~/Documents/vault
   git clone git@github.com:tuanda2912/hark.git ~/Documents/project/hark
   git clone git@github.com:tuanda2912/hark-docs.git ~/Documents/vault/hark
   ```
3. **Engine:** `cd ~/Documents/project/hark/engine && swift build` (debug) — fetches WhisperKit + FluidAudio + swift-transformers + swift-crypto.
4. **UI:** `cd ~/Documents/project/hark/ui && npm install && npm run build` (renderer `ng build` + main `tsc`). Dev loop: `npm run dev`.
5. **Vault RAG in dev:** the embedder isn't hosted yet — run harkd with `HARK_EMBEDDER_LOCAL_DIR=<dir with MultilingualE5Small.mlpackage + tokenizer>` (re-create via `engine/scripts/convert-embedder-coreml.py` if `/tmp/hark-coreml/out` is gone). First WhisperKit run downloads ~626 MB + an ANE compile (slow on M1 cold start; fast warm).

---

## Don't redo (locked — see the ADR, then move on)

Stack basics ([ADR-0001](docs/decisions/0001-electron-over-tauri.md)–[0005](docs/decisions/0005-phase-0-rtf-validated.md)): Electron over Tauri · macOS-only · Swift+WhisperKit engine (no Rust) · no cloud ASR. No full SwiftUI v1 · no Windows/Linux/iOS · no calendar/auto-join. Plus this session's locks:

- **Diarization** = offline FluidAudio, anonymous-v1, engine-written ([ADR-0016](docs/decisions/0016-phase-5-diarization.md)/[0017](docs/decisions/0017-diarization-offline-pipeline.md)); **no live diarization for v1** ([ADR-0025](docs/decisions/0025-no-live-diarization-v1.md)). Supersession gate = time-containment AND text-prefix, never text-only ([ADR-0018](docs/decisions/0018-utterance-supersession-signal.md)).
- **Enrollment / privacy** ([ADR-0026](docs/decisions/0026-speaker-enrollment.md)/[0027](docs/decisions/0027-privacy-data-control-model.md)): voiceprints local-only, all sensitive storage opt-in & default-off. Audio persistence opt-in to `vault/.audio` ([ADR-0028](docs/decisions/0028-meeting-audio-persistence.md)).
- **LLM** ([ADR-0029](docs/decisions/0029-llm-provider-layer-egress.md)/[0030](docs/decisions/0030-api-key-storage.md)/[0031](docs/decisions/0031-content-egress-redaction-log.md)): provider HTTP in main only, raw fetch (no SDK); key in Keychain via safeStorage; cloud redacts + logs metadata-only, local = zero egress. Don't move egress out of main or add a vendor SDK.
- **Vault RAG** ([ADR-0032](docs/decisions/0032-vault-rag-architecture.md)/[0033](docs/decisions/0033-pluggable-retrieval-backend.md)/[0034](docs/decisions/0034-external-retrieval-transport.md)): built-in = engine CoreML embedder + brute-force cosine (NOT sqlite-vec for v1) + offset-only index in app-data (never the vault); pluggable built-in/external; external is loopback-only + hand-rolled (no MCP SDK for v1). Don't re-debate the embedder runtime, the vector store, or offset-only.

---

## Open threads (small, non-blocking)

1. **Vietnamese / non-English ASR quality** — deferred. Language-lock lever exists (top-bar picker → `capture.start.language`); if a locked `vi` session is still poor, ladder is prompt-vocab injection → undistilled `large-v3` → fine-tunes (PhoWhisper / whisper-th). Language-lock HURTS code-switching (use prompt injection there). New ADR if we swap models. (Energy-VAD hallucination on VN silence confirmed — Silero is the principled fix; see thread 2.)
2. **VAD is energy-based, not Silero** (`Sources/Harkd/VAD.swift`, behind a protocol). Upgrade trigger: hallucination on low-energy speech. Silero CoreML sourcing (ONNX→CoreML) is the open sub-question; ADR when we act.
3. **Built-in RAG cold-start, partially mitigated.** Embedder now loads concurrently with the speech model (4c fix), so vault search is available early. The large-v3 **ANE compile itself** is still slow on M1 cold start (minutes) — capture is gated on it regardless; a smaller/cached speech model is a separate lever.
4. **Default capture backend** — ScreenCaptureKit is default; Process Taps opt-in (`HARK_CAPTURE_BACKEND=tap`). Taps grant-and-continue (SCK needs a restart), a point for flipping; decide after more tap mileage ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md)).
5. **Transcript readability** on continuous, pause-less narration — residual run-on/dup the post-hoc dedup doesn't fully catch; robust fix is source-level finalize-once. Mostly an adversarial-input edge (real meetings segment cleanly).
6. **WS has no auth** — loopback-only bind makes it acceptable; breaks immediately if the socket ever opens beyond loopback (would need ADR-level rework). Same posture for the external-RAG loopback guard.
7. **No committed renderer/main tests** — engine has Swift tests; the renderer + main `rag`/`llm` logic is covered by `npm run build` typecheck + throwaway `/tmp` smokes + privacy audits. Stand up a real runner (vitest / `node --test`) to lock the loopback guard, `redirect:'error'`, and the retrieve correlation in.

---

## Update protocol

When work pauses: (1) bump `Last updated` + `Current phase`; (2) move done items from `⏳ Next up` → `✅ Done`; (3) set the new `⏳ Next up`; (4) add danglers to `Open threads`; (5) commit. Keep this file under ~250 lines — when it grows past that, archive the oldest `Done` detail to `docs/sessions/YYYY-MM-DD-*.md` (as done for Phase 0–5) and trim back to current state.
