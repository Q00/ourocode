#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
PACKAGE_SCRIPT="$APP_ROOT/package-dmg.sh"
BACKGROUND_SOURCE="$APP_ROOT/InstallerBackground.swift"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-installer-presentation.XXXXXX")
trap 'rm -rf "$TEST_DIR"' EXIT
BACKGROUND="$TEST_DIR/background.png"

swift "$BACKGROUND_SOURCE" "$BACKGROUND"

PIXELS_WIDE=$(sips -g pixelWidth "$BACKGROUND" | awk '/pixelWidth:/ { print $2 }')
PIXELS_HIGH=$(sips -g pixelHeight "$BACKGROUND" | awk '/pixelHeight:/ { print $2 }')
[[ "$PIXELS_WIDE" == "1320" && "$PIXELS_HIGH" == "840" ]] || {
  print -u2 "FAIL: installer background is not the 2x 660x420 Retina canvas"
  exit 1
}

for contract in \
  'set bounds of installerWindow to {120, 120, 780, 540}' \
  'set icon size of theViewOptions to 96' \
  'set text size of theViewOptions to 13' \
  'set label position of theViewOptions to bottom' \
  'set position of item "Ourocode.app" of mountedFolder to {205, 215}' \
  'set position of item "Applications" of mountedFolder to {455, 215}'
do
  grep -Fq "$contract" "$PACKAGE_SCRIPT" || {
    print -u2 "FAIL: installer Finder presentation drifted: $contract"
    exit 1
  }
done

grep -Fq 'ln -s /Applications "$STAGING/Applications"' "$PACKAGE_SCRIPT" || {
  print -u2 "FAIL: installer lost the native Applications destination"
  exit 1
}

print "PASS: installer remains a readable Retina drag-to-Applications Finder surface"
