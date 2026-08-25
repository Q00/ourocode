#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-typography-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalBackingScale.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalLayoutEpoch.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalTypographyShortcut.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/Theme.swift" \
  "$APP_ROOT/Tests/TerminalTypographyFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
