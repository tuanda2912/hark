# Hark — Current Status

**Last updated:** 2026-05-28
**Current phase:** Phase 3 complete + smoke-verified · Phase 4 (Electron + Angular UI) is next
**Stack:** validated (Phase 0 RTF 0.075 on M4 — see [ADR-0005](docs/decisions/0005-phase-0-rtf-validated.md))

> This file is the **session handoff**. It gets updated every time work pauses so the next session (or the next machine) can pick up without re-deriving context.

---

## Where we are right now

### ✅ Done

- **Project scaffolding** — `CLAUDE.md` (operating manual), `meetingmind-handoff.md` (design rationale), `.claude/agents/` with `swift-macos-expert` + `privacy-auditor`, `docs/decisions/` template + ADRs 0001–0005
- **Product docs** in the vault repo (`hark-docs`): 10 documents across product / analysis / design / qa
- **UI/UX design pass** in `vault/hark/docs/design/ui/` — 9 surfaces, dark + light, JSX artboards + screenshots + design tokens. Post-fix pass already applied.
- **Phase 0** — RTF benchmark harness (`hark-bench`), validated **RTF avg 0.0747** on Apple M4 (6.7× under the 0.50 threshold). Cold start 1.67s.
- **Phase 1** — batch transcribe engine (`hark-engine`). Audio file in, JSON segments out matching the WebSocket API contract shape. Shared `HarkCore` library extracted (`ProgressRenderer`, `Heartbeat`, `ModelLoader`).
- **Phase 2** — `hark-capture` CLI complete and **smoke-passed end-to-end** on M4 with a Vietnamese audio source (2026-05-27). Pipeline: Core Audio Process Taps (system audio) + AVAudioEngine (mic) → per-source resampler → FIFO → tanh soft-clip mixer → 16 kHz mono s16le WAV via `HarkCore.WAVWriter`. Active TCC permission request on first run ([ADR-0007](docs/decisions/0007-active-permission-request.md)), SIGINT graceful stop, stderr JSON heartbeat. **macOS floor pinned to 14.4+** ([ADR-0006](docs/decisions/0006-phase-2-capture-architecture.md)).
  - Smoke run: 29.9s WAV → 11 clean Vietnamese segments, `language_detected="vi"`, no underruns.
  - One cosmetic fix landed: `ProgressRenderer` no longer renders `0 MB / 0 MB · 0.0 MB/s` when the Progress producer reports non-byte unit counts.
- **Phase 3** — `harkd` streaming engine + WebSocket server complete ([ADR-0008](docs/decisions/0008-phase-3-streaming-architecture.md)). Long-lived daemon: HarkCapture (in-process library) → VAD gate → 30s sliding window with 5s hop → WhisperKit → Swift NIO localhost WebSocket. Loopback-only bind, port written to `~/Library/Application Support/Hark/engine.port`. Implements meta.hello + 5s heartbeat, capture lifecycle (start/stop/pause/resume), segment.partial→final with utterance_id replacement across windows, bookmark.created, backpressure (drop oldest unprocessed if RTF > 1 → warning `rtf_high`).
  - `HarkCapture` refactored from executable into a library; `HarkCaptureCLI` is now the thin wrapper preserving the batch CLI.
  - `harkd --help` runs, build clean for all four binaries (hark-bench, hark-engine, hark-capture, harkd).
  - **DEVIATION from ADR-0008 §3:** ships an energy-based VAD with hangover (behind a `VAD` protocol), NOT Silero CoreML. ADR-0008 §3's open question #1 acknowledged Silero sourcing was uncertain. Energy gate covers the steady-silence hallucination case which is what §3 actually motivates. Silero is now an upgrade path — see Open Threads.
- **Phase 3 follow-up — utterance_id v2** ([ADR-0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md)). Smoke test 2026-05-28 on M1 caught an engulfment failure mode in the v1 (min-denominator) overlap rule from commit `be31c52`: when WhisperKit produced a coarser segmentation, long new segments hijacked the UUIDs of short engulfed entries, causing identity drift to alien content (e.g. `1C4B2CBA` "Okay." mutating into "the scheme where they provide the secure…"). Fix: max-denominator overlap (`overlap / max(segLen, eLen)`) + `UtteranceLedger.prune(beforeSessionTime:)` that emits a synthetic `segment.final` (identifiable by `language: nil`) for orphan partials falling out of the window. Re-smoke 2026-05-28 confirms catastrophic case eliminated; 7 clean partial→final transitions; prune emitting for 3 orphans. One softer wart documented as ADR-0009 open question #1, deferred until Phase 4 UI shows whether it matters. Closes ADR-0008 §"Open questions" #3.

### ⏳ Next up: Phase 4 — Electron + Angular UI

The full engine pipeline is complete and accepting WebSocket connections. Phase 4 builds the user-facing surface:

- Electron + Angular 21 shell (per [ADR-0001](docs/decisions/0001-electron-over-tauri.md))
- Electron main process spawns `harkd` as a child process; reads `engine.port`; connects WebSocket
- Renderer: menu-bar tray, main window with live transcript view (per the UI design in `vault/hark/docs/design/ui/`), Q&A side panel, settings with privacy page
- Manual speaker tag UI (Phase 5 will do voice fingerprint persistence)
- electron-builder config for unsigned dev builds (signed builds deferred per the 2026-05-24 open-source local-devs decision)

Estimated effort: 1–2 weeks per the roadmap. Largest phase by line count but most familiar territory (Angular is the developer's strength).

---

## Resuming on a fresh Mac — setup steps

1. **Install Xcode Command Line Tools** (if not already): `xcode-select --install`. Full Xcode is not required — Swift Package Manager works from the CLI.
2. **Clone both repos to the canonical paths:**
   ```bash
   mkdir -p ~/Documents/project ~/Documents/vault
   git clone git@github.com:tuanda2912/hark.git ~/Documents/project/hark
   git clone git@github.com:tuanda2912/hark-docs.git ~/Documents/vault/hark
   ```
   All path references in `CLAUDE.md`, agents, and docs use `~/Documents/...` so they resolve correctly on any Mac regardless of username.
3. **Verify the engine builds:**
   ```bash
   cd ~/Documents/project/hark/engine
   swift build -c release
   ```
   Should complete in <60s after fetching WhisperKit + transitive deps.
4. **Optional smoke test** (re-validates Phase 0 on the new hardware):
   ```bash
   # Drop a 60s+ audio file into engine/Fixtures/
   swift run -c release hark-bench Fixtures/your-audio.mp3
   ```
   First run downloads the ~626MB CoreML model from HuggingFace (2–5 min on home internet). Subsequent runs use the cached model.

---

## How to onboard a fresh Claude Code session

When opening Claude Code on the new Mac, the first message to it should be something like:

> "I'm resuming work on Hark on a new Mac. Read `STATUS.md`, `CLAUDE.md`, `meetingmind-handoff.md`, and `docs/decisions/0005-phase-0-rtf-validated.md`. Then we continue from where Phase 2 starts."

That gives the new session:
- Current cursor (this file)
- Operating manual (`CLAUDE.md`)
- Stack rationale (`meetingmind-handoff.md`)
- Most recent decision (`ADR-0005`) which references all the prior ADRs

The session will then have the same context budget I have right now.

---

## Open threads (small, non-blocking)

1. **One minor segment artifact** in `hark-engine` output: the last segment is sometimes literal `"."` (WhisperKit end-of-stream quirk). Documented in the smoke-test discussion; we agreed to filter at the UI layer in Phase 4 rather than mask it at the engine boundary.
2. **WhisperKit special-token regex** in `HarkEngine.swift` strips `<|startoftranscript|>` etc. Fragile if upstream changes format. Watch on WhisperKit upgrades.
3. **`utterance_id`** is a fresh UUID per segment in batch mode — exists for Phase 3 wire compatibility, doesn't carry meaning yet.
4. **English-only Phase 0 validation.** Thai-English code-switch unmeasured. Even a 3× slowdown still passes, so not blocking. Will be revealed naturally during Phase 4+ dogfooding.
5. **Settings → Speakers design mock** still ⏳ (open from the UI design pass). Needed for Phase 5 implementation, not Phase 2.
6. **Single-speaker UI collapse** still ⏳ (open from the UI design pass). Needed for Phase 4 implementation.
7. **Phase 2 — clock-drift between mic and system tap is unmitigated.** Worst-case ~225 ms over a 1-hour recording. Revisit if Phase 4 dogfooding shows it hurts. Documented in [CapturePipeline.swift](engine/Sources/HarkCapture/CapturePipeline.swift).
8. **Phase 2 — sample-rate changes mid-capture** (plug/unplug an audio interface) untested. Listed as ADR-0006 open question.
9. **Phase 2 — Process Tap drift compensation is off** (`kAudioSubTapDriftCompensationKey: 0`). Flip on if needed.
10. **Model upgrade path — not blocking.** `large-v3-turbo` is the speed/quality Pareto pick today. If Vietnamese / Thai / code-switch WER turns out to be unacceptable in dogfooding, the cheapest upgrade is undistilled **`large-v3`** (Argmax ships a CoreML bundle) — ~10–15% WER improvement on hard languages at ~5× compute. Still fits the 0.5 RTF budget with current Phase 0 headroom (projected ~0.37). Fine-tunes like PhoWhisper (Vietnamese) or biodatlab whisper-th-* (Thai) require manual `whisperkittools` conversion and lose code-switching. **Decide *after* trying initial-prompt vocab injection from the vault** — that's a cheaper accuracy win we haven't cashed in. If we swap, capture the WER delta in a new ADR.
11. **Phase 3 VAD is energy-based, not Silero.** `Sources/Harkd/VAD.swift` ships behind a `VAD` protocol so the upgrade is a one-file swap. Trigger to upgrade: if Phase 4 dogfooding shows hallucination on low-energy speech, OR if `large-v3-turbo` swap (open thread #10) brings the same hallucination class back. Silero CoreML model sourcing is the unresolved sub-question — likely an ONNX→CoreML conversion via `coremltools`, or accept ONNX Runtime as a dependency. Capture in a new ADR when we act.
12. **Phase 3 WebSocket has no auth.** Loopback-only bind makes this acceptable per the threat model (only processes on the same Mac can connect). If a future feature ever opens the WS beyond loopback, this assumption breaks immediately and needs ADR-level rework. Don't let it slide.
13. ~~**`harkd` smoke test against a live WS client** is not yet done~~ — **resolved 2026-05-28.** Smoke run on M1 via `websocat` exercised the full path `meta.hello → capture.start → segment.partial/final stream → capture.stop`. The run also caught the v1 utterance-id engulfment bug (see Phase 3 follow-up in Done), now fixed in [ADR-0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md).
14. **Utterance-id soft mutation case** ([ADR-0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md) open question #1) — overlap-of-longer at threshold ~0.5 still permits a UUID to mutate text across re-segmentations when the two intervals are roughly the same size but contain adjacent (not identical) speech. Observed in the 2026-05-28 re-smoke: `E4A8F453` shifted from "You are integrated with your ledger" → "You inherit the ledger contract" (score ≈ 0.58). Bounded — content stays in the same speech vicinity — but Phase 4 will tell us if it's user-visible. Fix would be text-similarity tie-breaking (call it v3); deferred until UI feedback exists.
15. **M1 cold-start cost** is much worse than M4 — first ANE compile of `large-v3-turbo` took ~90s on M1 vs 1.67s warm on M4 ([ADR-0005](docs/decisions/0005-phase-0-rtf-validated.md)). Subsequent launches are fast (warm CoreML cache). RTF on M1 measured 0.08–0.28 during smoke — well under the 0.5 budget. The "10–30s typical" wording in `ModelLoader.swift` is M4-calibrated; consider rewording when Phase 4 lands and the load happens behind a spinner anyway.

---

## Don't redo (already decided this session — see ADRs)

- ❌ Cloud ASR (Soniox / AssemblyAI / Deepgram) — [ADR-0004](docs/decisions/0004-no-cloud-asr.md)
- ❌ Rust engine — [ADR-0003](docs/decisions/0003-swift-whisperkit-engine.md), unblocked by [ADR-0002](docs/decisions/0002-macos-only-scope.md)
- ❌ Tauri 2 — [ADR-0001](docs/decisions/0001-electron-over-tauri.md)
- ❌ Full SwiftUI app for v1 — too much ramp; revisit at v1.5
- ❌ Windows / Linux / iOS / Android — [ADR-0002](docs/decisions/0002-macos-only-scope.md)
- ❌ Calendar integration — corporate Intune blocks Exchange sync
- ❌ Auto-join Zoom / Teams
- ❌ Per-speaker redact-name override (drawn in the modal, removed in the post-design fix pass)

If a future session suggests revisiting any of these, point at the ADR and move on.

---

## Update protocol

When work pauses or a session ends:

1. Bump `Last updated` and `Current phase` at top
2. Move completed items from `⏳ Next up` → `✅ Done`
3. Set the new `⏳ Next up` section
4. Add anything dangling to `Open threads`
5. Commit + push

Keep this file under ~250 lines. When it grows past that, archive older "Done" entries to a `docs/sessions/YYYY-MM-DD.md` log file and trim this back to current state.
