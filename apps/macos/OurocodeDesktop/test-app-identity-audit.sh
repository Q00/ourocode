#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
AUDIT="$APP_ROOT/audit-app-identities.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-app-identity-audit.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

make_app() {
  local app="$1"
  local bundle_id="$2"
  local channel="$3"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp /usr/bin/true "$app/Contents/MacOS/Ourocode"
  plutil -create xml1 "$app/Contents/Info.plist"
  plutil -insert CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  plutil -insert CFBundleExecutable -string Ourocode "$app/Contents/Info.plist"
  plutil -insert CFBundleShortVersionString -string 1.0.0 "$app/Contents/Info.plist"
  plutil -insert OurocodeBuildChannel -string "$channel" "$app/Contents/Info.plist"
  plutil -insert OurocodeBuildID -string fixture-build "$app/Contents/Info.plist"
}

CANONICAL="$TEST_ROOT/build/Ourocode.app"
QA_ONE="$TEST_ROOT/qa/Ourocode-QA-One.app"
QA_TWO="$TEST_ROOT/qa/Ourocode-QA-Two.app"
make_app "$CANONICAL" com.ourolabs.ourocode release
make_app "$QA_ONE" com.ourolabs.ourocode.qa.fixture-one qa
make_app "$QA_TWO" com.ourolabs.ourocode.qa.fixture-two qa

OUROCODE_CANONICAL_BUILD_BUNDLE="$CANONICAL" \
OUROCODE_APPLICATION_BUNDLE="$TEST_ROOT/Applications/Ourocode.app" \
  "$AUDIT" "$TEST_ROOT/build" "$TEST_ROOT/qa" >/dev/null

DUPLICATE="$TEST_ROOT/duplicate/Ourocode-QA-One-Copy.app"
make_app "$DUPLICATE" com.ourolabs.ourocode.qa.fixture-one qa
set +e
DUPLICATE_OUTPUT=$(OUROCODE_CANONICAL_BUILD_BUNDLE="$CANONICAL" \
  OUROCODE_APPLICATION_BUNDLE="$TEST_ROOT/Applications/Ourocode.app" \
  "$AUDIT" "$TEST_ROOT/build" "$TEST_ROOT/qa" "$TEST_ROOT/duplicate" 2>&1)
DUPLICATE_STATUS=$?
set -e
if [[ $DUPLICATE_STATUS -ne 1 ]] \
    || ! print -r -- "$DUPLICATE_OUTPUT" | rg -Fq 'duplicated non-release identifier(s)'; then
  print -u2 "FAIL: duplicate QA identifier was not rejected"
  print -u2 -- "$DUPLICATE_OUTPUT"
  exit 1
fi

STRAY="$TEST_ROOT/stray/Ourocode-Stale-Release.app"
make_app "$STRAY" com.ourolabs.ourocode qa
set +e
STRAY_OUTPUT=$(OUROCODE_CANONICAL_BUILD_BUNDLE="$CANONICAL" \
  OUROCODE_APPLICATION_BUNDLE="$TEST_ROOT/Applications/Ourocode.app" \
  "$AUDIT" "$TEST_ROOT/build" "$TEST_ROOT/qa" "$TEST_ROOT/stray" 2>&1)
STRAY_STATUS=$?
set -e
if [[ $STRAY_STATUS -ne 1 ]] \
    || ! print -r -- "$STRAY_OUTPUT" | rg -Fq 'release identifier outside canonical locations'; then
  print -u2 "FAIL: QA app carrying the release identifier was not rejected"
  print -u2 -- "$STRAY_OUTPUT"
  exit 1
fi

print "PASS: canonical release location and unique QA identifiers are accepted"
print "PASS: duplicate QA and stray release identifiers fail closed"
