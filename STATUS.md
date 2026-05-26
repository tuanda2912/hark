# Hark — Current Status

**Last updated:** 2026-05-26
**Current phase:** Phase 1 complete · Phase 2 is next
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

### ⏳ Next up: Phase 2 — Audio capture

Build `hark-capture` CLI: ScreenCaptureKit (system audio) + AVAudioEngine (mic) → mixed 16kHz mono PCM → WAV file the Phase 1 engine can transcribe.

After Phase 2, the batch pipeline is complete:

```bash
hark-capture --duration 60 --output session.wav
hark-engine session.wav --output session.json
```

**Phase 2 is the first phase where macOS permission prompts appear** (ScreenCapture + Microphone) and where the **macOS 14.4+ floor will probably get pinned** (CoreAudio Process Taps).

Estimated effort: 3–5 days per the roadmap.

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
