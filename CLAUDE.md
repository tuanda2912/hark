# Hark (MeetingMind) — Operating Manual

Hark is a **local-first, macOS-only** meeting transcription tool. Live captions, translation, speaker diarization, and a markdown second-brain — all running on the user's Mac, no cloud ASR.

**Resuming a session?** Read [STATUS.md](STATUS.md) first — it's the current-state snapshot (what's done, what's next, what not to re-litigate). Then this file for the operating manual.

Full design rationale: [meetingmind-handoff.md](meetingmind-handoff.md)
Decision log: [docs/decisions/](docs/decisions/)
Vault location: `/Users/quynhanhquach/Documents/vault/hark` — **outside this repo**.

## Don't re-debate

Stack decisions are locked. If a session suggests revisiting them, point to the relevant ADR in `docs/decisions/` and move on.

- ❌ Cloud ASR (Soniox, AssemblyAI, Deepgram, etc.) — violates the threat model
- ❌ Rust engine — Windows scope was cut, the reason for Rust is gone
- ❌ Tauri 2 — WKWebView quirks, no leverage when engine is a Swift sidecar
- ❌ Full SwiftUI app for v1 — ramp cost too high; revisit for v1.5
- ❌ Windows / Linux / iOS / Android — out of scope
- ❌ Auto-join Zoom/Teams — out of scope
- ❌ Calendar integration — corporate Intune blocks Exchange sync; deferred

See the "rejected" section in the handoff doc and the ADRs for the full reasoning.

## Hard rules (project-specific)

These are non-negotiable. Privacy and trust ARE the product.

1. **Audio never leaves the machine** except through the explicit Claude API path (summary, translation-high-quality mode, in-meeting Q&A). The user must have invoked the action.
2. **Never write transcripts, audio, or PII to disk outside the vault folder** (`/Users/quynhanhquach/Documents/vault/hark`). Models cache and app data go in `~/Library/Application Support/Hark/`.
3. **No telemetry, no analytics, no crash reporters that exfiltrate content.** Local-only logs are fine.
4. **The vault is sacred.** Never auto-delete or auto-rewrite vault files. All changes go through git commits so history is recoverable.
5. **Speaker enrollment data stays local.** Voice embeddings in `vault/.speakers/` never go to any API.
6. **Before adding any dependency that opens a network socket, document it as an ADR.** No silent network calls.

## Workflow

- **Solo pre-v1 development:** direct commits and pushes to `main` are acceptable. Single developer, no production users yet, no external contributors. PR ceremony would be theater.
- **Switch to feature-branch + PR flow when:** v1 ships publicly, external contributors join, or production users depend on `main` stability. At that point this section gets rewritten.
- Branch from `main`. Never branch from another feature branch.
- Don't commit without explicit instruction from the user.
- **Never force-push** to any branch, ever. Force-pushing rewrites shared history.
- Always ask before `reset --hard`, `clean -fd`, branch deletion, or anything that overwrites uncommitted work.

### Commit style

Conventional Commits. Use these types:

- `feat:` — new feature
- `fix:` — bug fix
- `docs:` — documentation only (handoff doc, ADRs, CLAUDE.md)
- `chore:` — tooling, config, dependencies, build scripts
- `refactor:` — code restructure with no behavior change
- `test:` — adding or fixing tests
- `perf:` — performance improvement with no behavior change

Example: `feat(engine): wire WhisperKit large-v3-turbo into batch transcribe path`

### Decision log

Every non-trivial decision gets an ADR in `docs/decisions/`. Triggers:

- Picking between two viable libraries / tools / architectures
- Rejecting a tempting option (so future-you doesn't re-litigate)
- Any privacy / threat-model judgement
- Anything you'd say "that's a good question" to in a code review

Use the template in [docs/decisions/0000-template.md](docs/decisions/0000-template.md). Number sequentially. Never edit an accepted ADR's *decision* — supersede it with a new ADR instead.

## Repo layout (target — most folders don't exist yet)

```
hark/
├── engine/                 Swift / Xcode project — WhisperKit + ScreenCaptureKit + WS server
├── ui/                     Electron + Angular 21
├── scripts/                Build, sign, notarize, package
├── docs/
│   └── decisions/          ADRs
├── .claude/
│   └── agents/             Sub-agent definitions
├── CLAUDE.md
└── meetingmind-handoff.md
```

## Build / run commands

Empty until Phase 0 lands. Fill in as commands stabilize.

```
# (todo) bench:       run Phase 0 RTF harness
# (todo) engine:dev:  launch Swift engine in debug mode
# (todo) ui:dev:      launch Electron+Angular against a running engine
# (todo) package:     build, sign, notarize the full app
```

## Where things live

| Thing | Location |
|---|---|
| Source repo | `/Users/quynhanhquach/Documents/project/hark` |
| Vault (user's notes + transcripts + speaker enrollments) | `/Users/quynhanhquach/Documents/vault/hark` |
| App data (models cache, prefs) | `~/Library/Application Support/Hark/` |
| Logs (local only) | `~/Library/Logs/Hark/` |
| Handoff doc (design rationale) | `meetingmind-handoff.md` |
| ADRs (decision history) | `docs/decisions/` |

## User context

Quynh Anh — Java/Spring backend (7+ yrs), strong Angular, no Swift yet, no Rust yet. Mac on Apple Silicon, based in Thailand. This project is both a real product *and* an L4 AI-mastery learning project. Explain Swift idioms in terms of Java/Spring analogues when helpful. Push back on bad decisions with reasoning, don't hedge.
