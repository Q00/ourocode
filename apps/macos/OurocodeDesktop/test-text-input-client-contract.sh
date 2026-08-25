#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp /private/tmp/ourocode-text-input-client.XXXXXX)
trap 'rm -f -- "$FIXTURE_BINARY"' EXIT

swiftc -warnings-as-errors -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroTerminalMarkedTextState.swift" \
  "$APP_ROOT/Tests/OuroTextInputClientContractFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"

HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
TERMINAL="$APP_ROOT/Sources/OurocodeDesktop/AccessibleTerminalView.swift"
rg -Fq 'terminal.commitMarkedTextForBoundary()' "$HOST"
rg -Fq 'inputContext?.discardMarkedText()' "$TERMINAL"

echo "PASS: compatibility IME boundary clears AppKit state before forwarding the key"
