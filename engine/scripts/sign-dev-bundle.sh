#!/usr/bin/env bash
#
# sign-dev-bundle.sh — wrap the hark-capture CLI in a signed .app bundle so
# Core Audio Process Taps can acquire the kTCCServiceAudioCapture permission.
#
# Process Taps need a STABLE code-signing identity for TCC to attribute and
# remember the grant. An unsigned/ad-hoc binary has none, so the permission
# request silently fails (granted=false, no prompt). A real signing identity —
# even a FREE "Apple Development" certificate from a personal Apple ID — fixes
# that. This script wraps the SPM-built binary in a minimal .app (with the
# required NSAudioCaptureUsageDescription) and signs it with that identity.
#
# Usage:
#   ./scripts/sign-dev-bundle.sh "Apple Development: you@example.com (TEAMID)"
#
# Find your identity string with:
#   security find-identity -v -p codesigning
#
set -euo pipefail

IDENTITY="${1:?Usage: sign-dev-bundle.sh \"Apple Development: you@example.com (TEAMID)\"}"
ENGINE_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ENGINE_DIR/.build/release/hark-capture"
APP="$ENGINE_DIR/.build/HarkCapture.app"

if [ ! -x "$BIN" ]; then
  echo "error: $BIN not found. Build first:  swift build -c release" >&2
  exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/hark-capture"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.hark.capture.dev</string>
    <key>CFBundleName</key><string>HarkCapture</string>
    <key>CFBundleExecutable</key><string>hark-capture</string>
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
codesign --force --sign "$IDENTITY" "$APP/Contents/MacOS/hark-capture"
codesign --force --sign "$IDENTITY" "$APP"

echo "── signature ─────────────────────────────────────────────"
codesign -dvv "$APP" 2>&1 | sed 's/^/  /'
echo "──────────────────────────────────────────────────────────"
echo
echo "Signed bundle ready: $APP"
echo
echo "Run the Process Tap test (audio playing through built-in speakers):"
echo "  HARK_CAPTURE_BACKEND=tap HARK_ENABLE_TCC_SPI=1 HARK_TAP_DEBUG=1 \\"
echo "    \"$APP/Contents/MacOS/hark-capture\" --system-only --duration 12 -o /tmp/tap.wav"
