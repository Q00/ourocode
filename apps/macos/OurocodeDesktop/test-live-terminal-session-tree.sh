#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-live-terminal-session-tree.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/LiveTerminalSessionTreePolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/LiveTerminalSession.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSessionBinding.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Tests/LiveTerminalSessionTreeFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
