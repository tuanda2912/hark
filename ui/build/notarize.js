// Hark — electron-builder afterSign hook: notarize + STAPLE the signed .app.
//
// DRAFT / GATED. This file is intentionally a NO-OP unless the environment is
// fully configured for a Developer ID release, so that `npm run pack` and a
// local `npm run dist` (using a free "Apple Development" cert or ad-hoc) NEVER
// contact Apple. Two auth methods are supported; the hook no-ops unless ONE is
// fully present:
//
//   Method A — Apple ID + app-specific password (simplest to set up):
//     APPLE_ID                     your Apple ID email
//     APPLE_APP_SPECIFIC_PASSWORD  app-specific password (NOT your Apple pw)
//     APPLE_TEAM_ID                10-char Developer Program Team ID
//
//   Method B — App Store Connect API key (better for CI; no password):
//     APPLE_API_KEY                path to the .p8 key file
//     APPLE_API_KEY_ID             the key ID (e.g. "ABCD1234EF")
//     APPLE_API_ISSUER             the issuer UUID
//
// Notarization REQUIRES a paid Apple Developer Program membership and a
// "Developer ID Application" certificate. The free "Apple Development" cert
// CANNOT notarize. See PLAN §E / docs/decisions/0038 for the signing chain.
//
// Privacy note (CLAUDE.md rule #3): the ONLY network call this hook makes is to
// Apple's notary service, and only when the env vars above are present (i.e. an
// explicit release build). No telemetry, no other endpoints.
//
// Requires: npm i -D @electron/notarize  (already in devDependencies)

const { notarize } = require('@electron/notarize');
const { execFileSync } = require('node:child_process');

function authFromEnv() {
  const {
    APPLE_ID,
    APPLE_APP_SPECIFIC_PASSWORD,
    APPLE_TEAM_ID,
    APPLE_API_KEY,
    APPLE_API_KEY_ID,
    APPLE_API_ISSUER,
  } = process.env;

  // Method B (API key) takes precedence if fully specified.
  if (APPLE_API_KEY && APPLE_API_KEY_ID && APPLE_API_ISSUER) {
    return {
      method: 'api-key',
      opts: {
        appleApiKey: APPLE_API_KEY,
        appleApiKeyId: APPLE_API_KEY_ID,
        appleApiIssuer: APPLE_API_ISSUER,
      },
    };
  }

  // Method A (Apple ID + app-specific password).
  if (APPLE_ID && APPLE_APP_SPECIFIC_PASSWORD && APPLE_TEAM_ID) {
    return {
      method: 'apple-id',
      opts: {
        appleId: APPLE_ID,
        appleIdPassword: APPLE_APP_SPECIFIC_PASSWORD,
        teamId: APPLE_TEAM_ID,
      },
    };
  }

  return null;
}

exports.default = async function notarizing(context) {
  const { electronPlatformName, appOutDir } = context;

  if (electronPlatformName !== 'darwin') {
    return;
  }

  const auth = authFromEnv();

  // Gate: skip silently (with a clear log) unless fully configured for a
  // Developer ID release. This is what lets dev builds run without Apple.
  if (!auth) {
    // eslint-disable-next-line no-console
    console.log(
      '[hark][notarize] No complete Apple credential set found ' +
        '(need either APPLE_ID + APPLE_APP_SPECIFIC_PASSWORD + APPLE_TEAM_ID, ' +
        'or APPLE_API_KEY + APPLE_API_KEY_ID + APPLE_API_ISSUER) — skipping ' +
        'notarization. This is EXPECTED for a dev build; only a Developer ID ' +
        'release sets these.',
    );
    return;
  }

  const appName = context.packager.appInfo.productFilename; // "Hark"
  const appPath = `${appOutDir}/${appName}.app`;

  // eslint-disable-next-line no-console
  console.log(
    `[hark][notarize] submitting ${appPath} to Apple notary ` +
      `(auth: ${auth.method}, notarytool, --wait)…`,
  );

  // @electron/notarize with tool 'notarytool' runs `xcrun notarytool submit
  // --wait`. It SUBMITS and waits for acceptance — it does NOT staple.
  await notarize({
    tool: 'notarytool',
    appPath,
    ...auth.opts,
  });

  // eslint-disable-next-line no-console
  console.log('[hark][notarize] notary accepted — stapling the ticket…');

  // CRITICAL: staple the notarization ticket INTO the .app so Gatekeeper can
  // verify OFFLINE (first-launch on a machine with no network). @electron/
  // notarize does not staple; electron-builder only auto-staples when IT drives
  // notarization via `mac.notarize`, which we are NOT using (this afterSign hook
  // drives it instead). So we staple explicitly. The .dmg is stapled separately
  // AFTER electron-builder produces it — afterSign runs on the .app, before the
  // dmg exists, so the dmg staple is a manual post-build step (see runbook /
  // ADR-0038). Stapling the .app means the copy INSIDE the dmg is already
  // stapled, which is the load-bearing one.
  execFileSync('xcrun', ['stapler', 'staple', appPath], { stdio: 'inherit' });

  // Sanity-validate the staple so a broken ticket fails the BUILD, not the user.
  execFileSync('xcrun', ['stapler', 'validate', appPath], { stdio: 'inherit' });

  // eslint-disable-next-line no-console
  console.log('[hark][notarize] notarization + stapling complete.');
};
