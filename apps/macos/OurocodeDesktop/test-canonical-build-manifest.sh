#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-build-manifest.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
SOURCE_DIGEST=$($MANIFEST_TOOL source-digest)

make_app() {
  local app="$1"
  local bundle_id="$2"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
  cp /usr/bin/true "$app/Contents/MacOS/Ourocode"
  cp /usr/bin/true "$app/Contents/Helpers/fixture-helper"
  cp "$APP_ROOT/Resources/Info.plist" "$app/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
}

expect_status_and_text() {
  local expected_status="$1"
  local expected_text="$2"
  shift 2
  set +e
  local output
  output=$("$@" 2>&1)
  local exit_code=$?
  set -e
  if [[ $exit_code -ne $expected_status ]] || ! print -r -- "$output" | rg -Fq "$expected_text"; then
    print -u2 "FAIL: expected status $expected_status and: $expected_text"
    print -u2 -- "$output"
    exit 1
  fi
}

DEVELOPMENT_APP="$TEST_ROOT/Ourocode-Development.app"
make_app "$DEVELOPMENT_APP" works.ourocode.desktop.manifest-fixture
$MANIFEST_TOOL write --app "$DEVELOPMENT_APP" --profile development \
  --engine ghostty-metal-runtime-source --provider-scope isolated-fixture \
  --expected-source-digest "$SOURCE_DIGEST"
$MANIFEST_TOOL verify --app "$DEVELOPMENT_APP" --expected-profile development \
  --require-current-source

cp /usr/bin/false "$DEVELOPMENT_APP/Contents/Helpers/fixture-helper"
expect_status_and_text 65 'Ourocode helpers do not match their build manifest' \
  "$MANIFEST_TOOL" verify --app "$DEVELOPMENT_APP" --expected-profile development

CANONICAL_DEV_APP="$TEST_ROOT/Ourocode-Canonical-Development.app"
make_app "$CANONICAL_DEV_APP" com.ourolabs.ourocode
expect_status_and_text 65 'Development and QA builds may not use com.ourolabs.ourocode' \
  "$MANIFEST_TOOL" write --app "$CANONICAL_DEV_APP" --profile development \
    --engine ghostty-metal-runtime-source --provider-scope isolated-fixture \
    --expected-source-digest "$SOURCE_DIGEST"

RELEASE_APP="$TEST_ROOT/Ourocode-Release.app"
make_app "$RELEASE_APP" com.ourolabs.ourocode
expect_status_and_text 65 'Release manifests require the audited ghostty-metal engine' \
  "$MANIFEST_TOOL" write --app "$RELEASE_APP" --profile release \
    --engine swiftterm-compatibility --provider-scope shared-real \
    --expected-source-digest "$SOURCE_DIGEST"
expect_status_and_text 65 'Release manifests require provider scope shared-real' \
  "$MANIFEST_TOOL" write --app "$RELEASE_APP" --profile release \
    --engine ghostty-metal --provider-scope isolated-fixture \
    --expected-source-digest "$SOURCE_DIGEST"
$MANIFEST_TOOL write --app "$RELEASE_APP" --profile release --engine ghostty-metal \
  --provider-scope shared-real --expected-source-digest "$SOURCE_DIGEST"
$MANIFEST_TOOL verify --app "$RELEASE_APP" --expected-profile release \
  --require-current-source

print "PASS: development manifest is source-bound and detects helper tampering"
print "PASS: development cannot claim the production identifier"
print "PASS: release requires production ID, Ghostty/Metal, and shared-real provider scope"
