# Hark UI — Electron + Angular 21

Phase 4 of [Hark](../README.md). This is the user-facing shell that talks to `harkd` over a localhost WebSocket.

Stack decisions live in [ADR-0010](../docs/decisions/0010-phase-4-ui-scaffold.md).

## Prerequisites

- Node 20+ (`.nvmrc` pins to 20; run `nvm use` if you have nvm).
- The engine binary built: `cd ../engine && swift build -c release`.
- macOS 14.4+ (inherited from the engine's audio capture API floor).

## First-time setup

```bash
cd ui
npm install
```

## Dev loop

```bash
npm run dev
```

This boots three watchers in one terminal:

| Process | What it does |
|---|---|
| `ng` | Angular CLI dev server on `:4200`, rebuilds renderer on save |
| `tsc` | Compiles `src/main/` to `dist/main/` on save (Electron main) |
| `el` | Waits for `:4200`, then launches Electron pointed at it |

Electron's main process **spawns `harkd` itself** at startup — you do not need a separate `harkd` running. The renderer connects to the port that `harkd` writes to `~/Library/Application Support/Hark/engine.port`.

First launch on this machine: harkd compiles WhisperKit's CoreML bundles to ANE before writing the port file. **On M1 this can take ~90 seconds** (see STATUS open thread #15). The renderer's connection-state badge will sit on `connecting…` for the duration. Subsequent launches are seconds — the compiled bundle is cached.

## Layout

```
ui/
├── package.json           Two-build setup (Angular CLI + plain tsc)
├── angular.json           Renderer build config
├── tailwind.config.js     Design tokens piped through CSS vars
├── tsconfig.app.json      Compiles src/main.ts + src/app/**
├── tsconfig.main.json     Compiles src/main/** (Electron main)
├── src/
│   ├── styles.css         Tailwind layers + tokens import
│   ├── styles/tokens.css  Copied verbatim from the design pass
│   ├── index.html         Renderer HTML + CSP
│   ├── main.ts            Angular bootstrap
│   ├── app/
│   │   ├── app.component.{ts,html,css}
│   │   ├── app.config.ts
│   │   └── services/
│   │       ├── engine.types.ts    Wire payload types (must match Swift)
│   │       └── engine.service.ts  WS connection + signals + segment map
│   └── main/                       (Electron main process)
│       ├── main.ts                 Entry, window setup, IPC handler
│       ├── preload.ts              contextBridge — window.hark API
│       ├── harkd-spawn.ts          Child-process lifecycle + readiness
│       └── port-file.ts            ~/Library/.../engine.port reader
└── README.md              this file
```

## Production-style local run (no ng serve)

To test the prod loading path without booting `ng serve`:

```bash
npm run build                    # builds renderer + compiles main
HARK_USE_DIST=1 npx electron .   # loads dist/renderer/browser/index.html
```

`HARK_USE_DIST=1` forces the file:// load. In a packaged `.app` (Phase 5), `app.isPackaged` is true and the env var isn't needed.

## First-run macOS permissions

The first time Electron tries to spawn `harkd`, macOS asks for **Screen Recording** (for system-audio capture via Core Audio Process Taps) and **Microphone** permissions. These attach to the **Electron parent process**, not to `harkd` itself ([ADR-0007](../docs/decisions/0007-active-permission-request.md)).

If you previously granted these to your Terminal (for the `hark-capture` CLI or `harkd` standalone smoke tests), they don't transfer — you need to grant them to Electron once.

After granting:
1. Quit Electron completely (`Cmd+Q`).
2. Relaunch. macOS may require a second relaunch before the grant is honored — this is a TCC quirk, not a Hark bug.

Bundling into a distributable `.app` (with the harkd binary inside `Contents/Resources`) is **Phase 5** scope and waits on the packaging ADR.

## Privacy guardrails enforced here

- **CSP in `index.html`** forbids remote scripts, only allows `ws://127.0.0.1:*` for the engine connection. No fonts, no images, no analytics from anywhere off the machine.
- **`contextIsolation: true`, `nodeIntegration: false`, `sandbox: true`** in `main.ts` — only the explicit `window.hark` API crosses the bridge.
- **`shell.openExternal`** for `<a target="_blank">` — never opens remote URLs inside Electron windows.
- **No telemetry, no auto-update, no crash reporter** — see Hard Rule #3 in [CLAUDE.md](../CLAUDE.md).

The [`privacy-auditor` agent](../.claude/agents/privacy-auditor.md) inspects changes to this folder for regressions.
