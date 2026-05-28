# ADR-0010: Phase 4 UI scaffold — Electron + Angular 21 + Tailwind + signals

- **Date:** 2026-05-28
- **Status:** Accepted
- **Deciders:** Quynh Anh

## Context

[ADR-0001](0001-electron-over-tauri.md) locked the shell to **Electron + Angular 21**. With Phase 3 (`harkd`) shipping a stable WebSocket contract, Phase 4 needs to stand up an actual UI. This ADR captures the per-stack-layer choices that didn't fit into ADR-0001's level: build tooling, styling library, state management, dev loop shape, and the first-commit scope.

The design pass that lives in `vault/hark/docs/design/ui/` is a React/HTML prototype — purely a visual contract, not source. Tokens (`styles/tokens.css`, 350 lines) are explicitly meant to be lifted into the renderer's theme.

This is also the developer's first time wiring Electron + Angular together as a desktop app. The decisions below favor "things that match Angular idioms a Java/Spring developer will recognize" over "shortest path."

## Decision

The scaffold under `ui/` uses:

1. **Build / project structure** — hand-rolled Angular 21 project (no `ng new`), standalone components only, no NgModule. Two TypeScript build paths via separate tsconfigs:
   - `tsconfig.app.json` → Angular CLI builds the renderer into `dist/renderer/`
   - `tsconfig.main.json` → plain `tsc` builds the Electron main process into `dist/main/`

2. **Styling** — **Tailwind CSS v3** with the design tokens piped through CSS custom properties:
   - `src/styles/tokens.css` carries `:root` + `[data-theme="dark|light"]` blocks lifted verbatim from the design pass.
   - `tailwind.config.js` `theme.extend.colors` references the CSS vars (e.g. `bg: 'var(--bg)'`), so Tailwind utilities like `bg-bg`, `text-text-2`, `border-border-2` resolve through the theme.
   - Theme switching becomes a one-attribute toggle on `<html>`.

3. **State management** — Angular signals (`signal`, `computed`, `effect`) for component state; a single `EngineService` holds the WebSocket connection and exposes RxJS `Subject`s for streaming frame events. No NgRx, no Redux. Single-window app at this scope doesn't earn the ceremony.

4. **Dev loop** — `ng serve` on `:4200` plus `tsc --watch` for the main process plus `electron .` once both are ready. Electron main checks `app.isPackaged` to decide between `http://localhost:4200` (dev) and `file://.../dist/renderer/index.html` (prod). Coordinated by `concurrently` + `wait-on` so a single `npm run dev` brings everything up.

5. **Engine bridge** — Electron main is the lifecycle owner: it spawns `engine/.build/release/harkd`, polls for `~/Library/Application Support/Hark/engine.port`, parses the JSON, and exposes the port to the renderer via `contextBridge` + a typed `window.hark` API. The renderer connects to the WebSocket directly using the browser-native `WebSocket` — keeps the WS protocol logic in one place (the renderer) and matches Hard Rule #1 because the loopback bind already gates external access.

6. **First-commit scope** — thin slice: scaffold + harkd spawn + WS connect + a minimum live-transcript view (one component reading `segment.partial` / `segment.final` events and rendering them as TranscriptLine-style rows). Tray, Q&A, settings, post-meeting review, speaker tagging all land in follow-up commits. The thin slice exists to prove the dev loop end-to-end before piling on UI surfaces.

## Alternatives considered

- **`ng new` with Angular Material.** Tempting because it produces a working project in 30 seconds. Rejected for two reasons: (a) the design has its own opinionated visual language (muted accent, smallcaps speaker chips, mac-window chrome) that Material would fight, and (b) `ng new` ships Karma + Jasmine + Protractor scaffolding we don't need at v1.

- **Plain CSS, no Tailwind.** Lighter dep tree, matches the design pass's idiomatic CSS-custom-property pattern most literally. Loses Tailwind's iteration speed for prototype work. User picked Tailwind explicitly; recorded here for posterity.

- **Tauri 2.** Already rejected in ADR-0001, mentioned only so a future session doesn't re-litigate.

- **NgRx for state.** Heavier, more files, more ceremony. Right for a multi-window app with cross-cutting state; overkill for a single window with one WebSocket source of truth.

- **WebSocket connection in the main process, forwarded over IPC.** Cleaner separation of concerns — main owns the engine handle, renderer is a pure view. Rejected for v1 because it doubles the message-shape code (Swift → JSON → IPC → renderer) and the loopback security control is already sufficient. Revisit if we ever need to share one engine across multiple renderer windows.

- **Vite-only setup (no Angular CLI).** Faster dev server, smaller config surface. Angular's first-class story is still `ng build` / `ng serve`; deviating would mean fighting the toolchain. Revisit if Angular's Vite story matures further.

## Consequences

### Positive

- Standard Angular 21 idioms throughout — anyone with Angular experience can navigate the renderer code without onboarding. Maps cleanly to the developer's existing Angular knowledge.
- Theme switching is one DOM attribute (`<html data-theme="light">`) without any JS recomputation, because CSS variables propagate.
- The two-tsconfig split keeps Electron's `electron` API out of the renderer compile graph (which would pull in Node types and break Angular's type-checking). The opposite direction is also clean — main process can't accidentally import an Angular service.
- The dev loop is `npm run dev` from `ui/`. No script wrapping, no per-machine `.env`.

### Negative / tradeoffs accepted

- **Two build systems** (Angular CLI + plain `tsc`) means two watch processes and two error-reporting formats during development. Manageable; mirrored in concurrently's prefixed output.
- **Tailwind through CSS vars** means utility classes are only as good as the var bindings we declare. Tailwind's color opacity modifiers (`bg-bg/50`) don't work natively on `var(--bg)` references without extra config. Workaround documented in `tailwind.config.js` once it bites.
- **No automated tests in the scaffold.** Matches the engine side (HarkCaptureTests is a placeholder) and the solo pre-v1 workflow. The cost of adding Jasmine/Karma upfront outweighs the benefit at this stage; revisit when the UI has enough surface to be worth gating with tests.
- **Renderer-side WebSocket** means if we ever need to multiplex engine output to multiple windows, we'll either need to lift the WS into main or maintain N connections. Not a problem for the foreseeable future (single-window app), but worth flagging.
- **First-commit thin slice means several design surfaces are not yet wired.** Tray, Q&A, settings, speaker tagging all listed in the Phase 4 description in STATUS.md will land in follow-up commits. STATUS.md will track per-surface completion.

### Assumptions that must hold

- The user has `node >= 20` and `npm >= 10` on the dev machine. Pinned by `.nvmrc` and `engines` in `package.json`.
- The engine binary at `engine/.build/release/harkd` exists before the UI is launched. The Electron main process surfaces a clear error if the binary isn't there (with a hint to run `swift build -c release` in `engine/`). Phase 5's packaging step will bundle the binary; until then, dev-mode users build it manually.
- `~/Library/Application Support/Hark/engine.port` is the canonical port-discovery channel. Documented in ADR-0008 §1.

## Open questions

1. **Production bundling of `harkd`.** Phase 4 dev mode reads the binary from `engine/.build/release/`. For a distributable `.app`, we need to copy the binary into the Resources folder and `app.isPackaged ? bundledPath : devPath`. Defer to a later ADR when we wire `electron-builder` config.
2. **Code signing + notarization.** ADR-0001's reasoning assumed paid Apple Developer ID. The 2026-05-24 "unsigned dev builds" deviation in STATUS.md says signed builds are deferred. Open thread; capture in a packaging-focused ADR when we get there.
3. **Auto-updater.** `electron-updater` is the standard. Adds telemetry-shaped network calls that need to clear Hard Rule #3 (no exfiltration). Defer until v1 ships and we have a real release channel.
4. **Renderer-side persistence.** State that should survive a renderer reload (e.g. window position, pinned bookmarks, theme choice) needs somewhere to live. `localStorage` is the obvious answer; Electron's `electron-store` is a wrapper if we want JSON files in the app data dir. Pick when the first such state shows up.

## References

- [ADR-0001](0001-electron-over-tauri.md) — Electron over Tauri 2 (stack-level decision)
- [ADR-0008](0008-phase-3-streaming-architecture.md) — Phase 3 streaming architecture (the WS contract the renderer consumes)
- [ADR-0009](0009-utterance-id-overlap-rule-v2.md) — utterance_id v2 (the contract guarantee Phase 4 relies on)
- Design pass: `vault/hark/docs/design/ui/` — visual contract, tokens to lift
- Renderer entry: `ui/src/main.ts`
- Electron main entry: `ui/src/main/main.ts`
