#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
source "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"
SMOKE_BINARY="$APP_ROOT/.build/ghostty-render-bridge-smoke"
MODULE_MAP="$APP_ROOT/Sources/COuroRender/module.modulemap"
GHOSTTY_SOURCE_PIN=$(sed -n 's/^pub const GHOSTTY_SOURCE_COMMIT: &str = "\([0-9a-f]\{40\}\)";$/\1/p' \
  "$REPOSITORY_ROOT/crates/ouro-terminal-ghostty/src/lib.rs")

if [[ ${#GHOSTTY_SOURCE_PIN} -ne 40 ]]; then
  echo "Unable to read the exact Ghostty source pin" >&2
  exit 65
fi

export GHOSTTY_VT_PREFIX="${GHOSTTY_VT_PREFIX:-/private/tmp/ouro-ghostty-canonical-v6}"
export MACOSX_DEPLOYMENT_TARGET=13.0

METAL_TOOL=$(xcrun --sdk macosx --find metal 2>/dev/null || true)
METALLIB_TOOL=$(xcrun --sdk macosx --find metallib 2>/dev/null || true)
if [[ -n "$METAL_TOOL" && -x "$METAL_TOOL" && -n "$METALLIB_TOOL" && -x "$METALLIB_TOOL" ]]; then
  unset OUROCODE_SWIFTTERM_COMPATIBILITY_BUILD
  unset OUROCODE_GHOSTTY_RENDERER_BUILD
  unset OUROCODE_GHOSTTY_METAL_SURFACE_BUILD
  unset OUROCODE_METAL_RUNTIME_SOURCE_BUILD
  "$APP_ROOT/build-app.sh" >/dev/null
  APP_BUNDLE="$APP_ROOT/.build/Ourocode.app"
  RENDER_ARCHIVE="$APP_ROOT/.build/rust-target/$OURO_RUST_TARGET/release/libouro_render_ffi.a"
  if [[ ! -s "$APP_BUNDLE/Contents/Resources/OuroTerminal.metallib" ]]; then
    echo "Production Ghostty build did not package OuroTerminal.metallib" >&2
    exit 1
  fi
  if find "$APP_BUNDLE" -type f -name '*.metal' -print -quit | grep -q .; then
    echo "Production Ghostty build packaged runtime Metal source" >&2
    exit 1
  fi
else
  # Command Line Tools cannot produce a release metallib. Keep exercising the
  # render ABI through the explicitly development-only source path; the
  # packaging-contract fixture separately proves that release fails closed.
  TEST_DEV_BUILD_ROOT="$APP_ROOT/.build/test-ghostty-render"
  OUROCODE_DEV_BUILD_ROOT="$TEST_DEV_BUILD_ROOT" \
    "$APP_ROOT/build-dev-ghostty-app.sh" >/dev/null
  APP_BUNDLE="$TEST_DEV_BUILD_ROOT/Ourocode-Ghostty-Dev.app"
  RENDER_ARCHIVE="$TEST_DEV_BUILD_ROOT/rust/$OURO_RUST_TARGET/release/libouro_render_ffi.a"
  if [[ ! -s "$APP_BUNDLE/Contents/Resources/OuroTerminalShaders.metal" ]]; then
    echo "Development Ghostty build did not package its labelled runtime shader source" >&2
    exit 1
  fi
fi

swiftc -O -parse-as-library -D OUROCODE_GHOSTTY_RENDERER \
  -I "$APP_ROOT/Sources/COuroRender" \
  -Xcc "-fmodule-map-file=$MODULE_MAP" \
  "$APP_ROOT/Sources/OurocodeDesktop/GhosttyRenderBridge.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHyperlinkPolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/NormalizedTerminalInput.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift" \
  "$APP_ROOT/Tests/GhosttyRenderBridgeSmoke.swift" \
  "$RENDER_ARCHIVE" \
  -o "$SMOKE_BINARY"

"$SMOKE_BINARY" "$APP_BUNDLE"

if otool -L "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    "$APP_BUNDLE/Contents/Helpers"/* \
    | rg 'libghostty[^ ]*\.dylib' >/dev/null; then
  echo "A bundled executable has a dynamic Ghostty dependency" >&2
  exit 1
fi

if ! nm -gU "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    | rg ' _ouro_render_client_new$' >/dev/null; then
  echo "The feature-on executable dead-stripped the static render ABI root" >&2
  exit 1
fi

if ! vtool -show-build "$APP_BUNDLE/Contents/MacOS/Ourocode" \
    | rg 'minos 13\.0' >/dev/null; then
  echo "The feature-on executable does not target macOS 13" >&2
  exit 1
fi
PACKAGED_HELPER_NAME=$(/usr/libexec/PlistBuddy \
  -c 'Print :OurocodeGhosttyBrokerHelperName' "$APP_BUNDLE/Contents/Info.plist")
if ! vtool -show-build \
    "$APP_BUNDLE/Contents/Helpers/$PACKAGED_HELPER_NAME" \
    | rg 'minos 13\.0' >/dev/null; then
  echo "The pin-namespaced helper does not target macOS 13" >&2
  exit 1
fi

echo "PASS: app and pin-namespaced helpers have zero Ghostty dylib load commands"
echo "PASS: static render ABI root retained and app/helper minimum target is macOS 13"
