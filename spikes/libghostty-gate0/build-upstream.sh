#!/bin/sh
set -eu

PINNED_COMMIT=136f436a3bbb14fd48d18e927a83fc6585d5a63c
PINNED_ZIG_VERSION=0.16.0
PATCH_SHA256=58596254d225ae5cccd6abc402b494c4648ce58e9dc42c8d23e055f1381aabd3
MEMBER_MANIFEST_SHA256=0425918640f8ab640ad9fb88699e3396c4c0dc4ee53a47343f642c64ded07055
HEADER_SHA256=f78301213dcb68a692562dce7a6b0c33f398700a19569c7e14958aa258c111a0
CANONICAL_ARCHIVE_SHA256=c2c507b9355627e0ee2535e8328e47715212ea9075d50a96997fd3db2b8c34b6
MACOS_MIN_VERSION=${OUROCODE_MACOS_MIN_VERSION:-13.0}
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
PAGE_BUDGET_PATCH="$SCRIPT_DIR/patches/0001-shared-page-budget.patch"
MEMBER_MANIFEST="$SCRIPT_DIR/canonical-members.sha256"
CANONICALIZER="$SCRIPT_DIR/canonicalize-archive.sh"
ZIG_VERIFIER="$SCRIPT_DIR/verify-zig-distribution.sh"

if [ "$#" -ne 2 ]; then
  echo "usage: OUROCODE_ZIG_ARCHIVE=/absolute/zig.tar.xz $0 /absolute/path/to/ghostty /absolute/install/prefix" >&2
  exit 64
fi

GHOSTTY_SOURCE=$1
INSTALL_PREFIX=$2
ZIG_ARCHIVE=${OUROCODE_ZIG_ARCHIVE:-}

if [ -z "$ZIG_ARCHIVE" ] || [ "${ZIG_ARCHIVE#/}" = "$ZIG_ARCHIVE" ]; then
  echo "OUROCODE_ZIG_ARCHIVE must name the absolute official Zig 0.16.0 archive" >&2
  exit 64
fi

test "$(git -C "$GHOSTTY_SOURCE" rev-parse HEAD)" = "$PINNED_COMMIT"
test "$(zig version)" = "$PINNED_ZIG_VERSION"
"$ZIG_VERIFIER" "$ZIG_ARCHIVE"
test "$(shasum -a 256 "$PAGE_BUDGET_PATCH" | awk '{print $1}')" = "$PATCH_SHA256"
test "$(shasum -a 256 "$MEMBER_MANIFEST" | awk '{print $1}')" = "$MEMBER_MANIFEST_SHA256"
if ! git -C "$GHOSTTY_SOURCE" diff --quiet --ignore-submodules -- \
    || ! git -C "$GHOSTTY_SOURCE" diff --cached --quiet --ignore-submodules -- \
    || [ -n "$(git -C "$GHOSTTY_SOURCE" ls-files --others --exclude-standard)" ]; then
  echo "Ghostty source must be clean before applying the pinned Ourocode patch" >&2
  exit 65
fi
git -C "$GHOSTTY_SOURCE" apply --check "$PAGE_BUDGET_PATCH"
git -C "$GHOSTTY_SOURCE" apply "$PAGE_BUDGET_PATCH"
PATCH_APPLIED=1
cleanup() {
  if [ "${PATCH_APPLIED:-0}" = 1 ]; then
    git -C "$GHOSTTY_SOURCE" apply --reverse "$PAGE_BUDGET_PATCH"
    PATCH_APPLIED=0
  fi
}
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

case "$(uname -m)" in
  arm64) GHOSTTY_TARGET="aarch64-macos.$MACOS_MIN_VERSION" ;;
  x86_64) GHOSTTY_TARGET="x86_64-macos.$MACOS_MIN_VERSION" ;;
  *)
    echo "unsupported macOS architecture: $(uname -m)" >&2
    exit 66
    ;;
esac

zig build \
  --build-file "$GHOSTTY_SOURCE/build.zig" \
  -Dtarget="$GHOSTTY_TARGET" \
  -Demit-lib-vt=true \
  -Demit-xcframework=false \
  -Doptimize=ReleaseFast \
  --prefix "$INSTALL_PREFIX"

test -f "$INSTALL_PREFIX/include/ghostty/vt.h"
test -f "$INSTALL_PREFIX/lib/libghostty-vt.a"
RAW_ARCHIVE="$INSTALL_PREFIX/lib/libghostty-vt.raw.a"
CANONICAL_ARCHIVE="$INSTALL_PREFIX/lib/libghostty-vt.canonical.a"
mv "$INSTALL_PREFIX/lib/libghostty-vt.a" "$RAW_ARCHIVE"
"$CANONICALIZER" "$RAW_ARCHIVE" "$CANONICAL_ARCHIVE" "$MEMBER_MANIFEST"
mv "$CANONICAL_ARCHIVE" "$INSTALL_PREFIX/lib/libghostty-vt.a"
rm "$RAW_ARCHIVE"

test "$(shasum -a 256 "$INSTALL_PREFIX/include/ghostty/vt.h" | awk '{print $1}')" = "$HEADER_SHA256"
test "$(shasum -a 256 "$INSTALL_PREFIX/lib/libghostty-vt.a" | awk '{print $1}')" = "$CANONICAL_ARCHIVE_SHA256"
shasum -a 256 "$INSTALL_PREFIX/lib/libghostty-vt.a"
