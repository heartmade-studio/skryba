#!/usr/bin/env bash
# Builds build/Skryba.app from the Swift package.
#   scripts/build.sh            build for this Mac only
#   scripts/build.sh --install  build, copy to /Applications and launch
#   scripts/build.sh --dmg      universal build (Apple Silicon and Intel), packed as build/Skryba.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

MODE="${1:-}"

APP_NAME="Skryba"
APP="build/$APP_NAME.app"

# Use full Xcode's toolchain even if xcode-select still points at the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

# A release DMG runs on both architectures; a local build only needs this Mac's.
ARCHS=()
[[ "$MODE" == "--dmg" ]] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN_DIR="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

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

# Apple Development certificates can be renewed while keeping the same Team ID. Use a
# designated requirement based on that stable team and this app's signed identifier so
# TCC can recognize the replacement certificate as an update to the same app.
SIGNATURE_INFO="$(codesign -dvv "$APP" 2>&1)"
if grep -q '^Authority=Apple Development:' <<<"$SIGNATURE_INFO"; then
  TEAM_ID="$(sed -n 's/^TeamIdentifier=//p' <<<"$SIGNATURE_INFO" | head -n 1)"
  BUNDLE_ID="$(sed -n 's/^Identifier=//p' <<<"$SIGNATURE_INFO" | head -n 1)"
  if [[ -z "$TEAM_ID" || "$TEAM_ID" == "not set" || -z "$BUNDLE_ID" ]]; then
    echo "error: could not read Team ID and app identifier from the signed app." >&2
    exit 1
  fi

  # The WWDR marker on the intermediate limits this to Apple's developer certificates.
  REQUIREMENT="designated => anchor apple generic and identifier \"$BUNDLE_ID\" and certificate 1[field.1.2.840.113635.100.6.2.1] exists and certificate leaf[subject.OU] = \"$TEAM_ID\""
  codesign --force --sign "$IDENTITY" --requirements "=$REQUIREMENT" "$APP"
  codesign --verify --strict "$APP"
fi
echo "Built $APP (signed with: $IDENTITY)"

if [[ "$MODE" == "--dmg" ]]; then
  # The usual drag-to-install window: the app next to a link to /Applications.
  STAGE="$(mktemp -d)"
  trap 'rm -rf "$STAGE"' EXIT
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  rm -f "build/$APP_NAME.dmg"
  hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO "build/$APP_NAME.dmg"
  echo "Packed build/$APP_NAME.dmg ($(lipo -archs "$APP/Contents/MacOS/$APP_NAME"))"
fi

if [[ "$MODE" == "--install" ]]; then
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
