#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CC_BIN=${CC:-cc}
CXX_BIN=${CXX:-c++}

"$CC_BIN" \
  -std=c11 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$ROOT/include" \
  -x c \
  -fsyntax-only \
  "$ROOT/tests/header_conformance.c"

"$CXX_BIN" \
  -std=c++17 \
  -Wall \
  -Wextra \
  -Werror \
  -I"$ROOT/include" \
  -x c++ \
  -fsyntax-only \
  "$ROOT/tests/header_conformance.c"

echo "ouro-render-ffi C11/C++17 ABI conformance: PASS"
