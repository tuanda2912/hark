# Hark — Current Status

**Last updated:** 2026-05-31
**Current phase:** Phase 4 in progress · UI scaffold + English live transcript working · **Core Audio Process Taps now capturing system audio (incl. Bluetooth) on macOS 26** · adding surfaces incrementally
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
- **Phase 4 thin slice — scaffold + live transcript** ([ADR-0010](docs/decisions/0010-phase-4-ui-scaffold.md)). `ui/` project landed: Electron + Angular 21 (standalone components, signals) + Tailwind v3 (tokens piped via CSS vars) + plain `tsc` for the Electron main process. Electron main spawns `harkd` as a child process, polls `~/Library/Application Support/Hark/engine.port`, exposes the port to the renderer via a sandboxed `contextBridge`. Renderer's `EngineService` (`Injectable, providedIn: 'root'`) opens the WebSocket, dispatches frame types, maintains a `utterance_id`-keyed map → ordered `segments()` signal. `AppComponent` renders a minimal top-bar (REC / start / stop / RTF readout) and a live transcript list that exercises the partial→partial→final replace-in-place contract. Tray, Q&A, settings, post-meeting review, speaker tagging deferred to follow-up commits per ADR-0010 §"first-commit scope". Privacy guardrails: strict CSP (`connect-src 'self' ws://127.0.0.1:*`), `contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`. No telemetry, no auto-update.
  - **Dev-loop hardening (2026-05-28/29, hands-on M1 run):** confirmed full path works end-to-end in **English** — capture → live transcript renders with correct partial→final replace-in-place. Fixed three issues found by using it: (1) `capture.start` envelope must carry a `payload` field even when empty or harkd returns `PROTOCOL_MISMATCH`; (2) engine error frames now unstick the UI from "starting" + surface an inline error banner; (3) Start button needed `cursor-pointer` to read as clickable. See commit `0c5e762`.
- **Phase 4 — session language hint.** Added optional `language` (ISO-639-1) to the `capture.start` payload, locked for the session and threaded into `DecodingOptions.language` at every hop + the flush-on-stop drain. UI surfaces a top-bar language picker (`Auto / English / Tiếng Việt / ไทย / 中文 / 日本語 / 한국어`), disabled while capturing. Default is `Auto` (auto-detect, unchanged behavior). Built clean both sides; **English path verified working; Vietnamese intentionally deferred** (see Open Threads).
- **Phase 4 follow-up — Core Audio Process Taps working end-to-end on macOS 26** ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md)). System-audio capture via Process Taps now captures real audio from **built-in speakers AND Bluetooth headphones** — the latter *without* dropping A2DP→HFP, since we tap only the rendered output and never open the BT mic. This unblocks the core privacy scenario (record a meeting while listening privately on headphones, instead of forcing built-in output that the room can hear). Three stacked bugs, each masking the next, ALL returning `noErr`: (1) Process Taps need the **`kTCCServiceAudioCapture`** TCC service — distinct from Mic/Screen — plus a **stable signed identity** (free Apple Development cert + WWDR-G3 intermediate, launched via `open` for LaunchServices attribution); (2) a non-GUI process must run a **real `CFRunLoop`** on a dedicated thread (`kAudioHardwarePropertyRunLoop`) for the async `AudioDeviceStart` completion — setting it to `NULL` was a no-op on macOS 26; (3) **`isPrivate`/`isExclusive` on the global tap description** let the tap bind (`inputStreams=1`) but silently blocked the aggregate from ever starting (`isRunning=0`). The breakthrough was a runtime **aggregate-state readback** (`isAlive`/`isRunning`/`inputStreams`/`activeSubDevices`, gated by `HARK_TAP_DEBUG=1`) — it showed *composed-but-not-running*, ending four rounds of guess-and-check. Dual-backend retained: `HARK_CAPTURE_BACKEND=tap` (Process Taps) vs default **ScreenCaptureKit** (`SystemAudioTap`, built earlier as the fallback, also working). Verified on M1 / macOS 26.5 (2026-05-31). Cosmetic fix: `Mixer` no longer counts a deliberately-disabled source as an underrun in single-source mode.
- **Phase 4 — MainWindow design fidelity.** First pass at matching the design (`vault/hark/docs/design/ui/artboards/MainWindow.jsx`). Reusable `TranscriptLineComponent` atom (speaker chip + name + mono timestamp + body; speaker optional — renders timestamp+body until Phase 5 diarization sends a speaker). Top bar rebuilt: pulsing `rec-dot` + ticking `REC HH:MM:SS` counter, animated `audio-meter`, the `audio · local-only` trust lozenge, compact conn/RTF dev readout. **Live-tail separation**: finalized utterances render upright in history; in-flight partials float at the bottom italic + dimmed with a blinking `live-caret`, then "commit" upright on finalize. Native macOS chrome wired (`titleBarStyle: 'hiddenInset'` drag region + 78px traffic-light clearance). Verified visually on M1 (2026-05-29 screenshot). Wikilink `[[term]]` parsing from the design NOT ported yet (vault-linking is a later phase).

### ⏳ Next up: Phase 4 surfaces (incremental)

The scaffold from the 2026-05-28 thin slice is in place ([ADR-0010](docs/decisions/0010-phase-4-ui-scaffold.md)). Remaining Phase 4 surfaces, roughly in priority order:

- ✅ ~~Mac-window chrome~~ — drag region + traffic-light clearance done via `titleBarStyle: 'hiddenInset'`. We use the **native** traffic lights (not the design's drawn ones) since this is a real window, not the design canvas.
- ✅ ~~`TranscriptLine` atom + live-tail~~ — done (see Done section).
- **Remaining atoms from the design pass** — `SpeakerTag`, `Eyebrow`, `StatusBanner`, `Toggle`, `CitationChip`. Use `vault/hark/docs/design/ui/artboards/ComponentSheet.jsx` as the visual reference. Build as each gets a home (StatusBanner ↔ warning frames; SpeakerTag ↔ Phase 5; etc.).
- **Bookmark button** — engine already supports `bookmark.create` → `bookmark.created`. Wire the top-bar Bookmark button (⌘⇧B) end-to-end. Small, uses existing contract.
- **Warning banner** — engine emits `warning` frames (e.g. `rtf_high`); renderer currently swallows them into `warnings$` with no UI. Surface via a `StatusBanner` atom (the design's translation-fallback banner is the same component).
- **3-column layout in MainWindow** — `240px (attendees) | 1fr (transcript) | 320px (Q&A preview)`. **Blocked on data:** attendees needs diarization (Phase 5), Q&A needs Claude API (Phase 6). Building empty columns now would be dead UI; keep single-column until there's data.
- **Menu-bar tray** — `TrayMenu.jsx` three states (recording / idle / paused). Implemented via Electron's `Tray` + a small popover renderer.
- **Settings → Privacy pane** — redaction toggles, voiceprint folder, cloud-calls log placeholder. Visual mock in `SettingsPrivacy.jsx`.
- **Manual speaker tagging UI** — the modal + auto-recognition states from `SpeakerTagging.jsx`. WebSocket wiring for `speaker.tag` (engine side not yet implemented; capture as Phase 5 dep).
- **Q&A side panel** — `QAPanel.jsx`. Engine-side Claude API integration is Phase 6 dep; for now this is a placeholder.
- **Onboarding flow** — three screens from `Onboarding.jsx`. Defer until packaging.
- **electron-builder config** — unsigned dev `.app` bundles. Phase 5 packaging-focused ADR.

Estimated effort: 1–2 weeks for the visual surfaces, plus engine-side coupling for speaker tagging and Q&A.

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
9. ~~**Phase 2 — Process Tap drift compensation is off**~~ — **resolved 2026-05-31.** The working Process Tap aggregate sets `kAudioSubTapDriftCompensationKey: true` ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md)).
10. **Vietnamese / non-English transcription quality — deferred, not blocking.** During the 2026-05-29 dev-loop run, English transcribed well but Vietnamese did not catch reliably under auto-detect. User chose to defer tuning. **A session language-hint lever now exists** (top-bar picker → `capture.start` payload `language` → `DecodingOptions.language`), so the first thing to try when we return to this is locking the session to `vi` and comparing quality. If a locked `vi` session is still poor, the ladder is: (a) **initial-prompt vocab injection** from the vault (cheapest, untried — Whisper's `prompt:` param pre-loaded with VN names/terms); then (b) swap to undistilled **`large-v3`** (Argmax CoreML bundle, ~10–15% WER win on hard languages at ~5× compute; still fits the 0.5 RTF budget, projected ~0.37 on M-series); then (c) fine-tunes like PhoWhisper (VN) / biodatlab whisper-th-* (Thai) via manual `whisperkittools` conversion — but these lose code-switching. **Note: language-lock helps single-language sessions but HURTS code-switching** (one language per inference window means English-in-Vietnamese gets butchered). If meetings mix languages heavily, prompt injection (a) is the right lever, not the picker. Capture the WER delta in a new ADR if we swap the model.
11. **Phase 3 VAD is energy-based, not Silero.** `Sources/Harkd/VAD.swift` ships behind a `VAD` protocol so the upgrade is a one-file swap. Trigger to upgrade: if Phase 4 dogfooding shows hallucination on low-energy speech, OR if `large-v3-turbo` swap (open thread #10) brings the same hallucination class back. Silero CoreML model sourcing is the unresolved sub-question — likely an ONNX→CoreML conversion via `coremltools`, or accept ONNX Runtime as a dependency. Capture in a new ADR when we act.
    - **Concrete data point (2026-05-29 dogfood):** in Vietnamese mode the engine emitted the three canonical Vietnamese Whisper hallucinations on silence / low-level noise — "Hãy subscribe cho kênh Ghiền Mì Gõ…" (YouTube outro), "…Thư viện sách nói dành cho người mù thực hiện" / "Dương, Biên soạn và Kể" (audiobook credits), "Lạc Long Quân và Âu Cơ" (folklore narration). These are high-prior phrases burned into the model from scraped YouTube/audiobook training data. **WhisperKit's built-in thresholds do NOT catch them** because the model emits them *confidently* (`noSpeechThreshold` only fires when also low-logprob; `compressionRatioThreshold` only catches internally-repetitive text). The energy VAD at `speechThreshold=0.01` lets low-level noise through, which is what the model hallucinates on. This confirms Silero VAD (gate non-speech *before* Whisper) as the principled fix. A known-phrase blocklist was explicitly rejected — masking model artifacts at the engine boundary violates the same principle as open thread #1 (the trailing `"."`). English did not exhibit this in the same session, so it's also entangled with open thread #10 (non-English quality).
12. **Phase 3 WebSocket has no auth.** Loopback-only bind makes this acceptable per the threat model (only processes on the same Mac can connect). If a future feature ever opens the WS beyond loopback, this assumption breaks immediately and needs ADR-level rework. Don't let it slide.
13. ~~**`harkd` smoke test against a live WS client** is not yet done~~ — **resolved 2026-05-28.** Smoke run on M1 via `websocat` exercised the full path `meta.hello → capture.start → segment.partial/final stream → capture.stop`. The run also caught the v1 utterance-id engulfment bug (see Phase 3 follow-up in Done), now fixed in [ADR-0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md).
14. **Utterance-id soft mutation case** ([ADR-0009](docs/decisions/0009-utterance-id-overlap-rule-v2.md) open question #1) — overlap-of-longer at threshold ~0.5 still permits a UUID to mutate text across re-segmentations when the two intervals are roughly the same size but contain adjacent (not identical) speech. Observed in the 2026-05-28 re-smoke: `E4A8F453` shifted from "You are integrated with your ledger" → "You inherit the ledger contract" (score ≈ 0.58). Bounded — content stays in the same speech vicinity — but Phase 4 will tell us if it's user-visible. Fix would be text-similarity tie-breaking (call it v3); deferred until UI feedback exists.
16. **Process Tap minimal-fix not bisected** ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md) open Q). The working config has BOTH the dedicated `CFRunLoop` AND no `isPrivate`/`isExclusive`. Removing the tap flags was the A/B-confirmed flip (run loop present in both runs); the run loop's strict necessity once the flags are gone is unverified. Kept regardless — correct practice for the long-lived `harkd` daemon.
17. **Tap privacy flag dropped** ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md) open Q). We removed `isPrivate` AND `isExclusive` together to get capture working. If `isExclusive=false` was the real blocker, `isPrivate=true` may be restorable to regain tap isolation — worth a **privacy-auditor** follow-up. Does NOT violate "audio never leaves the machine" (capture still flows only to our IOProc → vault); only affects whether another *local* process could see the tap while it exists.
18. **Default capture backend undecided** ([ADR-0011](docs/decisions/0011-process-tap-system-audio-gotchas.md) open Q). Process Taps now work, but ScreenCaptureKit is still the default; Process Taps are opt-in via `HARK_CAPTURE_BACKEND=tap`. Decide whether to flip the default (and demote SCK to fallback-only) once the tap path has more on-device mileage. Also pending: wiring the proven tap backend into `harkd`'s live path.
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
