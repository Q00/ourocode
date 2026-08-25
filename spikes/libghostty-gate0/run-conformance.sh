#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /absolute/path/to/libghostty-install-prefix" >&2
  exit 64
fi

GHOSTTY_PREFIX=$1
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
BUILD_DIR=${TMPDIR:-/tmp}/ourocode-libghostty-gate0

test -f "$GHOSTTY_PREFIX/include/ghostty/vt.h"
test -f "$GHOSTTY_PREFIX/lib/libghostty-vt.a"
mkdir -p "$BUILD_DIR"

c++ \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$SCRIPT_DIR/include" \
  "$SCRIPT_DIR/tests/layout_cpp.cpp" \
  -o "$BUILD_DIR/layout_cpp"
"$BUILD_DIR/layout_cpp"

cc \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -O2 \
  -I"$SCRIPT_DIR/include" \
  -I"$GHOSTTY_PREFIX/include" \
  "$SCRIPT_DIR/src/ouro_ghostty_adapter.c" \
  "$SCRIPT_DIR/tests/conformance.c" \
  "$GHOSTTY_PREFIX/lib/libghostty-vt.a" \
  -o "$BUILD_DIR/conformance"

"$BUILD_DIR/conformance"
