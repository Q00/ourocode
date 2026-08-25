#!/bin/zsh

# Rust's prebuilt macOS std may inherit the build host's deployment target.
# Ourocode statically links Rust into an app that supports macOS 13, so release
# and development app artifacts rebuild std from the pinned rust-src component.

OURO_RUST_TOOLCHAIN="1.97.1"
OURO_RUSTUP_BIN=$(command -v rustup || true)
if [[ -z "$OURO_RUSTUP_BIN" ]]; then
  echo "Ourocode app builds require rustup and pinned toolchain $OURO_RUST_TOOLCHAIN" >&2
  exit 69
fi

OURO_RUSTC_BIN=$($OURO_RUSTUP_BIN which --toolchain "$OURO_RUST_TOOLCHAIN" rustc 2>/dev/null || true)
OURO_CARGO_BIN=$($OURO_RUSTUP_BIN which --toolchain "$OURO_RUST_TOOLCHAIN" cargo 2>/dev/null || true)
if [[ -z "$OURO_RUSTC_BIN" || -z "$OURO_CARGO_BIN" ]]; then
  echo "Install pinned Rust $OURO_RUST_TOOLCHAIN with rust-src before building Ourocode" >&2
  exit 69
fi

OURO_RUST_SYSROOT=$($OURO_RUSTC_BIN --print sysroot)
if [[ ! -f "$OURO_RUST_SYSROOT/lib/rustlib/src/rust/library/std/Cargo.toml" ]]; then
  echo "Pinned Rust $OURO_RUST_TOOLCHAIN is missing the rust-src component" >&2
  exit 69
fi

case "$(uname -m)" in
  arm64) OURO_RUST_TARGET="aarch64-apple-darwin" ;;
  x86_64) OURO_RUST_TARGET="x86_64-apple-darwin" ;;
  *)
    echo "Unsupported macOS build architecture: $(uname -m)" >&2
    exit 69
    ;;
esac

ouro_portable_cargo_build() {
  MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-13.0}" \
    RUSTUP_TOOLCHAIN="$OURO_RUST_TOOLCHAIN" \
    RUSTC="$OURO_RUSTC_BIN" \
    RUSTC_BOOTSTRAP=1 \
    "$OURO_CARGO_BIN" -Z build-std build --target "$OURO_RUST_TARGET" "$@"
}

