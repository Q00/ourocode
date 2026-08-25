#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE="$APP_ROOT/.build/ouro-terminal-color-semantics-fixture"

swiftc -warnings-as-errors -parse-as-library \
  -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroTerminalColorSemantics.swift" \
  "$APP_ROOT/Tests/OuroTerminalColorSemanticsFixture.swift" \
  -o "$FIXTURE"

"$FIXTURE"
