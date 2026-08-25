#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-metal-memory.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc \
  -warnings-as-errors \
  "$ROOT/Sources/OurocodeDesktop/TerminalMetalSurfaceMemoryPolicy.swift" \
  "$ROOT/Tests/TerminalMetalSurfaceMemoryPolicyFixture.swift" \
  -o "$TMP_DIR/terminal-metal-memory-fixture"

"$TMP_DIR/terminal-metal-memory-fixture"

VIEW="$ROOT/Sources/OurocodeDesktop/OuroMetalTerminalView.swift"
rg -Fq 'metalLayer.maximumDrawableCount = TerminalMetalSurfaceMemoryPolicy.maximumDrawableCount' "$VIEW"
rg -Fq 'metalLayer.presentsWithTransaction = TerminalMetalSurfaceMemoryPolicy.presentsWithTransaction' "$VIEW"
if rg -n 'maximumDrawableCount\s*=\s*[3-9]' "$VIEW" >/dev/null; then
  echo "FAIL: terminal surface raised CAMetalLayer drawable count above the memory policy" >&2
  exit 1
fi

echo "PASS: MTKView configuration is wired to the bounded surface-memory policy"
