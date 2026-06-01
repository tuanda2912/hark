# ADR-0021: macOS app packaging — Electron + bundled harkd sidecar

- **Date:** 2026-06-02
- **Status:** Accepted
- **Deciders:** Dang Anh Tuan

## Context

Hark ships as a macOS app: an Electron + Angular UI shell plus a Swift engine
sidecar (`harkd`) that does capture, ASR, and diarization. Until now there was no
packaging at all — the engine ran from `swift build` output and the UI from `ng serve`.
We need a real `.app` that bundles the sidecar, signs everything, and is
notarization-ready, without violating the local-first privacy posture (no auto-update,
no telemetry) and without breaking the hard-won TCC audio-capture attribution
(ADR-0011/0012): the system-audio grant must attribute to the **app** and persist
across launches, even though capture happens in the `harkd` child process.

A constraint shaped the whole approach: the user has a **free "Apple Development"**
cert, not a paid **Developer ID**. The free cert can sign for local execution (enough
to validate the app + TCC on-device) but **cannot notarize**.

## Decision

Package with **electron-builder**. `harkd` is a **single self-contained static
binary** (verified: `otool -L` shows only system frameworks + the OS Swift runtime;
WhisperKit/FluidAudio/NIO are statically linked — no dylibs/frameworks to co-locate),
shipped via `extraResources` to `Contents/Resources/engine/harkd`. **Hardened runtime**
on. App entitlements: `allow-jit`, `allow-unsigned-executable-memory` (Electron
requirement), `device.audio-input`. Nested binaries (incl. `harkd`) get **inherit**
entitlements: `com.apple.security.inherit`, `allow-jit`, `device.audio-input` — so
`harkd` runs under the app's identity and TCC attributes the audio grant to **Hark**.
Bundle id **`com.hark.app`**, **arm64-only** for v1.

**Local-signed-first:** validate the packaged app + TCC attribution on-device with the
free cert; **notarization (Developer ID) is deferred to BACKLOG**. The `afterSign`
notarize hook (`build/notarize.js`) no-ops unless `APPLE_*` env vars are present, so dev
builds never contact Apple.

Disable Angular's **critical-CSS inlining** (`optimization.styles.inlineCritical:
false`): its async-stylesheet trick uses an inline `onload` handler, which the strict
CSP (`script-src 'self'`, no `'unsafe-inline'`) blocks — leaving the app unstyled in the
packaged `file://` context. Disabling it emits a plain `<link>` (zero cost for a local
file load; critical-CSS inlining only helps over a network).

**Verified on-device (2026-06-02):** packaged app launches, `harkd` spawns from the
bundle, the system-audio prompt names **"Hark"**, transcription works, and the grant
**persists across relaunch**.

## Alternatives considered

- **electron-forge** instead of electron-builder.
  - ✅ Also bundles + signs.
  - ❌ electron-builder's `extraResources` + `entitlementsInherit` + notarize-hook story
    is more direct for our case; STATUS already named it.
  - **Why rejected:** no leverage to switch; electron-builder fit cleanly.
- **Sign `harkd` with its own code identity** (as the dev bundle does, `com.hark.daemon.dev`).
  - ❌ TCC would attribute the audio grant to "harkd", not "Hark" — a confusing System
    Settings entry and a grant that may not persist.
  - **Why rejected:** `com.apple.security.inherit` is the unlock for app-attributed TCC.
- **App Store sandbox** (`com.apple.security.app-sandbox`).
  - ❌ Would break the loopback WS handshake, the out-of-container vault
    (`~/Documents/vault/hark`), and Process Tap APIs. Not required for notarization.
  - **Why rejected:** incompatible with the architecture; only the App Store needs it.
- **Notarize now.**
  - ❌ Requires a paid Developer ID we don't have; and notarizing before confirming the
    app even works on-device is premature.
  - **Why rejected:** local-signed first validates the riskiest unknown (TCC) for $0;
    notarization is the last mile (BACKLOG).
- **Keep critical-CSS inlining; add `'unsafe-inline'` to `script-src`.**
  - ❌ Weakens the strict CSP that's core to the privacy posture (ADR-0001, rule #3).
  - **Why rejected:** disable the optimization instead — it has no value for a local app.
- **Universal (arm64 + x86_64) build.**
  - ❌ Would need a `lipo`-merged universal `harkd`; an arm64-only sidecar in a universal
    host crashes on Intel with no clear error.
  - **Why rejected:** Apple Silicon is the only supported target (CLAUDE.md).

## Consequences

**Positive**
- Single static `harkd` → no dylib co-location / `@rpath` rewriting (the classic
  hardened-runtime signing footgun avoided entirely).
- TCC attributes audio capture to **Hark** and the grant persists — verified on-device.
- Strict CSP preserved; entitlements minimal (privacy-audited; the broad
  `allow-unsigned-executable-memory` is app-only, never inherited by `harkd`).
- No auto-update, no telemetry; the notarize hook only ever contacts Apple, env-gated.

**Negative / tradeoffs accepted**
- A local-signed app is **not Gatekeeper-clean on other Macs** until notarized — fine for
  dogfooding, blocks distribution until a Developer ID is obtained (BACKLOG).
- **arm64-only** (Intel would need a universal build).
- Critical-CSS inlining off → marginally more render-blocking CSS (negligible on `file://`).
- Two-step build: `swift build -c release` (engine) must run before `electron-builder`.

**What needs to remain true**
- `harkd` stays a single self-contained binary. If it ever gains dynamic framework deps,
  revisit the bundling + deep-signing.
- The strict CSP stays — so keep `inlineCritical: false`.
- Apple Silicon only.

## Open questions

- **Notarization + Developer ID** — the distribution gate (BACKLOG).
- **App icon** — no `build/icon.icns` yet; default Electron icon for now (BACKLOG).
- **First-run model-download UX** — ~626 MB downloads on first use with no progress yet
  (BACKLOG).
- Universal build — only if Intel ever comes into scope (not planned).

## References

- ADR-0001 (Electron over Tauri), ADR-0011 (Process Tap TCC gotchas), ADR-0012 (lazy
  permissions / startup)
- `ui/electron-builder.yml`, `ui/build/entitlements.mac.plist`,
  `ui/build/entitlements.mac.inherit.plist`, `ui/build/notarize.js`
- `docs/BACKLOG.md` (notarization, icon, first-run UX deferrals)
- build-release-expert packaging plan + privacy audit (session 2026-06-02)
