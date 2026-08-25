#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
BUILD_MANIFEST_TOOL="$APP_ROOT/canonical-build-manifest.sh"
CANONICAL_BUNDLE_IDENTIFIER="com.ourolabs.ourocode"
PROVIDER_SCOPE="${OUROCODE_PROVIDER_SCOPE:-shared-real}"
source "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"
DEV_BUILD_ROOT="${OUROCODE_DEV_BUILD_ROOT:-$APP_ROOT/.build/dev-ghostty}"
if [[ "$DEV_BUILD_ROOT" != /* ]]; then
  echo "OUROCODE_DEV_BUILD_ROOT must be an absolute path" >&2
  exit 64
fi
SWIFT_SCRATCH="$DEV_BUILD_ROOT/swift"
RUST_TARGET="$DEV_BUILD_ROOT/rust"
RUST_RELEASE_DIR="$RUST_TARGET/$OURO_RUST_TARGET/release"
DEV_APP_NAME="${OUROCODE_DEV_APP_NAME:-Ourocode-Ghostty-Dev.app}"
if [[ "$DEV_APP_NAME" != *.app || "$DEV_APP_NAME" == */* ]]; then
  echo "OUROCODE_DEV_APP_NAME must be one .app basename" >&2
  exit 64
fi
APP_BUNDLE="$DEV_BUILD_ROOT/$DEV_APP_NAME"
DEV_BUNDLE_ID_SUFFIX=$(printf '%s' "$APP_BUNDLE" | shasum -a 256 \
  | awk '{print substr($1, 1, 12)}')
DEV_BUNDLE_IDENTIFIER="${OUROCODE_DEV_BUNDLE_IDENTIFIER:-works.ourocode.desktop.qa-$DEV_BUNDLE_ID_SUFFIX}"
if [[ "$DEV_BUNDLE_IDENTIFIER" == "$CANONICAL_BUNDLE_IDENTIFIER" ]]; then
  echo "Development and QA builds may not use $CANONICAL_BUNDLE_IDENTIFIER" >&2
  exit 64
fi
if [[ ! "$DEV_BUNDLE_IDENTIFIER" =~ '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' ]]; then
  echo "Invalid development bundle identifier: $DEV_BUNDLE_IDENTIFIER" >&2
  exit 64
fi
ICONSET="$DEV_BUILD_ROOT/Ourocode.iconset"
BROKER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-broker/Cargo.toml"
RENDER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-render-ffi/Cargo.toml"
TERMINAL_SOURCE="$REPOSITORY_ROOT/crates/ouro-terminal-ghostty/src/lib.rs"
SHADER_SOURCE="$APP_ROOT/Resources/OuroTerminalShaders.metal"
TRACKED_SHADER_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/Resources/OuroTerminalShaders.metal"
GHOSTTY_RENDER_PREFIX="${GHOSTTY_VT_PREFIX:-}"

if [[ -z "$GHOSTTY_RENDER_PREFIX" || "$GHOSTTY_RENDER_PREFIX" != /* ]]; then
  echo "GHOSTTY_VT_PREFIX must be an absolute audited Ghostty v6 install prefix" >&2
  exit 64
fi
if [[ ! -f "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" \
    || ! -f "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" ]]; then
  echo "The audited Ghostty v6 header or archive is missing from $GHOSTTY_RENDER_PREFIX" >&2
  exit 66
fi
if ! cmp -s "$SHADER_SOURCE" "$TRACKED_SHADER_SOURCE"; then
  echo "The packaged and SwiftPM-tracked terminal shader sources diverged" >&2
  exit 65
fi

GHOSTTY_SOURCE_PIN=$(sed -n \
  's/^pub const GHOSTTY_SOURCE_COMMIT: &str = "\([0-9a-f]\{40\}\)";$/\1/p' \
  "$TERMINAL_SOURCE")
if [[ "$GHOSTTY_SOURCE_PIN" != "136f436a3bbb14fd48d18e927a83fc6585d5a63c" ]]; then
  echo "The terminal crate does not contain the audited Ghostty source pin" >&2
  exit 65
fi
GHOSTTY_HEADER_SHA=$(shasum -a 256 "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" | awk '{print $1}')
GHOSTTY_ARCHIVE_SHA=$(shasum -a 256 "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" | awk '{print $1}')
if [[ "$GHOSTTY_HEADER_SHA" != "f78301213dcb68a692562dce7a6b0c33f398700a19569c7e14958aa258c111a0" \
    || "$GHOSTTY_ARCHIVE_SHA" != "c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6" ]]; then
  echo "Ghostty v6 header/canonical-archive digest does not match $GHOSTTY_SOURCE_PIN" >&2
  exit 65
fi

SOURCE_DIGEST_AT_BUILD_START=$("$BUILD_MANIFEST_TOOL" source-digest)

export MACOSX_DEPLOYMENT_TARGET=13.0
GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
  ouro_portable_cargo_build --locked --manifest-path "$RENDER_MANIFEST" \
    --target-dir "$RUST_TARGET" --release
"$REPOSITORY_ROOT/scripts/assert-static-archive-macos-minimum.zsh" \
  "$RUST_RELEASE_DIR/libouro_render_ffi.a" 13.0
GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
  ouro_portable_cargo_build --locked --manifest-path "$BROKER_MANIFEST" --target-dir "$RUST_TARGET" \
    --release --features ghostty-engine --bin ouro-broker-v4-ghostty

export OUROCODE_GHOSTTY_RENDERER_BUILD=1
export OUROCODE_GHOSTTY_METAL_SURFACE_BUILD=1
export OUROCODE_METAL_RUNTIME_SOURCE_BUILD=1
export OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD=0
export OUROCODE_GHOSTTY_RENDERER_ARCHIVE="$RUST_RELEASE_DIR/libouro_render_ffi.a"
swift build --package-path "$APP_ROOT" --scratch-path "$SWIFT_SCRATCH" --configuration debug
SWIFT_BIN_DIR=$(swift build --package-path "$APP_ROOT" --scratch-path "$SWIFT_SCRATCH" \
  --configuration debug --show-bin-path)

rm -rf "$APP_BUNDLE" "$ICONSET"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Helpers" \
  "$APP_BUNDLE/Contents/Resources" "$ICONSET"
cp "$SWIFT_BIN_DIR/OurocodeDesktop" "$APP_BUNDLE/Contents/MacOS/Ourocode"
BROKER_HELPER_STAGING="$APP_BUNDLE/Contents/Helpers/ouro-broker-v4-ghostty-$GHOSTTY_SOURCE_PIN"
cp "$RUST_RELEASE_DIR/ouro-broker-v4-ghostty" "$BROKER_HELPER_STAGING"
# Sign the nested executable before hashing it. The identity therefore names
# the exact executable bytes the outer app seal will carry, not merely the
# Ghostty source pin used by that executable.
codesign --force --sign - "$BROKER_HELPER_STAGING" >/dev/null
BROKER_BUILD_ID=$(shasum -a 256 "$BROKER_HELPER_STAGING" | awk '{print substr($1, 1, 16)}')
BROKER_HELPER_NAME="ouro-broker-v4-ghostty-$GHOSTTY_SOURCE_PIN-$BROKER_BUILD_ID"
mv "$BROKER_HELPER_STAGING" "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME"
cp "$APP_ROOT/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$DEV_BUNDLE_IDENTIFIER" \
  "$APP_BUNDLE/Contents/Info.plist"
plutil -replace OurocodeGhosttyBrokerHelperName -string "$BROKER_HELPER_NAME" \
  "$APP_BUNDLE/Contents/Info.plist"
plutil -replace OurocodeGhosttyBrokerBuildID -string "$BROKER_BUILD_ID" \
  "$APP_BUNDLE/Contents/Info.plist"
plutil -replace OurocodeGhosttyBrokerWireNamespace -string "input-v2" \
  "$APP_BUNDLE/Contents/Info.plist"
cp "$APP_ROOT/THIRD_PARTY_NOTICES.md" "$APP_BUNDLE/Contents/Resources/"
cp "$APP_ROOT/Resources/ouroboros-mcp-bridge-cua.yaml" "$APP_BUNDLE/Contents/Resources/"
cp "$TRACKED_SHADER_SOURCE" "$APP_BUNDLE/Contents/Resources/OuroTerminalShaders.metal"

for RESOURCE_BUNDLE in "$SWIFT_BIN_DIR"/*.bundle; do
  if [[ -d "$RESOURCE_BUNDLE" ]]; then
    cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
  fi
done

swift "$APP_ROOT/AppIconGenerator.swift" "$ICONSET/icon_512x512@2x.png"
for ICON_SPEC in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
  "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" "512:512x512"; do
  SOURCE_SIZE="${ICON_SPEC%%:*}"
  ICON_NAME="${ICON_SPEC#*:}"
  sips -z "$SOURCE_SIZE" "$SOURCE_SIZE" "$ICONSET/icon_512x512@2x.png" \
    --out "$ICONSET/icon_$ICON_NAME.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/Ourocode.icns"
rm -rf "$ICONSET"

codesign --force --sign - "$APP_BUNDLE/Contents/MacOS/Ourocode" >/dev/null
"$BUILD_MANIFEST_TOOL" write --app "$APP_BUNDLE" --profile development \
  --engine ghostty-metal-runtime-source --provider-scope "$PROVIDER_SCOPE" \
  --expected-source-digest "$SOURCE_DIGEST_AT_BUILD_START"

codesign --force --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
if otool -L "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME" \
    | rg 'libghostty[^ ]*\.dylib' >/dev/null; then
  echo "The development app contains a dynamic Ghostty dependency" >&2
  exit 1
fi
if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    | rg ' _ouro_render_client_new$' >/dev/null; then
  echo "The development app dead-stripped the static render ABI root" >&2
  exit 1
fi
if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    | rg ' _ouro_split_layout_new$' >/dev/null; then
  echo "The development app dead-stripped the static split-layout ABI root" >&2
  exit 1
fi
if ! vtool -show-build "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    | rg 'minos 13\.0' >/dev/null; then
  echo "The development app does not target macOS 13" >&2
  exit 1
fi
if ! vtool -show-build \
    "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME" \
    | rg 'minos 13\.0' >/dev/null; then
  echo "The development Ghostty helper does not target macOS 13" >&2
  exit 1
fi
FINAL_BROKER_BUILD_ID=$(shasum -a 256 "$APP_BUNDLE/Contents/Helpers/$BROKER_HELPER_NAME" \
  | awk '{print substr($1, 1, 16)}')
if [[ "$FINAL_BROKER_BUILD_ID" != "$BROKER_BUILD_ID" ]]; then
  echo "The outer app signing pass mutated the build-namespaced Ghostty helper" >&2
  exit 1
fi
"$BUILD_MANIFEST_TOOL" verify --app "$APP_BUNDLE" --expected-profile development \
  --require-current-source

echo "$APP_BUNDLE"
