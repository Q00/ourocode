#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
APP_BUILD_ROOT="$APP_ROOT/.build"
APP_BUNDLE="$APP_BUILD_ROOT/Ourocode.app"
ICONSET="$APP_BUILD_ROOT/Ourocode.iconset"
BUILD_MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
CODESIGN_IDENTITY_VALUE="${CODESIGN_IDENTITY:--}"
RELEASE_BUILD_VALUE="${RELEASE_BUILD:-0}"
CANONICAL_BUNDLE_IDENTIFIER="com.ourolabs.ourocode"
DEVELOPMENT_BUNDLE_IDENTIFIER="${OUROCODE_DEV_BUNDLE_IDENTIFIER:-works.ourocode.desktop.dev}"
PROVIDER_SCOPE="${OUROCODE_PROVIDER_SCOPE:-shared-real}"
BROKER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-broker/Cargo.toml"
RENDER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-render-ffi/Cargo.toml"
TERMINAL_SOURCE="$REPOSITORY_ROOT/crates/ouro-terminal-ghostty/src/lib.rs"
SHADER_SOURCE="$APP_ROOT/Resources/OuroTerminalShaders.metal"
TRACKED_SHADER_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/Resources/OuroTerminalShaders.metal"
SWIFTTERM_COMPATIBILITY_BUILD="${OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD:-0}"
if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "1" ]]; then
  GHOSTTY_RENDERER_BUILD="${OUROCODE_GHOSTTY_RENDERER_BUILD:-0}"
  GHOSTTY_METAL_SURFACE_BUILD="${OUROCODE_GHOSTTY_METAL_SURFACE_BUILD:-0}"
else
  GHOSTTY_RENDERER_BUILD="${OUROCODE_GHOSTTY_RENDERER_BUILD:-1}"
  GHOSTTY_METAL_SURFACE_BUILD="${OUROCODE_GHOSTTY_METAL_SURFACE_BUILD:-1}"
fi
METAL_RUNTIME_SOURCE_BUILD="${OUROCODE_METAL_RUNTIME_SOURCE_BUILD:-0}"

if [[ "$RELEASE_BUILD_VALUE" != "0" && "$RELEASE_BUILD_VALUE" != "1" ]]; then
  echo "RELEASE_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$RELEASE_BUILD_VALUE" == "1" ]]; then
  # Files and Folders consent is bound to a stable designated requirement.
  # An ad-hoc "release" changes identity whenever its executable changes, so
  # a login shell can stall while sourcing otherwise-readable startup files
  # under Desktop, Documents, or Downloads. Refuse that artifact here rather
  # than relying on package-dmg.sh to catch it later: build-app.sh is also a
  # public release entry point and its output is directly runnable.
  if [[ "$CODESIGN_IDENTITY_VALUE" == "-" ]]; then
    echo "RELEASE_BUILD=1 requires a Developer ID Application CODESIGN_IDENTITY" >&2
    exit 64
  fi
  if [[ "$CODESIGN_IDENTITY_VALUE" != "Developer ID Application:"* ]]; then
    echo "RELEASE_BUILD=1 requires a Developer ID Application identity, not: $CODESIGN_IDENTITY_VALUE" >&2
    exit 64
  fi
  if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "1" ]]; then
    echo "RELEASE_BUILD=1 cannot package the SwiftTerm compatibility engine" >&2
    exit 64
  fi
  BUILD_PROFILE="release"
  BUNDLE_IDENTIFIER="$CANONICAL_BUNDLE_IDENTIFIER"
else
  BUILD_PROFILE="development"
  BUNDLE_IDENTIFIER="$DEVELOPMENT_BUNDLE_IDENTIFIER"
  if [[ "$BUNDLE_IDENTIFIER" == "$CANONICAL_BUNDLE_IDENTIFIER" ]]; then
    echo "Development and QA builds may not use $CANONICAL_BUNDLE_IDENTIFIER" >&2
    exit 64
  fi
fi
if [[ ! "$BUNDLE_IDENTIFIER" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]]; then
  echo "Invalid bundle identifier: $BUNDLE_IDENTIFIER" >&2
  exit 64
fi
if [[ "$BUILD_PROFILE" == "release" && "$PROVIDER_SCOPE" != "shared-real" ]]; then
  echo "RELEASE_BUILD=1 requires OUROCODE_PROVIDER_SCOPE=shared-real" >&2
  exit 64
fi

if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" != "0" && "$SWIFTTERM_COMPATIBILITY_BUILD" != "1" ]]; then
  echo "OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$GHOSTTY_RENDERER_BUILD" != "0" && "$GHOSTTY_RENDERER_BUILD" != "1" ]]; then
  echo "OUROCODE_GHOSTTY_RENDERER_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$GHOSTTY_METAL_SURFACE_BUILD" != "0" && "$GHOSTTY_METAL_SURFACE_BUILD" != "1" ]]; then
  echo "OUROCODE_GHOSTTY_METAL_SURFACE_BUILD must be 0 or 1" >&2
  exit 64
fi
if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "1" \
    && ( "$GHOSTTY_RENDERER_BUILD" != "0" || "$GHOSTTY_METAL_SURFACE_BUILD" != "0" ) ]]; then
  echo "SwiftTerm compatibility mode cannot be combined with Ghostty renderer or Metal surface flags" >&2
  exit 64
fi
if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "0" \
    && ( "$GHOSTTY_RENDERER_BUILD" != "1" || "$GHOSTTY_METAL_SURFACE_BUILD" != "1" ) ]]; then
  echo "Packaged Ourocode requires the audited Ghostty renderer and Metal surface; set OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=1 for the explicit compatibility artifact" >&2
  exit 64
fi
if [[ "$METAL_RUNTIME_SOURCE_BUILD" != "0" ]]; then
  echo "Packaged builds forbid OUROCODE_METAL_RUNTIME_SOURCE_BUILD; provide a compiled metallib" >&2
  exit 64
fi
if [[ "$GHOSTTY_METAL_SURFACE_BUILD" == "1" ]]; then
  if ! cmp -s "$SHADER_SOURCE" "$TRACKED_SHADER_SOURCE"; then
    echo "The packaged and SwiftPM-tracked terminal shader sources diverged" >&2
    exit 65
  fi
  METAL_TOOL=$(xcrun --sdk macosx --find metal 2>/dev/null || true)
  METALLIB_TOOL=$(xcrun --sdk macosx --find metallib 2>/dev/null || true)
  if [[ -z "$METAL_TOOL" || ! -x "$METAL_TOOL" || -z "$METALLIB_TOOL" || ! -x "$METALLIB_TOOL" ]]; then
    echo "Production Ghostty/Metal packaging requires full Xcode with the macOS metal and metallib tools; Command Line Tools cannot produce a release" >&2
    exit 69
  fi
fi

if [[ "$GHOSTTY_RENDERER_BUILD" == "1" ]]; then
  GHOSTTY_RENDER_PREFIX="${GHOSTTY_VT_PREFIX:-}"
  if [[ -z "$GHOSTTY_RENDER_PREFIX" || "$GHOSTTY_RENDER_PREFIX" != /* ]]; then
    echo "GHOSTTY_VT_PREFIX must be an absolute audited Ghostty install prefix" >&2
    exit 64
  fi
  if [[ ! -f "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" || ! -f "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" ]]; then
    echo "The audited Ghostty header or static archive is missing from $GHOSTTY_RENDER_PREFIX" >&2
    exit 66
  fi

  GHOSTTY_SOURCE_PIN=$(sed -n 's/^pub const GHOSTTY_SOURCE_COMMIT: &str = "\([0-9a-f]\{40\}\)";$/\1/p' "$TERMINAL_SOURCE")
  if [[ ${#GHOSTTY_SOURCE_PIN} -ne 40 ]]; then
    echo "Unable to read the exact Ghostty source pin from ouro-terminal-ghostty" >&2
    exit 65
  fi
  if [[ "$GHOSTTY_SOURCE_PIN" != "136f436a3bbb14fd48d18e927a83fc6585d5a63c" ]]; then
    echo "The terminal crate does not contain the audited Ghostty source pin" >&2
    exit 65
  fi
  GHOSTTY_HEADER_SHA=$(shasum -a 256 "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" | awk '{print $1}')
  GHOSTTY_ARCHIVE_SHA=$(shasum -a 256 "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" | awk '{print $1}')
  if [[ "$GHOSTTY_HEADER_SHA" != "f78301213dcb68a692562dce7a6b0c33f398700a19569c7e14958aa258c111a0" \
      || "$GHOSTTY_ARCHIVE_SHA" != "c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6" ]]; then
    echo "Ghostty header/canonical-archive digest does not match source pin $GHOSTTY_SOURCE_PIN" >&2
    exit 65
  fi

fi

if [[ "${OUROCODE_BUILD_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  echo "PASS: terminal packaging preflight ($([[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "1" ]] && echo swiftterm-compatibility || echo ghostty-metal))"
  exit 0
elif [[ "${OUROCODE_BUILD_PREFLIGHT_ONLY:-0}" != "0" ]]; then
  echo "OUROCODE_BUILD_PREFLIGHT_ONLY must be 0 or 1" >&2
  exit 64
fi

source "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"
SOURCE_DIGEST_AT_BUILD_START=$("$BUILD_MANIFEST_TOOL" source-digest)
BROKER_TARGET_DIR="$APP_BUILD_ROOT/rust-target"
RUST_RELEASE_DIR="$BROKER_TARGET_DIR/$OURO_RUST_TARGET/release"
export MACOSX_DEPLOYMENT_TARGET=13.0
export OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD="$SWIFTTERM_COMPATIBILITY_BUILD"
export OUROCODE_GHOSTTY_RENDERER_BUILD="$GHOSTTY_RENDERER_BUILD"
export OUROCODE_GHOSTTY_METAL_SURFACE_BUILD="$GHOSTTY_METAL_SURFACE_BUILD"
export OUROCODE_METAL_RUNTIME_SOURCE_BUILD=0

if [[ "$GHOSTTY_RENDERER_BUILD" == "1" ]]; then
  GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
    ouro_portable_cargo_build --locked --manifest-path "$RENDER_MANIFEST" \
      --target-dir "$BROKER_TARGET_DIR" --release
  "$REPOSITORY_ROOT/scripts/assert-static-archive-macos-minimum.zsh" \
    "$RUST_RELEASE_DIR/libouro_render_ffi.a" 13.0
  GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
    ouro_portable_cargo_build --locked --manifest-path "$BROKER_MANIFEST" --target-dir "$BROKER_TARGET_DIR" \
      --release --features ghostty-engine --bin ouro-broker-v4-ghostty
  export OUROCODE_GHOSTTY_RENDERER_ARCHIVE="$RUST_RELEASE_DIR/libouro_render_ffi.a"
else
  unset OUROCODE_GHOSTTY_RENDERER_ARCHIVE
  ouro_portable_cargo_build --locked --manifest-path "$BROKER_MANIFEST" \
    --target-dir "$BROKER_TARGET_DIR" --release
fi

TERMINAL_METALLIB=""
if [[ "$GHOSTTY_METAL_SURFACE_BUILD" == "1" ]]; then
  TERMINAL_AIR="$APP_BUILD_ROOT/OuroTerminal.air"
  TERMINAL_METALLIB="$APP_BUILD_ROOT/OuroTerminal.metallib"
  "$METAL_TOOL" -std=macos-metal3.0 -mmacosx-version-min=13.0 \
    -c "$SHADER_SOURCE" -o "$TERMINAL_AIR"
  "$METALLIB_TOOL" "$TERMINAL_AIR" -o "$TERMINAL_METALLIB"
  if [[ ! -s "$TERMINAL_METALLIB" ]]; then
    echo "OuroTerminal.metallib was not produced; refusing a source-fallback release" >&2
    exit 70
  fi
fi

swift build --package-path "$APP_ROOT" --configuration release
SWIFT_BIN_DIR=$(swift build --package-path "$APP_ROOT" --configuration release --show-bin-path)

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" "$APP_BUNDLE/Contents/Resources"
cp "$SWIFT_BIN_DIR/OurocodeDesktop" "$APP_BUNDLE/Contents/MacOS/Ourocode"
if [[ "$GHOSTTY_RENDERER_BUILD" == "1" ]]; then
  BROKER_HELPER_STAGING="$APP_BUNDLE/Contents/Helpers/ouro-broker-v4-ghostty-$GHOSTTY_SOURCE_PIN"
  cp "$RUST_RELEASE_DIR/ouro-broker-v4-ghostty" "$BROKER_HELPER_STAGING"
  if [[ "$CODESIGN_IDENTITY_VALUE" == "-" ]]; then
    codesign --force --sign - "$BROKER_HELPER_STAGING" >/dev/null
  else
    codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY_VALUE" \
      "$BROKER_HELPER_STAGING" >/dev/null
  fi
  BROKER_BUILD_ID=$(shasum -a 256 "$BROKER_HELPER_STAGING" | awk '{print substr($1, 1, 16)}')
  BROKER_HELPER_NAME="ouro-broker-v4-ghostty-$GHOSTTY_SOURCE_PIN-$BROKER_BUILD_ID"
  mv "$BROKER_HELPER_STAGING" "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME"
else
  cp "$RUST_RELEASE_DIR/ouro-broker" "$APP_BUNDLE/Contents/Helpers/ouro-broker"
  cp "$RUST_RELEASE_DIR/ouro-broker-v4" "$APP_BUNDLE/Contents/Helpers/ouro-broker-v4"
fi
if [[ "$GHOSTTY_METAL_SURFACE_BUILD" == "1" ]]; then
  cp "$TERMINAL_METALLIB" "$APP_BUNDLE/Contents/Resources/OuroTerminal.metallib"
fi
cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$BUNDLE_IDENTIFIER" \
  "$APP_BUNDLE/Contents/Info.plist"
if [[ "$GHOSTTY_RENDERER_BUILD" == "1" ]]; then
  plutil -replace OurocodeGhosttyBrokerHelperName -string "$BROKER_HELPER_NAME" \
    "$APP_BUNDLE/Contents/Info.plist"
  plutil -replace OurocodeGhosttyBrokerBuildID -string "$BROKER_BUILD_ID" \
    "$APP_BUNDLE/Contents/Info.plist"
  plutil -replace OurocodeGhosttyBrokerWireNamespace -string "input-v2" \
    "$APP_BUNDLE/Contents/Info.plist"
fi
cp "$APP_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"
cp "$APP_ROOT/Resources/ouroboros-mcp-bridge-cua.yaml" "$APP_BUNDLE/Contents/Resources/"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
swift "$APP_ROOT/AppIconGenerator.swift" "$ICONSET/icon_512x512@2x.png"
for ICON_SPEC in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512"; do
  SOURCE_SIZE="${ICON_SPEC%%:*}"
  ICON_NAME="${ICON_SPEC#*:}"
  sips -z "$SOURCE_SIZE" "$SOURCE_SIZE" "$ICONSET/icon_512x512@2x.png" --out "$ICONSET/icon_$ICON_NAME.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Ourocode.icns"
rm -rf "$ICONSET"

for RESOURCE_BUNDLE in "$SWIFT_BIN_DIR"/*.bundle; do
  if [[ -d "$RESOURCE_BUNDLE" ]]; then
    if [[ "$GHOSTTY_METAL_SURFACE_BUILD" == "1" \
        && "${RESOURCE_BUNDLE:t}" == "SwiftTerm_SwiftTerm.bundle" ]]; then
      # SwiftTerm is retained as a temporary compile-time type dependency, but
      # its renderer and shader bundle belong only to the explicitly labelled
      # compatibility artifact.
      continue
    fi
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
  fi
done

if [[ "$GHOSTTY_METAL_SURFACE_BUILD" == "1" ]]; then
  if find "$APP_BUNDLE" -type f -name '*.metal' -print -quit | grep -q .; then
    echo "Production Ghostty/Metal app contains runtime shader source" >&2
    exit 70
  fi
  if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Ourocode" | rg ' _ouro_render_client_new$' >/dev/null; then
    echo "Production app dead-stripped the static Ghostty render ABI root" >&2
    exit 70
  fi
  if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Ourocode" | rg ' _ouro_split_layout_new$' >/dev/null; then
    echo "Production app dead-stripped the static split-layout ABI root" >&2
    exit 70
  fi
  if otool -L "$APP_BUNDLE/Contents/MacOS/Ourocode" "$APP_BUNDLE/Contents/Helpers/"* \
      | rg 'libghostty[^ ]*\.dylib' >/dev/null; then
    echo "Production app contains a dynamic Ghostty dependency" >&2
    exit 70
  fi
fi
if ! vtool -show-build "$APP_BUNDLE/Contents/MacOS/Ourocode" | rg 'minos 13\.0' >/dev/null; then
  echo "Packaged app does not target macOS 13" >&2
  exit 70
fi
for HELPER in "$APP_BUNDLE/Contents/Helpers/"*(N); do
  if ! vtool -show-build "$HELPER" | rg 'minos 13\.0' >/dev/null; then
    echo "Packaged helper does not target macOS 13: ${HELPER:t}" >&2
    exit 70
  fi
done

if [[ "$SWIFTTERM_COMPATIBILITY_BUILD" == "1" ]]; then
  TERMINAL_ENGINE="swiftterm-compatibility"
else
  TERMINAL_ENGINE="ghostty-metal"
fi
if [[ "$CODESIGN_IDENTITY_VALUE" == "-" ]]; then
  codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/Ourocode" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY_VALUE" \
    "$APP_BUNDLE/Contents/MacOS/Ourocode" >/dev/null
fi
if [[ "$GHOSTTY_RENDERER_BUILD" != "1" ]]; then
  for HELPER in "$APP_BUNDLE/Contents/Helpers/"*(N); do
    if [[ "$CODESIGN_IDENTITY_VALUE" == "-" ]]; then
      codesign --force --sign - "$HELPER" >/dev/null
    else
      codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY_VALUE" \
        "$HELPER" >/dev/null
    fi
  done
fi
"$BUILD_MANIFEST_TOOL" write --app "$APP_BUNDLE" --profile "$BUILD_PROFILE" \
  --engine "$TERMINAL_ENGINE" --provider-scope "$PROVIDER_SCOPE" \
  --expected-source-digest "$SOURCE_DIGEST_AT_BUILD_START"

if [[ "$CODESIGN_IDENTITY_VALUE" == "-" ]]; then
  codesign --force --sign - "$APP_BUNDLE" >/dev/null
else
  codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY_VALUE" \
    "$APP_BUNDLE" >/dev/null
fi
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if [[ "$GHOSTTY_RENDERER_BUILD" == "1" ]]; then
  FINAL_BROKER_BUILD_ID=$(shasum -a 256 "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME" \
    | awk '{print substr($1, 1, 16)}')
  if [[ "$FINAL_BROKER_BUILD_ID" != "$BROKER_BUILD_ID" ]]; then
    echo "The outer app signing pass mutated the build-namespaced Ghostty helper" >&2
    exit 70
  fi
fi
"$BUILD_MANIFEST_TOOL" verify --app "$APP_BUNDLE" --expected-profile "$BUILD_PROFILE" \
  --require-current-source
echo "$APP_BUNDLE"
