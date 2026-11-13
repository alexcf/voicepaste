#!/bin/zsh
# Builds VoicePaste.app (universal: Apple Silicon + Intel, macOS 13+).
#
#   ./build.sh           build and install to ~/Applications
#   ./build.sh --dist    build an ad-hoc-signed zip in dist/ for sharing
#
# Optional: run ./make-cert.sh once so rebuilds keep the same signature and
# macOS doesn't ask for Microphone/Accessibility permission again each time.
set -euo pipefail
cd "${0:A:h}"

BUNDLE_ID="${VOICEPASTE_BUNDLE_ID:-app.voicepaste.VoicePaste}"
VERSION="1.0"
APP=build/VoicePaste.app
DIST=0; [[ "${1:-}" == "--dist" ]] && DIST=1

rm -rf build
mkdir -p "$APP/Contents/MacOS" build/obj

for ARCH in arm64 x86_64; do
  swiftc -O -target "$ARCH-apple-macos13.0" main.swift Settings.swift -o "build/obj/VoicePaste-$ARCH" \
    -framework AppKit -framework AVFoundation -framework Carbon -framework ApplicationServices \
    -framework Speech -framework SwiftUI
done
lipo -create build/obj/VoicePaste-arm64 build/obj/VoicePaste-x86_64 -output "$APP/Contents/MacOS/VoicePaste"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>VoicePaste</string>
  <key>CFBundleExecutable</key><string>VoicePaste</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>VoicePaste records your voice to transcribe it.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>VoicePaste can use macOS built-in speech recognition to transcribe your voice.</string>
</dict>
</plist>
PLIST

if (( DIST )); then
  # Ad-hoc signature for distribution (no local certificate baked in).
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
  mkdir -p dist
  rm -f "dist/VoicePaste-$VERSION.zip"
  ditto -c -k --keepParent "$APP" "dist/VoicePaste-$VERSION.zip"
  echo "Built dist/VoicePaste-$VERSION.zip"
  exit 0
fi

# Stable local identity if present (see make-cert.sh), else ad-hoc.
IDENT=$(security find-identity -p codesigning | awk '/"VoicePaste Local Signing"/{print $2; exit}')
codesign --force --sign "${IDENT:--}" --identifier "$BUNDLE_ID" "$APP"

mkdir -p ~/Applications
pkill -x VoicePaste 2>/dev/null && sleep 0.5 || true
rm -rf ~/Applications/VoicePaste.app
cp -R "$APP" ~/Applications/
echo "Installed ~/Applications/VoicePaste.app"
