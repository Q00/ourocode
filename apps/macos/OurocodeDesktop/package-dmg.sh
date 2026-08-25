#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BUILD_MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
DEFAULT_APP_BUNDLE="$APP_ROOT/.build/Ourocode.app"
SOURCE_APP_BUNDLE="${OUROCODE_APP_BUNDLE:-$DEFAULT_APP_BUNDLE}"
DIST_DIR="$APP_ROOT/dist"
RELEASE_BUILD_VALUE="${RELEASE_BUILD:-0}"
if [[ "$RELEASE_BUILD_VALUE" != "0" && "$RELEASE_BUILD_VALUE" != "1" ]]; then
  echo "RELEASE_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$RELEASE_BUILD_VALUE" == "1" ]]; then
  if [[ -n "${OUROCODE_APP_BUNDLE:-}" ]]; then
    echo "RELEASE_BUILD=1 must use the packaged release build; OUROCODE_APP_BUNDLE is development-only" >&2
    exit 64
  fi
  EXPECTED_BUILD_PROFILE="release"
else
  EXPECTED_BUILD_PROFILE="development"
fi

if [[ "$SOURCE_APP_BUNDLE" != /* ]]; then
  echo "OUROCODE_APP_BUNDLE must be an absolute app bundle path" >&2
  exit 64
fi
if [[ -n "${OUROCODE_APP_BUNDLE:-}" && ! -d "$SOURCE_APP_BUNDLE/Contents/MacOS" ]]; then
  echo "OUROCODE_APP_BUNDLE is not a built macOS app bundle: $SOURCE_APP_BUNDLE" >&2
  exit 66
fi
DEVICE=""

if [[ "$RELEASE_BUILD_VALUE" == "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" || "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "RELEASE_BUILD=1 requires a Developer ID CODESIGN_IDENTITY" >&2
    exit 64
  fi
  if [[ "$CODESIGN_IDENTITY" != "Developer ID Application:"* ]]; then
    echo "RELEASE_BUILD=1 requires a Developer ID Application identity, not: $CODESIGN_IDENTITY" >&2
    exit 64
  fi
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "RELEASE_BUILD=1 requires a NOTARY_PROFILE" >&2
    exit 64
  fi
fi

if [[ -z "${OUROCODE_APP_BUNDLE:-}" ]]; then
  "$APP_ROOT/build-app.sh" >/dev/null
fi
"$BUILD_MANIFEST_TOOL" verify --app "$SOURCE_APP_BUNDLE" \
  --expected-profile "$EXPECTED_BUILD_PROFILE" --require-current-source
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$SOURCE_APP_BUNDLE/Contents/Info.plist")
if [[ ! "$VERSION" =~ '^[0-9A-Za-z][0-9A-Za-z.-]*$' ]]; then
  echo "Payload app contains an invalid CFBundleShortVersionString: $VERSION" >&2
  exit 65
fi
if [[ "$RELEASE_BUILD_VALUE" == "1" ]]; then
  ARTIFACT_NAME="Ourocode-$VERSION"
  VOLUME_NAME="Ourocode $VERSION"
else
  ARTIFACT_NAME="Ourocode-$VERSION-dev"
  VOLUME_NAME="Ourocode $VERSION Dev"
fi
# HFS+ volume names are limited to 27 Unicode characters. The artifact name
# remains complete and authoritative if a prerelease suffix exceeds that.
VOLUME_NAME="${VOLUME_NAME[1,27]}"
OUTPUT_DMG="$DIST_DIR/$ARTIFACT_NAME.dmg"
TEMP_OUTPUT_DMG="$DIST_DIR/.$ARTIFACT_NAME.$$.dmg"

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-dmg.XXXXXX")
STAGING="$WORK_DIR/staging"
RW_DMG="$WORK_DIR/Ourocode-rw.dmg"
MOUNT_POINT="$WORK_DIR/mount"
VERIFY_MOUNT_POINT="$WORK_DIR/verify-mount"

cleanup() {
  if [[ -n "$DEVICE" ]]; then
    hdiutil detach "$DEVICE" -quiet || true
  fi
  rm -f "$TEMP_OUTPUT_DMG"
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# A previous QA remount of either Ourocode artifact can otherwise make Finder
# bind the staging window to the wrong same-named volume. Detach only devices
# whose image paths exactly match this project's development or release DMG.
RELEASE_DMG="$DIST_DIR/Ourocode-$VERSION.dmg"
DEVELOPMENT_DMG="$DIST_DIR/Ourocode-$VERSION-dev.dmg"
EXISTING_DEVICES=$(hdiutil info | awk -v release="$RELEASE_DMG" -v development="$DEVELOPMENT_DMG" '
  /^=+/ { matched = 0 }
  /^image-path[[:space:]]*:/ {
    value = $0
    sub(/^[^:]*:[[:space:]]*/, "", value)
    matched = (value == release || value == development)
  }
  matched && /^\/dev\/disk[0-9]+[[:space:]]/ { print $1 }
')
for existing_device in ${(f)EXISTING_DEVICES}; do
  hdiutil detach "$existing_device" -quiet
done

mkdir -p "$STAGING/.background" "$DIST_DIR" "$MOUNT_POINT" "$VERIFY_MOUNT_POINT"
cp -R "$SOURCE_APP_BUNDLE" "$STAGING/Ourocode.app"
ln -s /Applications "$STAGING/Applications"
swift "$APP_ROOT/InstallerBackground.swift" "$STAGING/.background/background.png"

hdiutil create -quiet -fs HFS+ -volname "$VOLUME_NAME" -srcfolder "$STAGING" -format UDRW "$RW_DMG"
ATTACH_OUTPUT=$(hdiutil attach -readwrite -noverify -noautoopen -mountpoint "$MOUNT_POINT" "$RW_DMG")
DEVICE=$(printf '%s\n' "$ATTACH_OUTPUT" | awk '/\/dev\/disk/ { device=$1 } END { print device }')
osascript <<APPLESCRIPT
set mountedFolder to POSIX file "$MOUNT_POINT" as alias
tell application "Finder"
  open mountedFolder
  repeat with attempt from 1 to 50
    if exists container window of mountedFolder then exit repeat
    delay 0.2
  end repeat
  if not (exists container window of mountedFolder) then error "Finder did not open the mounted installer within 10 seconds"
  set installerWindow to container window of mountedFolder
  set current view of installerWindow to icon view
  set toolbar visible of installerWindow to false
  set statusbar visible of installerWindow to false
  set bounds of installerWindow to {120, 120, 780, 540}
  set theViewOptions to icon view options of installerWindow
  set arrangement of theViewOptions to not arranged
  set icon size of theViewOptions to 96
  set text size of theViewOptions to 13
  set label position of theViewOptions to bottom
  set shows item info of theViewOptions to false
  set shows icon preview of theViewOptions to false
  set background picture of theViewOptions to file ".background:background.png" of mountedFolder
  set position of item "Ourocode.app" of mountedFolder to {205, 215}
  set position of item "Applications" of mountedFolder to {455, 215}
  update mountedFolder without registering applications
  delay 3
  close installerWindow
  delay 2
  eject mountedFolder
end tell
APPLESCRIPT

for attempt in {1..50}; do
  if ! hdiutil info | grep -q "^$DEVICE"; then
    DEVICE=""
    break
  fi
  sleep 0.2
done
if [[ -n "$DEVICE" ]]; then
  hdiutil detach "$DEVICE" -quiet
  DEVICE=""
fi
hdiutil convert -quiet "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$TEMP_OUTPUT_DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  xcrun notarytool submit "$TEMP_OUTPUT_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$TEMP_OUTPUT_DMG"
  xcrun stapler validate "$TEMP_OUTPUT_DMG"
fi

hdiutil verify "$TEMP_OUTPUT_DMG" >/dev/null
VERIFY_ATTACH_OUTPUT=$(hdiutil attach -readonly -noverify -noautoopen -mountpoint "$VERIFY_MOUNT_POINT" "$TEMP_OUTPUT_DMG")
DEVICE=$(printf '%s\n' "$VERIFY_ATTACH_OUTPUT" | awk '/\/dev\/disk/ { device=$1 } END { print device }')
codesign --verify --deep --strict --verbose=2 "$VERIFY_MOUNT_POINT/Ourocode.app"
"$BUILD_MANIFEST_TOOL" verify --app "$VERIFY_MOUNT_POINT/Ourocode.app" \
  --expected-profile "$EXPECTED_BUILD_PROFILE" --require-current-source
if [[ "${CODESIGN_IDENTITY:--}" != "-" ]]; then
  spctl --assess --type execute --verbose=2 "$VERIFY_MOUNT_POINT/Ourocode.app"
fi
hdiutil detach "$DEVICE" -quiet
DEVICE=""
mv -f "$TEMP_OUTPUT_DMG" "$OUTPUT_DMG"
echo "$OUTPUT_DMG"
