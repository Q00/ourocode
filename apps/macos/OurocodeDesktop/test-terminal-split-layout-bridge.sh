#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
REPOSITORY_ROOT="${APP_ROOT:h:h:h}"
source "$REPOSITORY_ROOT/scripts/rust-portable-build-env.zsh"

FIXTURE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-split-layout-bridge.XXXXXX")
trap 'rm -rf "$FIXTURE_ROOT"' EXIT HUP INT TERM
RUST_TARGET_ROOT="$FIXTURE_ROOT/rust"
RENDER_MANIFEST="$REPOSITORY_ROOT/crates/ouro-render-ffi/Cargo.toml"
MODULE_MAP="$APP_ROOT/Sources/COuroRender/module.modulemap"
GHOSTTY_RENDER_PREFIX="${GHOSTTY_VT_PREFIX:-/private/tmp/ouro-ghostty-canonical-v6}"

RENDER_ARCHIVE="${OUROCODE_SPLIT_LAYOUT_ARCHIVE:-}"
if [[ -n "$RENDER_ARCHIVE" ]]; then
  if [[ "$RENDER_ARCHIVE" != /* || ! -s "$RENDER_ARCHIVE" ]]; then
    echo "OUROCODE_SPLIT_LAYOUT_ARCHIVE must be an existing absolute static archive" >&2
    exit 64
  fi
elif [[ -f "$GHOSTTY_RENDER_PREFIX/include/ghostty/vt.h" \
    && -f "$GHOSTTY_RENDER_PREFIX/lib/libghostty-vt.a" ]]; then
  export MACOSX_DEPLOYMENT_TARGET=13.0
  GHOSTTY_VT_PREFIX="$GHOSTTY_RENDER_PREFIX" \
    ouro_portable_cargo_build --locked --manifest-path "$RENDER_MANIFEST" \
      --target-dir "$RUST_TARGET_ROOT" --release
  RENDER_ARCHIVE="$RUST_TARGET_ROOT/$OURO_RUST_TARGET/release/libouro_render_ffi.a"
else
  # A prior static Rust ABI build is sufficient for this ABI-only fixture. The
  # full Ghostty/Metal build still requires the exact pinned prefix and never
  # takes this fallback.
  RENDER_ARCHIVE="$REPOSITORY_ROOT/target/debug/libouro_render_ffi.a"
  if [[ ! -s "$RENDER_ARCHIVE" ]]; then
    echo "Provide GHOSTTY_VT_PREFIX or OUROCODE_SPLIT_LAYOUT_ARCHIVE for the split fixture" >&2
    exit 66
  fi
  echo "Using existing static ABI archive: $RENDER_ARCHIVE" >&2
fi

if [[ ! -s "$RENDER_ARCHIVE" ]]; then
  echo "ouro-render-ffi did not produce a static archive" >&2
  exit 1
fi

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -D OUROCODE_GHOSTTY_RENDERER \
  -I "$APP_ROOT/Sources/COuroRender" \
  -Xcc "-fmodule-map-file=$MODULE_MAP" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSplitLayoutBridge.swift" \
  "$APP_ROOT/Tests/TerminalSplitLayoutBridgeFixture.swift" \
  "$RENDER_ARCHIVE" \
  -o "$FIXTURE_ROOT/terminal-split-layout-bridge-fixture"

if ! nm -gU "$FIXTURE_ROOT/terminal-split-layout-bridge-fixture" \
    | rg ' _ouro_split_layout_new$' >/dev/null; then
  echo "Fixture did not retain the linked split-layout ABI root" >&2
  exit 1
fi

"$FIXTURE_ROOT/terminal-split-layout-bridge-fixture"
