#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BUILD_APP="$APP_ROOT/build-app.sh"
DEV_BUILD_APP="$APP_ROOT/build-dev-ghostty-app.sh"
CANONICAL_PREFIX="${GHOSTTY_VT_PREFIX:-/private/tmp/ouro-ghostty-canonical-v6}"

if [[ ! -d /Library/Developer/CommandLineTools ]]; then
  echo "Command Line Tools fixture is unavailable" >&2
  exit 69
fi

# A directly-built release is runnable before package-dmg.sh ever sees it.
# Fail at the build boundary so an ad-hoc identity cannot repeatedly lose the
# Files and Folders consent needed by a real login shell's startup files.
set +e
ADHOC_RELEASE_OUTPUT=$(
  RELEASE_BUILD=1 \
    CODESIGN_IDENTITY=- \
    OUROCODE_BUILD_PREFLIGHT_ONLY=1 \
    "$BUILD_APP" 2>&1
)
ADHOC_RELEASE_STATUS=$?
set -e
if [[ $ADHOC_RELEASE_STATUS -ne 64 ]] \
    || ! print -r -- "$ADHOC_RELEASE_OUTPUT" \
      | rg 'requires a Developer ID Application CODESIGN_IDENTITY' >/dev/null; then
  echo "Direct release build accepted an ad-hoc code identity" >&2
  print -r -- "$ADHOC_RELEASE_OUTPUT" >&2
  exit 1
fi

# A production invocation has no opt-in flag: Ghostty plus a compiled Metal
# library is the default. Pinning xcrun to CLT must fail before Cargo or Swift
# can produce a misleading compatibility artifact.
set +e
FAIL_CLOSED_OUTPUT=$(
  env -u OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD \
    -u OUROCODE_GHOSTTY_RENDERER_BUILD \
    -u OUROCODE_GHOSTTY_METAL_SURFACE_BUILD \
    -u OUROCODE_METAL_RUNTIME_SOURCE_BUILD \
    DEVELOPER_DIR=/Library/Developer/CommandLineTools \
    GHOSTTY_VT_PREFIX="$CANONICAL_PREFIX" \
    OUROCODE_BUILD_PREFLIGHT_ONLY=1 \
    "$BUILD_APP" 2>&1
)
FAIL_CLOSED_STATUS=$?
set -e
if [[ $FAIL_CLOSED_STATUS -ne 69 ]] \
    || ! print -r -- "$FAIL_CLOSED_OUTPUT" | rg 'requires full Xcode' >/dev/null; then
  echo "Production packaging did not fail closed without metal/metallib" >&2
  print -r -- "$FAIL_CLOSED_OUTPUT" >&2
  exit 1
fi

# SwiftTerm is a named, coherent compatibility artifact. It is never inferred
# from missing Ghostty inputs or missing Xcode.
COMPATIBILITY_OUTPUT=$(
  OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1 \
    OUROCODE_BUILD_PREFLIGHT_ONLY=1 \
    "$BUILD_APP"
)
if ! print -r -- "$COMPATIBILITY_OUTPUT" | rg 'swiftterm-compatibility' >/dev/null; then
  echo "Explicit SwiftTerm compatibility preflight did not succeed" >&2
  exit 1
fi

set +e
MIXED_MODE_OUTPUT=$(
  OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1 \
    OUROCODE_GHOSTTY_RENDERER_BUILD=1 \
    OUROCODE_BUILD_PREFLIGHT_ONLY=1 \
    "$BUILD_APP" 2>&1
)
MIXED_MODE_STATUS=$?
set -e
if [[ $MIXED_MODE_STATUS -ne 64 ]] \
    || ! print -r -- "$MIXED_MODE_OUTPUT" | rg 'cannot be combined' >/dev/null; then
  echo "Mixed SwiftTerm/Ghostty packaging mode was not rejected" >&2
  exit 1
fi

PACKAGE_JSON=$(mktemp "${TMPDIR:-/tmp}/ourocode-package.XXXXXX")
PACKAGING_RUNTIME_ROOT=""
cleanup() {
  rm -f -- "$PACKAGE_JSON"
  if [[ -n "$PACKAGING_RUNTIME_ROOT" && -d "$PACKAGING_RUNTIME_ROOT" ]]; then
    rm -rf -- "$PACKAGING_RUNTIME_ROOT"
  fi
}
trap cleanup EXIT
OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1 \
  swift package --package-path "$APP_ROOT" dump-package >"$PACKAGE_JSON"
if jq -e 'any(.targets[].resources[]?; .path == "Resources/OuroTerminalShaders.metal")' \
    "$PACKAGE_JSON" >/dev/null; then
  echo "Compatibility package unexpectedly carries Ghostty runtime shader source" >&2
  exit 1
fi

OUROCODE_GHOSTTY_RENDERER_BUILD=1 \
  OUROCODE_GHOSTTY_METAL_SURFACE_BUILD=1 \
  OUROCODE_GHOSTTY_RENDERER_ARCHIVE=/private/tmp/ourocode-package-contract.a \
  swift package --package-path "$APP_ROOT" dump-package >"$PACKAGE_JSON"
if jq -e 'any(.targets[].resources[]?; .path == "Resources/OuroTerminalShaders.metal")' \
    "$PACKAGE_JSON" >/dev/null; then
  echo "Production package unexpectedly carries runtime Metal source" >&2
  exit 1
fi

OUROCODE_GHOSTTY_RENDERER_BUILD=1 \
  OUROCODE_GHOSTTY_METAL_SURFACE_BUILD=1 \
  OUROCODE_METAL_RUNTIME_SOURCE_BUILD=1 \
  OUROCODE_GHOSTTY_RENDERER_ARCHIVE=/private/tmp/ourocode-package-contract.a \
  swift package --package-path "$APP_ROOT" dump-package >"$PACKAGE_JSON"
if ! jq -e 'any(.targets[].resources[]?; .path == "Resources/OuroTerminalShaders.metal")' \
    "$PACKAGE_JSON" >/dev/null; then
  echo "Development package lost its explicit runtime Metal source" >&2
  exit 1
fi

rg -Fq 'cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"' "$BUILD_APP"
rg -Fq 'cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"' "$DEV_BUILD_APP"
rg -Fq 'resources.appendingPathComponent(' \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift"
rg -Fq '"OurocodeDesktop_OurocodeDesktop.bundle"' \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift"
rg -Fq 'Bundle.main.bundleURL.pathExtension == "app"' \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift"
rg -Fq 'preconditionFailure(' \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift"

# When an exact packaged fixture is supplied, prove the app fails before it can
# fall back to any live SwiftPM scratch beside the build machine. The source
# bundle is copied into a new mktemp directory and the original is untouched.
if [[ -n "${OUROCODE_PACKAGED_APP_FIXTURE:-}" ]]; then
  if [[ "$OUROCODE_PACKAGED_APP_FIXTURE" != /*.app \
      || ! -x "$OUROCODE_PACKAGED_APP_FIXTURE/Contents/MacOS/Ourocode" ]]; then
    echo "OUROCODE_PACKAGED_APP_FIXTURE must be an absolute Ourocode .app" >&2
    exit 64
  fi
  PACKAGING_RUNTIME_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-packaging-runtime.XXXXXX")
  BROKEN_APP="$PACKAGING_RUNTIME_ROOT/Ourocode-Missing-Resources.app"
  ditto "$OUROCODE_PACKAGED_APP_FIXTURE" "$BROKEN_APP"
  RESOURCE_BUNDLE="$BROKEN_APP/Contents/Resources/OurocodeDesktop_OurocodeDesktop.bundle"
  if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
    echo "Packaged fixture does not contain the expected resource bundle" >&2
    exit 66
  fi
  mv "$RESOURCE_BUNDLE" "$RESOURCE_BUNDLE.missing"
  # A fresh identifier avoids AppKit's previous-crash restoration alert from
  # intercepting the deliberately fatal resource check on repeated runs.
  FIXTURE_IDENTIFIER="works.ourocode.packaging-fixture.$$.$RANDOM"
  plutil -replace CFBundleIdentifier -string "$FIXTURE_IDENTIFIER" \
    "$BROKEN_APP/Contents/Info.plist"
  codesign --force --sign - "$BROKEN_APP" >/dev/null
  set +e
  RUNTIME_OUTPUT=$("$BROKEN_APP/Contents/MacOS/Ourocode" \
    -ApplePersistenceIgnoreState YES --no-ouroboros --shell /bin/sh 2>&1)
  RUNTIME_STATUS=$?
  set -e
  if [[ $RUNTIME_STATUS -ne 133 ]] \
      || ! print -r -- "$RUNTIME_OUTPUT" | rg -Fq \
        'Packaged Ourocode is missing OurocodeDesktop_OurocodeDesktop.bundle'; then
    echo "Missing packaged resources were hidden by a build-scratch fallback" >&2
    echo "Expected missing-resource exit status 133, got $RUNTIME_STATUS" >&2
    print -r -- "$RUNTIME_OUTPUT" >&2
    exit 1
  fi
fi

echo "PASS: production defaults to audited Ghostty/Metal and fails closed without full Xcode"
echo "PASS: direct release builds require a stable Developer ID Application identity"
echo "PASS: packaged apps cannot hide a missing resource bundle behind SwiftPM scratch"
echo "PASS: SwiftTerm is explicit compatibility mode and release packages omit Metal source"
