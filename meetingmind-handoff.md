MeetingMind — Project Handoff
Context
Personal product. Building a local-first meeting transcription tool because I don't trust closed-source binaries (like altalt.io / Alt) listening to my work calls. Alt is the inspiration but is closed-source, so I want my own.

Reminder for Claude: policy/legal angle — recording work calls touches corporate recording policies + Thai PDPA + EU GDPR. The tool is fine to build; using it on real work calls needs manager/DPO sign-off. Don't re-litigate this.

Goals
macOS-only (Apple Silicon). No Windows, no Linux, no mobile. Scope is locked.
Live meeting transcription, fast + precise
Personal product I'd actually trust and ship
Features (v1 scope)
Live transcription + translation
Real-time subtitle from system audio + mic, low-latency
Translation mode toggle in settings:
  - Fast: local NLLB-200 (CoreML, ~600MB), <500ms per chunk, works offline
  - High quality: Claude API per VAD-chunk (3–5s blocks), better for Thai↔EN nuance
Speaker labels: manual-tag first appearance, voice fingerprint remembers across meetings (no calendar integration in v1 — corporate IT blocks Exchange sync)
Bookmark hotkey (⌘⇧B) to flag moments during the meeting; flagged moments weighted in summary
Vault (second brain)
Plain markdown folder, Obsidian-compatible ([[wikilinks]], frontmatter)
Git-backed versioning (auto-commit on save) — full history, blame, restore. NOT building Confluence-style visual diffs in v1.
Whisper initial-prompt vocab auto-grows from vault terms (precision compounds with use)
Auto-link entities during transcription: known vault terms get wrapped as [[links]] live
In-meeting & post-meeting intelligence
LLM Q&A over vault + all past transcripts (RAG with local embeddings, BGE-small or nomic via CoreML)
  - Expectation: in-meeting Q&A is for *recall* (1–3s Claude API latency), not reflex
Term capture panel: detected terms get inline vault snippet alongside the transcript
Post-meeting LLM pass extracts: summary, action items {owner, due}, decisions, open questions
LLM-generated chapters/timeline (jump-to topic in playback)
Outputs
One-click export: Meetings/YYYY-MM-DD-{title}.md into vault folder with frontmatter (attendees, duration, action items)
Semantic search bar across vault + transcripts (reuses RAG embeddings)
Privacy
Always-visible pause/resume capture button
Redact-before-send toggle for the Claude API path (PII strip)
Deferred (post-v1)
Calendar integration (blocked by corporate Intune on Exchange)
Active-speaker OCR from Teams window (fragile, breaks on Teams updates)
Auto-join Zoom/Teams meetings
Confluence-style visual version diffs (git history covers it)
Stack — DECIDED, don't re-debate
Layer	Choice
UI	Electron + Angular 21 (menu-bar tray + main window)
Engine	Swift binary — WhisperKit (CoreML / Apple Neural Engine) + Silero VAD CoreML
Audio capture	Swift — ScreenCaptureKit (system audio) + AVAudioEngine (mic), mixed → 16kHz mono PCM
Diarization	FluidAudio (Swift, CoreML pyannote port) — runs on ANE, post-meeting
Summary + chat	Claude API (Sonnet 4.7) with prompt caching on transcript
IPC	Localhost WebSocket (Swift engine ↔ Electron UI), single sidecar binary
Why WhisperKit + Swift engine (not whisper.cpp Metal, not Python, not Rust):

Uses Apple Neural Engine, not just Metal — ~30–40% faster than whisper.cpp on M-series
First-party CoreML model bundles from Argmax, no quantization tradeoffs
ScreenCaptureKit + AVAudioEngine are first-party APIs — no FFI lag against new macOS releases
One language for engine + capture + diarization, single signed binary
Code sign + notarize is one Xcode checkbox
Why Electron (not Tauri 2, not native SwiftUI):

Chromium = predictable rendering. Tauri's WKWebView hits Safari-specific CSS/JS quirks
Angular 21 + Chrome DevTools = familiar, ships UI in days not weeks
electron-updater, notarize tooling, Sentry — all battle-tested
WhisperKit holds ~1.5GB in memory; Electron's 200MB shell is noise
SwiftUI ramp from zero would burn 2+ weeks on tray + live transcript yak-shaving
Why not full SwiftUI: zero Swift UI experience would cost weeks on menu-bar + live list rendering quirks. Saved for a possible v1.5 native polish pass.

Repo layout (pnpm monorepo + Xcode project)
meetingmind/
├── engine/           Xcode project, Swift binary — WhisperKit + ScreenCaptureKit + WS server
├── ui/               Electron + Angular 21
└── scripts/          Build, sign, notarize, package
Speed/precision decisions (non-negotiable for live UX)
Setting	Value
Model	WhisperKit large-v3-turbo (CoreML bundle from Argmax, ~800MB)
VAD	Silero CoreML — chunks on speech boundaries
Window	30s sliding, 5s hop, re-transcribe overlap
Initial prompt	Auto-inject vocab: attendee names, "Pre-Arrangement", "Camunda", "SIMB"
Language	auto with TH+EN hint (code-switching is my real case)
Audio	16kHz mono PCM s16le, resampled in capture
Engine context	One WhisperKit instance, dedicated queue, ring buffer
Backpressure	Drop oldest unprocessed segment if RTF > 1, log warning
Target latency	< 1.5s spoken word → visible text
Target RTF	< 0.5
Phased plan
Phase	What	Duration
0	Validate: WhisperKit + ScreenCaptureKit demo, measure RTF on my Mac	1 day
1	Swift engine v0: file in (PCM) → JSON segments out, batch mode	3–5 days
2	Capture: ScreenCaptureKit + AVAudioEngine → mix → 16kHz mono	3–5 days
3	Streaming: sliding window + WebSocket server (Swift NIO or Vapor)	3–5 days
4	Electron + Angular: menu-bar tray, main window, live transcript view	1–2 weeks
5	Diarization: FluidAudio integration, post-meeting	2–3 days
6	Claude integration: summary + chat, prompt caching on transcript	2–3 days
7	Hardening: code sign, notarize, electron-updater, settings, hotkeys	1–2 weeks
Total: 5–7 weeks evenings/weekends. Phase 0–3 (~2 weeks) = useful CLI.

Resolved decisions (2026-05-24)
Apple Developer account: DEFERRED. Hark stays open-source local-devs for now — no App Store, no signed-and-notarized distribution. Users build from source. Revisit if/when public distribution becomes the goal.
macOS floor: LIBRARY-DRIVEN. Use the latest version of WhisperKit / FluidAudio / ScreenCaptureKit APIs; the OS floor is whatever those libraries require (likely macOS 14+, possibly 15+ for newer WhisperKit features). Document the actual floor once Phase 0 pins library versions.
Next action when resuming
Phase 0 validation script — a Swift harness that records 60s of system audio via ScreenCaptureKit, runs WhisperKit large-v3-turbo, prints actual RTF + sample transcript on my Mac. One hour to a real go/no-go.

What's been rejected (don't re-suggest)
Rust engine (whisper-rs/cpal/screencapturekit-rs) — was for Windows reuse, scope is now macOS-only
Pure Python engine (packaging hell, GIL pauses in long sessions)
Tauri 2 (WKWebView quirks for Angular, no Rust-backend leverage when engine is a Swift sidecar)
Full SwiftUI app (ramp cost too high; revisit for v1.5)
Windows / Linux / iOS / Android — out of scope
Quiz generation, Discord integration, 100+ language UI (Alt features I don't need)
My background (for Claude)
Java/Spring Boot 7+ yrs, Angular, Kafka, Camunda, banking/insurance domains. No Swift yet (will learn enough for the engine binary). Mac on Apple Silicon. Working in Thailand. L3 → L4 on AI mastery ladder.
