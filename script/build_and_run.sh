#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="ThirdHand"
BUNDLE_ID="studio.moonbay.ThirdHand"
MIN_SYSTEM_VERSION="14.0"
APP_VERSION="0.3.0"
APP_BUILD="3"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/Third Hand.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_ICON_SOURCE="$ROOT_DIR/Sources/ThirdHand/Resources/ThirdHand.icns"
APP_ICON_NAME="ThirdHand.icns"

if [[ "$MODE" == "--version" || "$MODE" == "version" ]]; then
  echo "$APP_VERSION ($APP_BUILD)"
  exit 0
fi

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

swift_build() {
  # SwiftPM otherwise spends minutes scanning Codex's internal Git refs while
  # resolving root-package metadata. Keep the override scoped to the build so
  # the launched app still sees the user's normal Git environment.
  env GIT_DIR=/dev/null swift build --package-path "$ROOT_DIR" "$@"
}

swift_build
BUILD_BINARY="$(swift_build --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/ThirdHand_ThirdHand.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
  cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/"
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
  for localization in "$RESOURCE_BUNDLE"/*.lproj; do
    if [[ -d "$localization" ]]; then
      cp -R "$localization" "$APP_RESOURCES/"
    fi
  done
fi

cp "$APP_ICON_SOURCE" "$APP_RESOURCES/$APP_ICON_NAME"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>Third Hand</string>
  <key>CFBundleDisplayName</key>
  <string>Third Hand</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>$APP_ICON_NAME</string>
  <key>CFBundleDevelopmentRegion</key>
  <string>ru</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ru</string>
    <string>en</string>
    <string>de</string>
    <string>fr</string>
    <string>es</string>
    <string>it</string>
    <string>pt-BR</string>
    <string>pl</string>
    <string>tr</string>
    <string>uk</string>
    <string>be</string>
    <string>kk</string>
    <string>uz</string>
    <string>ky</string>
    <string>tg</string>
    <string>tk</string>
    <string>zh-Hans</string>
    <string>ja</string>
    <string>ko</string>
  </array>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Third Hand использует микрофон только во время голосового ввода сообщения.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>Third Hand преобразует продиктованное сообщение в редактируемый текст.</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    for _ in {1..20}; do
      if pgrep -x "$APP_NAME" >/dev/null; then
        exit 0
      fi
      sleep 0.25
    done
    echo "Third Hand did not stay running" >&2
    exit 1
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--version]" >&2
    exit 2
    ;;
esac
