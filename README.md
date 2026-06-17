<div align="center">

# 🎙️ Hark

### Local-first meeting transcription for macOS

Live captions · translation · speaker recognition · a markdown second-brain —
**running entirely on your Mac.**

![Platform](https://img.shields.io/badge/platform-macOS%2014.4%2B-black?logo=apple&logoColor=white)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-111)
![On-device](https://img.shields.io/badge/speech--to--text-100%25%20on--device-2ea44f)
![No telemetry](https://img.shields.io/badge/telemetry-none-2ea44f)
![License](https://img.shields.io/badge/license-MIT-blue)
![Status](https://img.shields.io/badge/status-pre--v1-orange)

</div>

---

Hark listens to your microphone and your meeting's system audio, transcribes it **on-device**
with [WhisperKit](https://github.com/argmaxinc/WhisperKit), labels who spoke with
[FluidAudio](https://github.com/FluidInference/FluidAudio) diarization, and writes clean
markdown notes into a vault folder **you** own and control.

No cloud speech-to-text. No account. No telemetry. No background sync.

> [!IMPORTANT]
> **Your meeting content never leaves your Mac** unless *you* explicitly invoke an action that
> sends it somewhere. Transcription, speaker recognition, and storage are 100% on-device.
> The two sensitive features — keeping audio and remembering voices — are **off until you turn
> them on**. See [**Your data & privacy**](#-your-data--privacy) below.

---

## ✨ What Hark does

- 🎧 **Live captions while you record** — your mic and the meeting's system audio, mixed and
  transcribed in near real-time. Tap your meeting audio even while listening on Bluetooth
  headphones, without forcing the room to hear it.
- 🌍 **Translation** — caption languages you don't speak *(quality modes in progress)*.
- 🗣️ **Speaker labels** — after you stop recording, an accurate offline pass labels each line
  ("Speaker 1", "Speaker 2", …). Name them once; with **Remember speakers** on, Hark
  recognizes those voices automatically in future meetings.
- 📝 **A markdown vault** — every meeting is a plain `.md` file with front-matter, transcript,
  and bookmarks. Yours to grep, link, back up, and own forever.
- 🔖 **Bookmarks** — mark a moment mid-meeting and jump back to it later.

---

## 🔒 Your data & privacy

Privacy and trust **are** the product. Hark is built so that lawful, private use is *possible* —
everything stays on your machine, and the sensitive bits are opt-in.

Hark keeps three kinds of data, and **you control each one:**

| What | Why it exists | Stored? | Leaves your Mac? |
|---|---|:---:|:---:|
| 📄 **Transcript** (markdown) | your meeting notes — the product | ✅ always, in your vault | only if *you* sync your vault |
| 🎵 **Audio recording** | re-listen / verify-by-ear review | ⛔ **off by default** — opt-in | ⛔ **off by default** |
| 🧬 **Voiceprints** (`.speakers/`) | recognize known voices across meetings | ⛔ **off by default** — opt-in | ⛔ **off by default** |

### Where everything lives

| Location | Contents |
|---|---|
| `~/Documents/vault/hark` *(configurable)* | Your transcripts. Audio + voiceprints **only if you enable them**. Hark never auto-deletes or silently rewrites this folder, and every change goes through git so your history is recoverable. |
| `~/Library/Application Support/Hark/` | Model cache + preferences. **No transcripts, no audio, no personal content.** |
| `~/Library/Logs/Hark/` | Local-only logs. **Never uploaded.** |

### You opt in — knowingly, and reversibly

The two sensitive features are **off until you turn them on**, and you're asked to choose
during onboarding:

- 🎵 **Keep audio** — save the meeting's audio so you can re-listen later. *Off by default.*
- 🧬 **Remember speakers** — when you name a speaker after a meeting, store a *voiceprint*
  (a mathematical fingerprint of their voice) so Hark can auto-recognize them next time.
  *Off by default.*

Change them any time in **Settings → Privacy**, which shows exactly what's stored and where.

### Syncing is off by default

Audio recordings and voiceprints are **excluded from your vault's git history** (`.gitignored`),
so they never travel through a git remote. If you keep your vault in a folder-syncing service
(iCloud Drive, Dropbox, …), remember those copy *whole folders* — so if you've enabled
audio/voiceprints and want them to stay on this Mac only, exclude them there. Settings → Privacy
spells this out.

> [!WARNING]
> **A note on consent — this is *not* legal advice.**
> Recording conversations and storing voiceprints may require the consent of the other
> participants under your local laws — **you are responsible for obtaining it.** Hark keeps
> everything on your Mac, and keeps these features off by default, to support that.

Full rationale: [ADR-0027 — Privacy & data-control model](docs/decisions/0027-privacy-data-control-model.md).

---

## 🚫 What Hark deliberately does **not** do

- **No cloud speech-to-text.** Transcription is 100% on-device.
- **No telemetry, analytics, or content-exfiltrating crash reporters.**
- **No auto-join** of Zoom / Teams / Meet, and no calendar integration.
- **macOS only** — no Windows, Linux, iOS, or Android.

These are intentional, locked decisions — see the [ADRs](docs/decisions/) for the reasoning.

### Why there's no live "who's speaking now"

Diarizing a *mixed, compressed* meeting stream live (everyone blended into one system-audio
track) isn't reliably solvable on-device today — even the accurate offline pass struggles on
that audio. So speaker labels appear **after** you stop recording, where they're accurate,
rather than showing confidently-wrong labels live. See
[ADR-0025](docs/decisions/0025-no-live-diarization-v1.md).

---

## 🏗️ How it works

```
┌─────────────────────────┐         ws://127.0.0.1 (loopback only)        ┌──────────────────────┐
│   harkd  (Swift daemon)  │ ◄───────────────────────────────────────────► │  Electron + Angular   │
│                          │                                                │       front-end       │
│  mic ─┐                  │                                                │                       │
│       ├─ mixer ─ VAD ─ WhisperKit ─ segments ──►  (over the socket) ──►   │  live captions, tray, │
│  sys ─┘                  │                                                │  settings, vault view │
│                          │                                                │                       │
│  on stop: FluidAudio     │                                                │                       │
│  diarization + enrollment│                                                │                       │
└──────────┬───────────────┘                                                └──────────────────────┘
           │ writes
           ▼
   ~/Documents/vault/hark/*.md
```

A Swift sidecar daemon (`harkd`) does capture + ASR + diarization and exposes a
**loopback-only** WebSocket. The Electron + Angular front-end connects over `ws://127.0.0.1`.
The daemon binds only to localhost, writes its port to app-data, and **never opens an outbound
socket.** Full design rationale: [meetingmind-handoff.md](meetingmind-handoff.md).

---

## 🛠️ Run it from source

> Pre-v1 — there's no released binary yet. **Apple Silicon + macOS 14.4+** required.
> Prerequisites: Xcode + the Swift toolchain (engine), Node 20+ (front-end).

```bash
git clone git@github.com:tuanda2912/hark.git
cd hark

# 1. Build the engine the UI spawns  (do this first)
cd engine && swift build -c release && cd ..

# 2. Run the full dev stack — Angular + Electron; Electron spawns harkd itself
cd ui && npm install && npm run dev
```

First launch downloads + ANE-compiles the model (**~90 s, ~626 MB**), and macOS
prompts for **Microphone** + **System Audio Recording** — grant them to Electron,
then relaunch. Subsequent launches are seconds.

**Packaging** (arm64-only): `npm run pack` builds an unpacked `.app`; `npm run
dist` builds a signed `.dmg` + `.zip`. A free *Apple Development* cert runs
locally; a paid *Developer ID* cert is needed to notarize for other Macs.

📖 **Full runbook — local dev, packaging, code signing, notarization & stapling,
and troubleshooting: [docs/BUILDING.md](docs/BUILDING.md).**

---

## 📂 Project layout

```
hark/
├── engine/                 Swift daemon — WhisperKit ASR + FluidAudio diarization + WS server
│   └── scripts/            dev signing helper
├── ui/                     Electron + Angular 21 front-end
├── docs/
│   ├── decisions/          Architecture Decision Records (the "why")
│   └── BACKLOG.md          deferred-work ledger
├── CLAUDE.md               operating manual / project conventions
├── STATUS.md               current-state snapshot (start here when resuming)
└── meetingmind-handoff.md  full design rationale
```

---

## 📚 Documentation

- **[docs/BUILDING.md](docs/BUILDING.md)** — run from source, package, sign & notarize.
- **[STATUS.md](STATUS.md)** — what's done, what's next, the dev loop. Start here.
- **[docs/decisions/](docs/decisions/)** — every non-trivial decision, with reasoning.
- **[meetingmind-handoff.md](meetingmind-handoff.md)** — the original design rationale.
- **[docs/BACKLOG.md](docs/BACKLOG.md)** — deliberately deferred work.

---

## 📄 License

[MIT](LICENSE) © 2026 Dang Anh Tuan
