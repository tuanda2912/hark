# ADR-0038: Notarization signing chain + explicit harkd sidecar signing

- **Date:** 2026-06-04
- **Status:** Accepted (amends [ADR-0021](0021-macos-app-packaging.md))
- **Deciders:** Dang Anh Tuan

## Context

[ADR-0021](0021-macos-app-packaging.md) chose electron-builder, shipped `harkd`
via `extraResources` to `Contents/Resources/engine/harkd`, set hardened runtime,
and split entitlements (app vs. `entitlementsInherit`) so the audio-capture TCC
grant attributes to **Hark**, not to a standalone `harkd` identity (ADR-0011 #18).
It deferred notarization to BACKLOG ("Packaging ADR (TBD) will record the signing
chain"). This ADR is that record, and it closes a **signing gap** found during the
Phase 7 packaging-hardening review.

The gap: a packaging-mechanics audit of an existing dev bundle
(`ui/release/mac-arm64/Hark.app`, free "Apple Development" cert) showed that
`Contents/Resources/engine/harkd` was sealed in `_CodeSignature/CodeResources`
as an **opaque resource hash** (`files`/`files2` `hash2`) — NOT as a nested
code item with its own `cdhash` + designated `requirement`, the way the Electron
helpers and frameworks were. electron-builder's deep-sign pass only re-signs
Mach-Os matching its `nested` resource rule
(`^(Frameworks|...|Helpers|MacOS|Library/...)/`); a file under `Resources/` does
not match, so `entitlementsInherit` was **never applied to harkd**. harkd kept
whatever signature `swift build` produced (ad-hoc — SwiftPM does not sign) and
carried **no `com.apple.security.inherit`**. ADR-0021's "verified on-device"
note (2026-06-02) likely passed because a *manually* re-signed harkd was present
at that moment; the unattended `npm run dist` path did not reproduce it.

Two consequences follow, both serious: (1) at runtime the spawned harkd child
runs under its **own** identity, so `kTCCServiceAudioCapture` does not reliably
attribute to "Hark" or persist across launches — the exact thing ADR-0011 #18
needs; (2) an ad-hoc / non-inheriting nested Mach-O **fails notarization**.

## Decision

**1. Sign harkd explicitly via `mac.binaries`.** Add to `electron-builder.yml`:

```yaml
mac:
  binaries:
    - Contents/Resources/engine/harkd
```

app-builder-lib 25.1.8 `macPackager.getOptionsForFile()` applies the **inherit**
entitlements (the `entitlements.mac.inherit.plist`: `com.apple.security.inherit`
+ `allow-jit` + `device.audio-input`) and hardened runtime to **every signed
file except the app root** — so harkd gets exactly the inherit set, and NOT the
broad app-only `allow-unsigned-executable-memory`. The signer runs deepest-first,
so harkd is signed before the parent bundle re-seals over it. This is the unlock
that makes harkd inherit Hark's identity, so the audio grant attributes to "Hark".

**2. The signing chain (free dev cert → Developer ID release):**

- **Dev / dogfood:** free **Apple Development** cert. Signs everything for local
  execution and validates TCC attribution on-device. **Cannot notarize.**
- **Release:** paid Developer Program + **Developer ID Application** cert.
  `npm run dist` with `CSC_NAME` set to the Developer ID identity; electron-builder
  deep-signs (app → helpers/frameworks → harkd) with hardened runtime; then the
  `afterSign` hook (`build/notarize.js`) submits to Apple's notary via
  `notarytool --wait` and **staples** the ticket into the `.app`. The `.dmg` is
  stapled as a manual post-build step (the hook runs on the `.app`, before the
  dmg exists).

**3. Notarize hook stays env-gated and now staples.** `build/notarize.js` is a
NO-OP unless a full credential set is present (Apple-ID+password OR App Store
Connect API key), keeping dev builds offline. It now **staples + validates**
after a successful notarize (`@electron/notarize` only submits; it does not
staple — only electron-builder's own `mac.notarize` path auto-staples, which we
do not use). It also supports the API-key auth method the config header always
advertised.

**4. Suppress Electron's default usage strings.** electron-builder's base
Info.plist injects `NSCameraUsageDescription` and `NSBluetooth*UsageDescription`
("This app needs access to the camera/Bluetooth"). Hark uses neither; a shipped
app advertising camera access it never exercises is a privacy smell. We blank
them via `extendInfo`.

## Alternatives considered

- **Custom `afterPack` / `signDlls` hook that `codesign`s harkd manually.**
  - ✅ Total control over flags.
  - ❌ Reinvents what `mac.binaries` does correctly; easy to get the entitlements
    or deepest-first ordering wrong; one more script to maintain.
  - **Why rejected:** `mac.binaries` is the supported, minimal mechanism and
    routes harkd through the same inherit-entitlements path as the helpers.
- **Move harkd out of `Resources/` into `Contents/MacOS/` or a `Helpers/`
  subdir** so the `nested` rule signs it automatically.
  - ✅ Would get signed without `mac.binaries`.
  - ❌ Changes the prod spawn path (`harkd-spawn.ts` resolves
    `process.resourcesPath/engine/harkd`) and `extraResources` layout for no real
    benefit; `Resources/engine/` is a tidy home and matches ADR-0021.
  - **Why rejected:** churns a working layout to avoid a one-line config key.
- **Give harkd its own Developer ID identity (no inherit).**
  - ❌ TCC would attribute the audio grant to "harkd" not "Hark" — the rejected
    option from ADR-0021; breaks grant persistence.
  - **Why rejected:** `cs.inherit` is the whole point.
- **Drive notarization via electron-builder `mac.notarize: true` instead of the
  afterSign hook.**
  - ✅ Auto-staples; less custom code.
  - ❌ Harder to make a clean offline NO-OP for credential-less dev builds; the
    env-gated hook is explicit about *when* a network call to Apple happens
    (CLAUDE.md rule #3 / rule #6 posture).
  - **Why rejected:** the explicit, env-gated hook better matches the "no silent
    network" posture; we just add the staple step the hook was missing.

## Consequences

**Positive**
- harkd is signed with hardened runtime + inherit entitlements → TCC attributes
  audio capture to **Hark**, the grant can persist (ADR-0011 #18), and the bundle
  is notarizable (no ad-hoc nested Mach-O).
- Notarized builds are **stapled** → Gatekeeper passes offline on first launch.
- No misleading camera/Bluetooth permission declarations in the shipped plist.
- Two auth methods supported; hook stays a clean offline no-op without creds.

**Negative / tradeoffs accepted**
- `mac.binaries` path is brittle to the `extraResources` `to:` path — if harkd's
  in-bundle location changes, this must change in lockstep (both reference
  `Contents/Resources/engine/harkd`).
- The `.dmg` staple is a separate manual step (the afterSign hook only sees the
  `.app`). Documented in the runbook; revisit if we automate the dmg staple.
- Still **arm64-only**, still **free-cert-can't-notarize** until the $99
  enrollment + Developer ID cert land (unchanged from ADR-0021).

**What needs to remain true**
- harkd stays a single self-contained static Mach-O (no dylibs to co-sign).
  If it gains dynamic framework deps, the `mac.binaries` list and signing order
  must be revisited.
- The inherit plist keeps `com.apple.security.inherit` — drop it and TCC
  attribution breaks again.
- The notarize hook stays env-gated; it must never contact Apple on a dev build.

## Open questions

- **On-device re-verification REQUIRED.** This ADR's signing fix is verified at
  the config/CodeResources-structure level (the prior bundle's harkd had only a
  resource hash, no `cdhash`/`requirement`). It has **not** yet been re-verified
  on real hardware after a fresh `npm run dist` with the `mac.binaries` change:
  `codesign -dvvv` on the nested harkd must show the inherit entitlements +
  `runtime` flag, and a launched build's TCC prompt must say "Hark". Do this
  before claiming success.
- **Automate the `.dmg` staple** (post-build) instead of a manual step.
- **Developer ID + notarization end-to-end** — blocked on the paid enrollment
  (the only remaining external dependency, with the icon art).

## References

- Amends: [ADR-0021](0021-macos-app-packaging.md); relates to
  [ADR-0011](0011-process-tap-system-audio-gotchas.md) #18,
  [ADR-0012](0012-harkd-lazy-permissions-startup.md)
- `ui/electron-builder.yml` (`mac.binaries`, `extendInfo` suppression),
  `ui/build/notarize.js` (staple + API-key auth),
  `ui/build/entitlements.mac.plist`, `ui/build/entitlements.mac.inherit.plist`
- `ui/src/main/harkd-spawn.ts` (prod spawn path = `process.resourcesPath/engine/harkd`)
- app-builder-lib 25.1.8 `out/macPackager.js` `getOptionsForFile()` (inherit
  entitlements applied to every non-root signed file) — the mechanism this relies on
- Evidence: `ui/release/mac-arm64/Hark.app/Contents/_CodeSignature/CodeResources`
  (harkd under `files`/`files2` resource hash, absent from the nested-code list)
