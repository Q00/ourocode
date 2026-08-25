#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUT="${TMPDIR:-/tmp}/ourocode-terminal-pointer-readiness-policy"

xcrun swiftc \
  -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$ROOT/Sources/OurocodeDesktop/TerminalPointerReadinessPolicy.swift" \
  "$ROOT/Tests/TerminalPointerReadinessPolicyFixture.swift" \
  -o "$OUT"

"$OUT"
