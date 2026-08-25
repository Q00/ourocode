#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h}"
OUT="${TMPDIR:-/tmp}/ourocode-terminal-tab-launch-directory"

xcrun swiftc \
  "$ROOT/Sources/OurocodeDesktop/TerminalTabLaunchDirectory.swift" \
  "$ROOT/Tests/TerminalTabLaunchDirectoryFixture.swift" \
  -o "$OUT"

"$OUT"
