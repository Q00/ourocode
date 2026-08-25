#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
LAUNCHER="$APP_ROOT/run-canonical-app.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-canonical-launch.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
APP="$TEST_ROOT/Ourocode-Current-Source.app"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp /usr/bin/true "$APP/Contents/MacOS/Ourocode"
cp /usr/bin/true "$APP/Contents/Helpers/fixture-helper"
cp "$APP_ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string works.ourocode.desktop.launch-fixture \
  "$APP/Contents/Info.plist"

SOURCE_DIGEST=$($MANIFEST_TOOL source-digest)
$MANIFEST_TOOL write --app "$APP" --profile development --engine fixture \
  --provider-scope isolated-fixture --expected-source-digest "$SOURCE_DIGEST"

OUROCODE_CANONICAL_APP="$APP" OUROCODE_CANONICAL_PROFILE=development \
  "$LAUNCHER" --verify

cp /usr/bin/false "$APP/Contents/MacOS/Ourocode"
set +e
TAMPER_OUTPUT=$(OUROCODE_CANONICAL_APP="$APP" OUROCODE_CANONICAL_PROFILE=development \
  "$LAUNCHER" --verify 2>&1)
TAMPER_STATUS=$?
set -e
if [[ $TAMPER_STATUS -ne 65 ]] \
    || ! print -r -- "$TAMPER_OUTPUT" | rg -Fq \
      'Ourocode executable does not match its build manifest'; then
  print -u2 "FAIL: launcher accepted an executable that did not match the manifest"
  print -u2 -- "$TAMPER_OUTPUT"
  exit 1
fi

rg -Fq 'exec open "${OPEN_FLAGS[@]}" "$CANONICAL_APP"' "$LAUNCHER" || {
  print -u2 "FAIL: canonical launcher stopped using the exact verified app path"
  exit 1
}
rg -Fq '(( NEW_INSTANCE == 1 )) && OPEN_FLAGS=(-n)' "$LAUNCHER" || {
  print -u2 "FAIL: a second canonical process is no longer explicit opt-in"
  exit 1
}

print "PASS: canonical launcher accepts a current source-bound development app"
print "PASS: executable tampering fails before LaunchServices is invoked"
print "PASS: canonical launch reuses an instance unless --new-instance is explicit"
