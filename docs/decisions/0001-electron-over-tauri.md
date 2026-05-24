# ADR-0001: Electron over Tauri 2 for the UI shell

- **Date:** 2026-05-24
- **Status:** Accepted
- **Deciders:** Quynh Anh

## Context

Hark needs a desktop shell to host the Angular 21 UI and talk to the Swift engine binary over localhost WebSocket. Two viable options for a 2026 macOS-only product: **Electron** (Chromium + Node, 11 years mature) and **Tauri 2** (WKWebView + Rust, stable since Oct 2024).

The earlier project draft assumed cross-platform support (Windows v2 reusing a Rust engine), which made Tauri's Rust-native backend attractive. That assumption was dropped — see [ADR-0002](0002-macos-only-scope.md) — so the question was reopened: with macOS as the only target and the engine as a separate Swift binary, does Tauri still win?

## Decision

Use **Electron** + Angular 21 for the UI shell.

## Alternatives considered

- **Tauri 2** — Rust backend + WKWebView frontend, ~10 MB binary, low idle RAM.
  - ✅ Pros: Tiny bundle, low RAM, modern, no Chromium baggage.
  - ❌ Cons: WKWebView is Safari's engine — Angular hits Safari-specific CSS/JS quirks; Safari Web Inspector instead of Chrome DevTools; Rust-backend advantage is moot because the engine is a separate Swift binary; smaller ecosystem for code-sign/notarize/auto-update.
  - **Why rejected:** the strategic reason to pick Tauri (Rust everywhere) disappeared when the engine moved to Swift. What remains is WKWebView quirks against a UI built in Angular, with no offsetting architectural win.

- **Full native SwiftUI app** — no web layer at all.
  - ✅ Pros: One language, one binary, lowest RAM, native polish.
  - ❌ Cons: Developer has zero Swift UI experience; menu-bar + live transcript list quirks would burn 2+ weeks of learning vs. familiar Angular.
  - **Why rejected:** ramp cost too high for v1. Revisit for v1.5 native polish pass — see [ADR-0008](0008-defer-swiftui-port.md) (TODO).

## Consequences

**Positive:**
- Predictable Chromium rendering across the whole UI surface.
- Familiar Chrome DevTools, no new debugger to learn.
- Battle-tested tooling: electron-updater, electron-builder for sign + notarize, Sentry-style crash reporting if ever needed (subject to [privacy hard rule #3](../../CLAUDE.md)).
- UI ships in days, not weeks.

**Negative / tradeoffs accepted:**
- ~200 MB bundle size and ~150 MB idle RAM overhead. Acceptable because WhisperKit holds ~1.5 GB in memory; the shell is noise.
- Electron security model requires care — strict CSP, no remote content, contextIsolation on, nodeIntegration off. Enforced by [privacy-auditor agent](../../.claude/agents/privacy-auditor.md).
- A future cross-platform port (Windows) would need to rebuild the engine bridge anyway, so Electron's portability is not a current asset.

**Assumptions that must hold:**
- The engine remains a separate Swift binary talking over localhost — if it ever moves into the shell process, this calculus flips.
- macOS remains the only target. A Linux target would re-introduce Electron's footprint as a real concern.

## Open questions

None.

## References

- Project handoff doc: [meetingmind-handoff.md](../../meetingmind-handoff.md) — "Why Electron" section
- Conversation that produced this ADR: stack reconsideration on 2026-05-24
