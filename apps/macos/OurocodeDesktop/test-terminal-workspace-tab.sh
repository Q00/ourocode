#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
source "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"

FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-workspace-tab.XXXXXX")
trap 'rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM
RUST_TARGET_ROOT="$FIXTURE_ROOT/rust"
RENDER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-render-ffi/Cargo.toml"
MODULE_MAP="$APP_ROOT/Sources/COuroRender/module.modulemap"
GHOSTTY_RENDER_PREFIX="${GHOSTTY_VT_PREFIX:-/private/tmp/ouro-ghostty-canonical-v6}"

RENDER_ARCHIVE="${OUROCODE_SPLIT_LAYOUT_ARCHIVE:-}"
if [[ -n "$RENDER_ARCHIVE" ]]; then
  [[ "$RENDER_ARCHIVE" == /* && -s "$RENDER_ARCHIVE" ]] || {
    echo "OUROCODE_SPLIT_LAYOUT_ARCHIVE must be an existing absolute static archive" >&2
    exit 64
  }
elif [[ -f "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" \
    && -f "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" ]]; then
  export MACOSX_DEPLOYMENT_TARGET=13.0
  GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
    ouro_portable_cargo_build --locked --manifest-path "$RENDER_MANIFEST" \
      --target-dir "$RUST_TARGET_ROOT" --release
  RENDER_ARCHIVE="$RUST_TARGET_ROOT/$OURO_RUST_TARGET/release/libouro_render_ffi.a"
else
  RENDER_ARCHIVE="$REPOSITORY_ROOT/target/debug/libouro_render_ffi.a"
  [[ -s "$RENDER_ARCHIVE" ]] || {
    echo "Provide GHOSTTY_VT_PREFIX or OUROCODE_SPLIT_LAYOUT_ARCHIVE for the workspace fixture" >&2
    exit 66
  }
  echo "Using existing static ABI archive: $RENDER_ARCHIVE" >&2
fi

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -D OUROCODE_GHOSTTY_RENDERER \
  -D OUROCODE_PANE_PROJECTION_FIXTURE \
  -I "$APP_ROOT/Sources/COuroRender" \
  -Xcc "-fmodule-map-file=$MODULE_MAP" \
  "$APP_ROOT/Sources/OurocodeDesktop/PaneProjectionToken.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/PaneSurfaceAdmissionPolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/NormalizedTerminalInput.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalViewLifecyclePolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSplitLayoutBridge.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalWorkspaceTab.swift" \
  "$APP_ROOT/Tests/TerminalWorkspaceTabFixture.swift" \
  "$RENDER_ARCHIVE" \
  -o "$FIXTURE_ROOT/terminal-workspace-tab-fixture"

"$FIXTURE_ROOT/terminal-workspace-tab-fixture"
