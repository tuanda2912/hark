// Hark — electron-builder afterSign hook: notarize the signed .app.
//
// DRAFT / GATED. This file is intentionally a NO-OP unless ALL of the
// following are set in the environment, so that `npm run pack` and local
// `npm run dist` builds (using a free "Apple Development" cert or ad-hoc)
// NEVER contact Apple:
//
//   APPLE_ID                     your Apple ID email
//   APPLE_APP_SPECIFIC_PASSWORD  app-specific password (NOT your Apple pw)
//   APPLE_TEAM_ID                10-char Developer Program Team ID
//
// Notarization REQUIRES a paid Apple Developer Program membership and a
// "Developer ID Application" certificate. The free "Apple Development" cert
// CANNOT notarize. See PLAN §E for exactly where the paid gate is.
//
// Privacy note (CLAUDE.md): the ONLY network call this hook makes is to
// Apple's notary service, and only when the env vars above are present
// (i.e. an explicit release build). No telemetry, no other endpoints.
//
// Requires: npm i -D @electron/notarize

const { notarize } = require('@electron/notarize');

exports.default = async function notarizing(context) {
  const { electronPlatformName, appOutDir } = context;

  if (electronPlatformName !== 'darwin') {
    return;
  }

  const { APPLE_ID, APPLE_APP_SPECIFIC_PASSWORD, APPLE_TEAM_ID } = process.env;

  // Gate: skip silently (with a clear log) unless fully configured for a
  // Developer ID release. This is what lets dev builds run without Apple.
  if (!APPLE_ID || !APPLE_APP_SPECIFIC_PASSWORD || !APPLE_TEAM_ID) {
    // eslint-disable-next-line no-console
    console.log(
      '[hark][notarize] APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID ' +
        'not all set — skipping notarization (dev/unsigned build). ' +
        'This is expected unless you are cutting a Developer ID release.',
    );
    return;
  }

  const appName = context.packager.appInfo.productFilename; // "Hark"
  const appPath = `${appOutDir}/${appName}.app`;

  // eslint-disable-next-line no-console
  console.log(`[hark][notarize] submitting ${appPath} to Apple notary…`);

  await notarize({
    tool: 'notarytool',
    appPath,
    appleId: APPLE_ID,
    appleIdPassword: APPLE_APP_SPECIFIC_PASSWORD,
    teamId: APPLE_TEAM_ID,
  });

  // electron-builder staples automatically after a successful afterSign
  // notarize when using notarytool; if not, run `xcrun stapler staple`
  // on the .app (and the .dmg) as a follow-up step — see PLAN §E.
  // eslint-disable-next-line no-console
  console.log('[hark][notarize] notarization complete.');
};
