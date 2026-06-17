# Building, running & signing Hark

The full developer runbook: clone → run locally → package → sign → notarize.

> **Pre-v1.** There's no released binary yet — these are the from-source steps.
> **Apple Silicon + macOS 14.4+ required** (the audio-capture APIs have no Intel
> path; see [ADR-0011](decisions/0011-process-tap-system-audio-gotchas.md)).

For *why* the architecture is shaped this way, see
[meetingmind-handoff.md](../meetingmind-handoff.md) and the
[ADRs](decisions/). For current state, see [STATUS.md](../STATUS.md).

---

## 1. Prerequisites

| Need | Why | Check |
|---|---|---|
| **macOS 14.4+** | Core Audio Process Tap behavior validated on 14.4+ | `sw_vers` |
| **Apple Silicon** (M-series) | WhisperKit runs on the Apple Neural Engine; no Intel target | `uname -m` → `arm64` |
| **Xcode + Swift toolchain** | builds the `harkd` engine | `swift --version` |
| **Node 20+** | builds the Electron + Angular front-end (`.nvmrc` pins 20) | `node --version` |
| **An Apple code-signing identity** *(optional in dev)* | system-audio capture needs a *stable* signed identity for the TCC grant to attribute + persist | `security find-identity -v -p codesigning` |

A **free "Apple Development"** certificate (from any personal Apple ID in Xcode →
Settings → Accounts) is enough to **run and validate** the app on this Mac.
A paid **Developer ID Application** certificate is required only to **notarize**
for distribution to other Macs (see §6).

---

## 2. One-time setup

```bash
git clone git@github.com:tuanda2912/hark.git
cd hark

# Front-end deps
cd ui && npm install && cd ..
```

The engine (`harkd`) has no separate install step — `swift build` resolves its
SwiftPM dependencies on first build.

---

## 3. Run it locally (the dev loop)

**Order matters: build the engine first, then run the UI.** The Electron main
process spawns `harkd` itself — you do **not** run a separate engine process.

```bash
# 1. Build the engine binary the UI will spawn
cd engine && swift build -c release && cd ..

# 2. Boot the full dev stack (Angular dev server + Electron + harkd)
cd ui && npm run dev
```

`npm run dev` runs three watchers in one terminal:

| Tag | Process | Role |
|---|---|---|
| `ng`  | `ng serve` on `:4200` | rebuilds the Angular renderer on save |
| `tsc` | `tsc -p tsconfig.main.json --watch` | compiles the Electron main process |
| `el`  | `electron .` | waits for `:4200`, then launches; spawns `harkd` |

**First launch on a new machine is slow.** `harkd` downloads (~626 MB) and
ANE-compiles the WhisperKit model — **up to ~90 s on first run**; the connection
badge sits on `connecting…` meanwhile. Subsequent launches are seconds (the
compiled bundle is cached under `~/Library/Application Support/Hark/`).

### First-run macOS permissions

On the first capture, macOS prompts for **Microphone** and **System Audio
Recording**. In the dev loop these attach to the **Electron** parent process
([ADR-0007](decisions/0007-active-permission-request.md)). After granting:

1. Quit Electron fully (`⌘Q`).
2. Relaunch. macOS sometimes needs a second relaunch before honoring the grant —
   a TCC quirk, not a bug.

> Permissions you previously granted to Terminal (for standalone engine smoke
> tests) do **not** transfer to Electron — grant them to Electron once.

### Production-style local run (no `ng serve`)

To exercise the packaged `file://` load path without building a `.app`:

```bash
cd ui
npm run build                    # renderer + main → dist/
HARK_USE_DIST=1 npx electron .   # loads dist/renderer/browser/index.html
```

---

## 4. Engine-only testing (capture without the UI)

To exercise capture/transcription straight against the engine, use the project
skills — they encode the signed-bundle + launch-via-`open` recipe that TCC needs:

- **`/test-tap`** — Core Audio Process Tap capture test (`hark-capture` CLI).
- **`/smoke-harkd`** — live end-to-end WebSocket smoke test of the daemon.

Both build on [`engine/scripts/sign-dev-bundle.sh`](../engine/scripts/sign-dev-bundle.sh),
which wraps an SPM-built binary in a minimal **signed** `.app` so Process Taps can
acquire `kTCCServiceAudioCapture` (an unsigned binary gets no prompt and silently
fails — [ADR-0011](decisions/0011-process-tap-system-audio-gotchas.md)):

```bash
cd engine
swift build -c release
# Wrap + sign harkd (or hark-capture) with your identity, then launch via `open`:
./scripts/sign-dev-bundle.sh "Apple Development: you@example.com (TEAMID)" harkd
```

Find your identity string with `security find-identity -v -p codesigning`.

---

## 5. Packaging the `.app`

Both packaging scripts run `swift build -c release` (engine) **first**, so the
bundled `harkd` is never stale, then build the renderer + main, then
electron-builder. Config: [`ui/electron-builder.yml`](../ui/electron-builder.yml).

```bash
cd ui
npm run pack    # unpacked .app under release/  (electron-builder --dir) — fast, for smoke-testing the bundle
npm run dist    # .dmg + .zip under release/      (electron-builder --mac) — the real signed artifact
```

Output lands in `ui/release/` (gitignored). The build is **arm64-only** by
design — Apple Silicon is the only supported target. Shipping a universal
Electron host with an arm64-only `harkd` would crash on Intel
([ADR-0021](decisions/0021-macos-app-packaging.md)).

What's in the bundle: the compiled renderer + main, and the single self-contained
`harkd` Mach-O at `Contents/Resources/engine/harkd` (WhisperKit / FluidAudio /
NIO are all statically linked — no dylibs to co-locate).

---

## 6. Signing & notarization

Hark has a **two-tier** signing chain
([ADR-0021](decisions/0021-macos-app-packaging.md) +
[ADR-0038](decisions/0038-notarization-signing-chain.md)):

| Tier | Certificate | Can run on this Mac | Can run on *other* Macs |
|---|---|:---:|:---:|
| **Dev / dogfood** | free **Apple Development** | ✅ | ❌ (not notarized) |
| **Release** | paid **Developer ID Application** | ✅ | ✅ (notarized + stapled) |

### How the signing works

- **Hardened runtime** is on (required for notarization, and the stable-identity
  base the TCC grant needs).
- Entitlements are split: the app gets [`build/entitlements.mac.plist`](../ui/build/entitlements.mac.plist)
  (`allow-jit`, `allow-unsigned-executable-memory` — Electron's needs);
  every nested Mach-O gets [`build/entitlements.mac.inherit.plist`](../ui/build/entitlements.mac.inherit.plist)
  (`com.apple.security.inherit` + `allow-jit` + `device.audio-input`).
- **`harkd` is signed explicitly** via `mac.binaries` in the config. This is
  load-bearing: a file under `Contents/Resources/` is *not* in electron-builder's
  default deep-sign rule, so without this it would be sealed as an opaque resource
  hash and carry no `cs.inherit` — which both **breaks TCC attribution** (the
  audio grant would attribute to "harkd", not "Hark", and not persist) and
  **fails notarization** (an ad-hoc nested Mach-O is rejected). See
  [ADR-0038](decisions/0038-notarization-signing-chain.md) for the full why.

### Dev build (free cert) — signs, does not notarize

```bash
cd ui
# electron-builder auto-discovers a single signing identity, or pin it:
export CSC_NAME="Apple Development: you@example.com (TEAMID)"
npm run dist
```

With no `APPLE_*` env vars set, the `afterSign` notarize hook
([`build/notarize.js`](../ui/build/notarize.js)) **no-ops** — a dev build never
contacts Apple. The result is a signed-but-not-notarized `.app` (fine for this
Mac; Gatekeeper will warn on others).

### Release build (Developer ID) — signs + notarizes + staples

Needs a paid Apple Developer Program membership and a **Developer ID
Application** certificate, plus one of two notarization auth methods:

```bash
cd ui
export CSC_NAME="Developer ID Application: Your Name (TEAMID)"

# Method A — Apple ID + app-specific password (simplest):
export APPLE_ID="you@example.com"
export APPLE_APP_SPECIFIC_PASSWORD="abcd-efgh-ijkl-mnop"   # NOT your Apple password
export APPLE_TEAM_ID="ABCDE12345"

# …or Method B — App Store Connect API key (better for CI; takes precedence):
# export APPLE_API_KEY="/path/to/AuthKey_XXXX.p8"
# export APPLE_API_KEY_ID="ABCD1234EF"
# export APPLE_API_ISSUER="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

npm run dist
```

The `afterSign` hook submits the `.app` to Apple's notary via `notarytool --wait`
and **staples** the ticket into the `.app`. The **`.dmg` must be stapled
manually** afterward (the hook only sees the `.app`, before the dmg exists):

```bash
xcrun stapler staple "release/Hark-<version>.dmg"
```

### Verify a signed/notarized build

```bash
cd ui/release/mac-arm64        # adjust to the actual output path
APP="Hark.app"

# harkd must carry the inherit entitlements + the hardened-runtime (runtime) flag:
codesign -dvvv --entitlements - "$APP/Contents/Resources/engine/harkd"

# Whole-bundle signature + Gatekeeper assessment (post-notarize):
codesign --verify --deep --strict --verbose=2 "$APP"
spctl -a -vvv "$APP"
xcrun stapler validate "$APP"
```

After launching a release build, the system-audio TCC prompt must say **"Hark"**
(not "harkd").

---

## 7. Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| Capture prompt never appears / `granted=false` | The binary isn't signed with a stable identity. In dev use `sign-dev-bundle.sh`; in the app the `mac.binaries` signing handles it. |
| TCC entry says **"harkd"**, not "Hark", or the grant doesn't persist | `harkd` wasn't signed with `cs.inherit` — confirm `mac.binaries` is in the config and re-run `npm run dist`; verify with `codesign -dvvv` (§6). |
| `npm run dist` "skips notarization" | Expected without a full `APPLE_*` credential set — that's the env gate. A free Apple Development cert **cannot** notarize regardless. |
| Packaged app launches unstyled | Critical-CSS inlining must stay off (the strict CSP blocks its inline `onload`) — see [ADR-0021](decisions/0021-macos-app-packaging.md). |
| Connection badge stuck on `connecting…` | First-run ANE compile (~90 s). Watch the `[el]` logs for `harkd ready`. |

> **Status note:** the signing chain is implemented but full end-to-end
> notarization is **blocked on paid Developer Program enrollment**; ADR-0038
> still lists on-device re-verification of the `mac.binaries` fix as an open
> item. Treat the release path as "wired, not yet fully verified."

---

## 8. Claude Code design skills (taste-skill)

The UI design work uses third-party **taste-skill** design skills (installed via
the Vercel `skills` CLI). The `SKILL.md` folders are **gitignored**, but
[`skills-lock.json`](../skills-lock.json) (the manifest) is committed — so a fresh
checkout restores them with one command:

```bash
npx skills experimental_install     # restores all skills from skills-lock.json
```

If the CLI verb has changed (it's young — `skills install` / `skills i` are
landing too), fall back to the explicit re-add:

```bash
npx -y skills add leonxlnx/taste-skill --skill design-taste-frontend     --agent claude-code
npx -y skills add leonxlnx/taste-skill --skill redesign-existing-projects --agent claude-code
npx -y skills add leonxlnx/taste-skill --skill high-end-visual-design     --agent claude-code
```

See [CLAUDE.md](../CLAUDE.md) for the project's design/operating conventions.

---

## See also

- [README.md](../README.md) — what Hark is, privacy model, project layout
- [ui/README.md](../ui/README.md) — front-end internals, dev-loop details
- [engine/README.md](../engine/README.md) — engine internals
- [STATUS.md](../STATUS.md) — current-state snapshot
- ADRs: [0011 (Process Tap TCC)](decisions/0011-process-tap-system-audio-gotchas.md) ·
  [0021 (packaging)](decisions/0021-macos-app-packaging.md) ·
  [0038 (signing chain)](decisions/0038-notarization-signing-chain.md)
