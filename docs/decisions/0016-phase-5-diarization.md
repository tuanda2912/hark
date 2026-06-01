# ADR-0016: Phase 5 speaker diarization — FluidAudio, offline pass, engine-owned write

- **Date:** 2026-06-01
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Hark's design has always promised speaker attribution — a transcript that says *who* said what, not just a wall of timestamped quotes. The design docs spec this as a **post-meeting** pass: on `capture.stop` the engine runs diarization over the full session audio, assigns each final segment a speaker, writes the markdown file, and emits `meeting.saved` ([07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) §2 "Capture end → diarization → vault file"; [06-architecture-overview.md](../../../hark-docs/docs/design/06-architecture-overview.md) lists Diarization + Speaker Matcher under **Post-processing**, not the live ASR pipeline).

v1 shipped **pre-diarization**: [ADR-0015](0015-transcript-vault-persistence.md) parked the markdown+git write in the Electron main process "until Phase 5," with `attendees: []` and timestamp-only utterance headers. **Phase 5 is now here.** This ADR records the diarization decisions and, in doing so, **activates the ADR-0015 migration** — the write moves into the Swift engine.

The hard rules bind this tightly: [CLAUDE.md](../../CLAUDE.md) rule #2 (transcripts/PII and app-data caches go to their sanctioned locations only), rule #5 (speaker voice embeddings stay local, never to any API), rule #6 (an ADR before any network-socket dependency).

## Decision

Add **on-device, offline, post-meeting** diarization to the engine using **FluidAudio**, with **anonymous "Speaker N" labels only** in v1 (enrollment + naming deferred to Phase 5.1). The diarization pass runs at `capture.stop`, after which **the Swift engine** writes the vault file and emits `meeting.saved` — superseding ADR-0015's interim Electron-main writer.

**1. Library = FluidAudio**, pinned to a stable tag (https://github.com/FluidInference/FluidAudio.git). CoreML / Apple Neural Engine, fully on-device. It ships the segmentation model **and** the 256-dim speaker-embedding model, **plus** a built-in `Codable` `Speaker` type and a cosine matcher (`SpeakerManager`) — so Phase 5.1 enrollment becomes *wiring*, not algorithm work. The CoreML model cache is pointed at `~/Library/Application Support/Hark/` (overridable directory), matching the WhisperKit precedent ([ADR-0003](0003-swift-whisperkit-engine.md); `HarkCore/ModelLoader.swift` passes a `downloadBase` for exactly this reason).

**2. Offline, post-meeting pass — NOT real-time/online.** On `capture.stop`, run FluidAudio's `performCompleteDiarization` over the **full session audio**, then assign each final segment a speaker by **time-overlap** of the segment against the returned diarization segments. This is what the docs already specify (flow §2; the Post-processing subgraph in the architecture view). It is the spec, not a new choice.

**3. v1 = anonymous "Speaker N" labels only.** No enrollment, no matching, no naming. **Deferred to Phase 5.1:** speaker enrollment to `vault/.speakers/*.json`, cosine name-matching, the `speaker.tag` command, retroactive segment rename + git re-commit, and the speaker-tagging UI. The markdown format reserves the slots already ([07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) §2: `attendees: [Alice Chen, Speaker 2, ...]`, `> **Speaker 2** · 10:30:18`); v1 populates them with `Speaker N`.

**4. The engine becomes the meeting-file writer now — this activates the ADR-0015 migration.** [ADR-0015](0015-transcript-vault-persistence.md) §2 assigned the write to Electron main *for v1 only*, with the explicit migration trigger "when Phase 5 (FluidAudio diarization) lands, move the write into the engine behind `meeting.saved`." That trigger has fired. The write moves into the Swift engine, runs **after** the diarization pass, and emits the `meeting.saved` frame ([08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) ~172–189). The Electron-main writer was **never built** (ADR-0015's implementation was deferred), so there is no two-writer interregnum to dismantle — **the engine is the sole writer.** The format does not change; only the writer and the now-populated speaker fields.

**5. Full-session audio is retained in RAM** for the offline pass, as raw mono 16 kHz `Float` so it feeds FluidAudio with zero per-frame conversion off the hot path. A 60-min meeting is ≈ 230 MB (`Float`; ~115 MB if stored as `Int16` — we keep `Float` deliberately to avoid any conversion) — acceptable for v1. The buffer is a **transient working buffer**, discarded after the write, **never persisted outside the vault**. Spill-to-temp-WAV is noted as a later optimization if long meetings pressure memory.

**6. `segment.speaker` stays provisional live, resolved after `meeting.saved`.** During the meeting the engine has no diarization, so `segment.speaker` is provisional/absent; speakers are resolved only by the post-stop pass ([08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) line 146: "`speaker` is provisional during the meeting (acoustic cluster only); resolved to real names after `meeting.saved`."). This keeps the live path on the locked `segment.final` + stable-`utterance_id` contract ([ADR-0009](0009-utterance-id-overlap-rule-v2.md)) untouched.

## Alternatives considered

- **Online / streaming diarization** (label speakers live as audio arrives).
  - ✅ Pros: speaker names visible during the meeting.
  - ❌ Cons: runs a **second CoreML model on the ANE during live capture**, contending with WhisperKit for the <1.5 s caption budget / RTF target; and suffers **streaming identity-churn** — speakers get re-labelled as evidence accrues.
  - **Why rejected:** ANE contention threatens the live latency budget, and identity-churn fights the locked terminal-`segment.final` + stable-`utterance_id` contract ([ADR-0009](0009-utterance-id-overlap-rule-v2.md)). The docs already specify an offline pass.

- **Speaker enrollment + naming in v1** (do all of Phase 5.1 now).
  - ✅ Pros: meetings ship with real names immediately.
  - ❌ Cons: a much larger **stateful** slice — `vault/.speakers/*.json` lifecycle, matching, retroactive rename + re-commit — and it pulls in the speaker-tagging UI.
  - **Why rejected:** "Speaker N" delivers the core attribution value at a fraction of the surface; enrollment is cleanly deferrable to 5.1 with the format slots already reserved.

- **Hand-rolled diarization / clustering.**
  - ✅ Pros: no third-party dependency.
  - ❌ Cons: segmentation + embedding models + a tuned cosine matcher is real research-grade work.
  - **Why rejected:** FluidAudio ships exactly this (`SpeakerManager`, the `Codable` `Speaker` type) on the ANE for free. Rebuilding it is unjustified.

- **Keep the Electron-main writer** (don't migrate per ADR-0015).
  - ✅ Pros: no Swift writer to build.
  - ❌ Cons: a **two-writer interregnum** — and diarization is exactly the privileged engine-only data ADR-0015 said justifies the engine owning the write (speaker labels, the `meeting.saved` frame).
  - **Why rejected:** the migration trigger ADR-0015 itself defined has fired; the engine is now the only place that can produce the speaker-bearing file. Since the main writer was never built, migrating is the *simpler* path, not extra work.

## Consequences

**Positive:**
- Transcripts gain speaker attribution (`Speaker N`) with the format slots ADR-0015 reserved now populated — byte-compatible with the v1 file shape.
- Live latency is untouched: diarization runs only after `capture.stop`, off the caption path ([ADR-0009](0009-utterance-id-overlap-rule-v2.md) contract intact).
- Phase 5.1 enrollment is **wiring, not algorithm work** — FluidAudio's `Speaker`/`SpeakerManager` are already in hand.
- One write-owner from here on: the engine. The ADR-0015 two-writer concern resolves cleanly (the main writer was never built).

**Tradeoffs accepted:**
- **~230 MB RAM** (`Float`) held for the full-session audio during the offline pass on a 60-min meeting. Acceptable for v1; spill-to-temp-WAV is the escape hatch for longer meetings.
- **No live speaker labels** — attribution appears only after stop. Inherent to the offline choice and consistent with the docs.
- Building an **engine-side markdown + git writer** in Swift (the work ADR-0015 deferred). Bounded, and the format is already specified verbatim.

**Must remain true / revisit trigger:**
- FluidAudio runs **fully offline after first-run model download** (see privacy note). If a future version added a runtime network call, that's a new ADR under rule #6.
- Embeddings never leave the device, and in 5.1 go **only** to `vault/.speakers/` (gitignored per [ADR-0015](0015-transcript-vault-persistence.md) §4); matching runs in the engine; the UI receives **names only** ([08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) line 293).
- If RAM pressure from long meetings shows up in dogfooding, implement the spill-to-temp-WAV optimization.

## Privacy / threat-model note

- **Rule #2 (sanctioned locations).** The CoreML model cache lives in `~/Library/Application Support/Hark/` (rebuildable app-data, same as WhisperKit), and the full-session audio is a **transient in-RAM working buffer** discarded after the write — it is **never written outside the vault**. The only persisted artefact is the meeting `.md` in `~/Documents/vault/hark/meetings/`.
- **Rule #5 (embeddings stay local).** In v1 the rule holds **trivially**: nothing is persisted, matched, or transmitted — embeddings are computed in-memory and discarded with the audio buffer. In Phase 5.1, embeddings go **only** to `vault/.speakers/*.json` (gitignored per ADR-0015), matching runs entirely in the engine, and the UI gets names only — never embeddings.
- **Rule #6 (network-socket ADR).** FluidAudio downloads **public CoreML model weights** from HuggingFace over HTTPS **on first run**, then runs fully offline — identical *in kind* to WhisperKit ([ADR-0003](0003-swift-whisperkit-engine.md)). This is public-weight download, **not user-content exfiltration**: audio and embeddings never leave the device. Per rule #6's intent this needs no separate network-socket ADR, but it is documented here for the audit trail.

**Nothing leaves the machine.**

## Open questions

- **Clustering / match threshold.** The docs say cosine **similarity** 0.72 ([07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) §2: "Match found (sim > 0.72)"). FluidAudio uses cosine **distance** with a `clusteringThreshold` default ~0.7; these convert as `distance ≈ 1 − similarity`. Resolve by tuning on a real 2–3-speaker recording on-device. (Matters for 5.1; v1 only needs the within-meeting clustering knob.)
- **Segment ↔ speaker assignment rule edge cases.** The v1 rule is time-overlap of each final segment against the diarization segments; the exact tie-break / partial-overlap / cross-talk behaviour needs pinning against real audio.

## References

- Hard rules: [CLAUDE.md](../../CLAUDE.md) (rules #2, #5, #6)
- FluidAudio: https://github.com/FluidInference/FluidAudio.git (segmentation + 256-dim embedding models, `Speaker` / `SpeakerManager`)
- Flow #2 (stop → diarize → match → write → `meeting.saved`): [07-data-flows.md](../../../hark-docs/docs/design/07-data-flows.md) §2 (~59–117)
- `segment.speaker` provisional/resolved, `meeting.saved.speakers[]`, `speaker.tag`, "UI gets names only": [08-websocket-api-contract.md](../../../hark-docs/docs/design/08-websocket-api-contract.md) (~140–206, 293)
- Diarizer + Speaker Matcher under Post-processing; `vault/.speakers/*.json` layout: [06-architecture-overview.md](../../../hark-docs/docs/design/06-architecture-overview.md) (~52–53, 116–118, 182)
- Model-cache precedent (`downloadBase` → `~/Library/Application Support/Hark/`): [ADR-0003](0003-swift-whisperkit-engine.md); `engine/Sources/HarkCore/ModelLoader.swift`
- Live-path contract preserved: [ADR-0009](0009-utterance-id-overlap-rule-v2.md)
- **Activates the migration in** [ADR-0015](0015-transcript-vault-persistence.md) §2 (write moves engine-side; main writer never built)
