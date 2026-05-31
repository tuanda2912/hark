#!/usr/bin/env bash
#
# sign-dev-bundle.sh — wrap an engine binary in a signed .app bundle so Core
# Audio Process Taps can acquire the kTCCServiceAudioCapture permission.
#
# Process Taps need a STABLE code-signing identity for TCC to attribute and
# remember the grant. An unsigned/ad-hoc binary has none, so the permission
# request silently fails (granted=false, no prompt). A real signing identity —
# even a FREE "Apple Development" certificate from a personal Apple ID — fixes
# that. This wraps the SPM-built binary in a minimal .app (with the required
# NSAudioCaptureUsageDescription) and signs it with that identity. See ADR-0011.
#
# Usage:
#   ./scripts/sign-dev-bundle.sh "Apple Development: you@example.com (TEAMID)" [binary]
#
#   [binary] defaults to hark-capture. Pass "harkd" to wrap the streaming
#   daemon instead, for testing the LIVE transcription path with the tap
#   backend (HARK_CAPTURE_BACKEND=tap).
#
# Find your identity string with:
#   security find-identity -v -p codesigning
#
set -euo pipefail

IDENTITY="${1:?Usage: sign-dev-bundle.sh \"Apple Development: you@example.com (TEAMID)\" [binary]}"
BINNAME="${2:-hark-capture}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ENGINE_DIR/.build/release/$BINNAME"

# Each binary gets its OWN bundle id so its kTCCServiceAudioCapture grant is
# tracked independently (you grant hark-capture and harkd once each in dev).
case "$BINNAME" in
  hark-capture) APPNAME="HarkCapture"; BUNDLEID="com.hark.capture.dev";;
  harkd)        APPNAME="Harkd";       BUNDLEID="com.hark.daemon.dev";;
  *)            APPNAME="$BINNAME";    BUNDLEID="com.hark.$BINNAME.dev";;
esac
APP="$ENGINE_DIR/.build/$APPNAME.app"

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found. Build first:  swift build -c release" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/$BINNAME"

# Unquoted heredoc: the bundle id / name / exec are interpolated per-binary.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$BUNDLEID</string>
    <key>CFBundleName</key><string>$APPNAME</string>
    <key>CFBundleExecutable</key><string>$BINNAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>LSMinimumSystemVersion</key><string>14.4</string>
    <key>NSMicrophoneUsageDescription</key><string>Hark transcribes meeting audio locally.</string>
    <key>NSAudioCaptureUsageDescription</key><string>Hark captures system audio to transcribe meetings locally.</string>
</dict>
</plist>
PLIST

# Sign the inner executable first, then the bundle. No hardened runtime and no
# restricted entitlements: this is a local dev test, and a free Personal-Team
# cert can't carry profile-gated entitlements anyway. A plain signed identity
# is all TCC needs to attribute the grant.
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/$BINNAME"
codesign --force --sign "$IDENTITY" "$APP"

echo "── signature ─────────────────────────────────────────────"
codesign -dvv "$APP" 2>&1 | sed 's/^/  /'
echo "──────────────────────────────────────────────────────────"
echo
echo "Signed bundle ready: $APP"
echo
echo "Launch via 'open' — LaunchServices attribution is what makes the TCC grant stick:"
if [ "$BINNAME" = "harkd" ]; then
  echo "  open --env HARK_CAPTURE_BACKEND=tap --env HARK_ENABLE_TCC_SPI=1 \\"
  echo "    \"$APP\""
  echo "  # harkd writes its port to ~/Library/Application Support/Hark/engine.port;"
  echo "  # connect a WebSocket client (e.g. websocat) and send capture.start."
else
  echo "  open -W --env HARK_CAPTURE_BACKEND=tap --env HARK_ENABLE_TCC_SPI=1 --env HARK_TAP_DEBUG=1 \\"
  echo "    \"$APP\" --args --system-only --duration 12 -o /tmp/tap.wav"
fi
