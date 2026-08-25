#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-command-ax-fixture.XXXXXX")
PALETTE="$APP_ROOT/Sources/OurocodeDesktop/CommandPaletteViewController.swift"
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/MacCommandAccessibility.swift" \
  "$APP_ROOT/Tests/MacCommandAccessibilityFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

rg -Fq 'searchField.focusRingType = .default' "$PALETTE"
rg -Fq 'NSWorkspace.accessibilityDisplayOptionsDidChangeNotification' "$PALETTE"
rg -Fq '? .windowBackground' "$PALETTE"
rg -Fq 'accessibility.reduceTransparency ? .withinWindow : .behindWindow' "$PALETTE"
