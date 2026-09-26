#!/usr/bin/env bash
# Builds build/Skryba.app from the Swift package.
#   scripts/build.sh            build only
#   scripts/build.sh --install  build, copy to /Applications and launch
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Skryba"
APP="build/$APP_NAME.app"

# Use full Xcode's toolchain even if xcode-select still points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns Resources/MenuBarIcon.png Resources/MenuBarIcon@2x.png "$APP/Contents/Resources/"

# macOS ties Microphone, Accessibility and keychain access to the code signature.
# A stable identity keeps those grants across rebuilds; ad-hoc signing ("-") changes on every build.
IDENTITY="${SKRYBA_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}"
if [[ -z "$IDENTITY" ]]; then
  echo "warning: no 'Apple Development' signing identity found — signing ad-hoc." >&2
  echo "         Permissions will reset after every rebuild. See README → Signing." >&2
  if security find-identity -p codesigning | grep -q "Apple Development"; then
    echo "         An Apple Development certificate exists but isn't valid — usually the Apple WWDR G3" >&2
    echo "         intermediate is missing: https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer" >&2
  fi
  IDENTITY="-"
fi
codesign --force --sign "$IDENTITY" "$APP"
echo "Built $APP (signed with: $IDENTITY)"

if [[ "${1:-}" == "--install" ]]; then
  DEST="/Applications/$APP_NAME.app"
  STAGE="/Applications/.$APP_NAME.app.new"
  # Copy first: if this fails, the existing install is untouched.
  rm -rf "$STAGE"
  cp -R "$APP" "$STAGE"
  codesign --verify --strict "$STAGE"

  pkill -x "$APP_NAME" || true
  for _ in $(seq 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
  if pgrep -x "$APP_NAME" >/dev/null; then
    rm -rf "$STAGE"
    echo "error: $APP_NAME is still running; quit it and try again." >&2
    exit 1
  fi
  sleep 0.5 # let LaunchServices notice the old instance is gone

  rm -rf "$DEST"
  mv "$STAGE" "$DEST"
  open "$DEST"
  echo "Installed and launched $DEST"
fi
