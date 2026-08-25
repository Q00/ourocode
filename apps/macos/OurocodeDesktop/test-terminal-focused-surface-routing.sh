#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-focused-surface-routing.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

xcrun swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalFocusedSurfaceRouting.swift" \
  "$APP_ROOT/Tests/TerminalFocusedSurfaceRoutingFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'focusedSurfaceCoordinator()?.clearScreen()' "$HOST"
rg -Fq 'focusedSurfaceCoordinator()?.scrollToTop()' "$HOST"
rg -Fq 'focusedSurfaceCoordinator()?.scrollToBottom()' "$HOST"
rg -Fq 'let surface = self.focusedSurfaceCoordinator()' "$HOST"
rg -Fq 'self.focusedSurfaceCoordinator()?.revealFindMatch(match)' "$HOST"

echo "PASS: clear, scroll, and find share focused-pane routing"
