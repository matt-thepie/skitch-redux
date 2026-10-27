#!/bin/bash
# Builds "Skitch Redux.app" into ./build. Pass --install to copy it to /Applications.
# Set SIGN_IDENTITY to a Developer ID / Apple Development identity to keep the
# Screen Recording permission across rebuilds (ad-hoc signatures change every build).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/Skitch Redux.app"
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c release --show-bin-path)/SkitchRedux" "$APP/Contents/MacOS/SkitchRedux"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if [ ! -f build/AppIcon.icns ]; then
  swift scripts/make-icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# Prefer a stable local identity (see README) so macOS remembers the Screen Recording grant.
LOCAL_ID="Skitch Redux Local Signing"
if [ -z "${SIGN_IDENTITY:-}" ] && security find-certificate -c "$LOCAL_ID" >/dev/null 2>&1; then
  SIGN_IDENTITY="$LOCAL_ID"
fi
if [ -z "${SIGN_IDENTITY:-}" ]; then
  echo "warning: ad-hoc signing; Screen Recording permission will reset on every rebuild" >&2
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
  pkill -x SkitchRedux || true
  rm -rf "/Applications/Skitch Redux.app"
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Skitch Redux.app"
fi
