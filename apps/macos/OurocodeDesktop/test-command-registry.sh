#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUT="${TMPDIR:-/tmp}/ourocode-command-registry-fixture"

xcrun swiftc \
  "$ROOT/Sources/OurocodeDesktop/CommandRegistry.swift" \
  "$ROOT/Tests/CommandRegistryFixture.swift" \
  -o "$OUT"

"$OUT"
