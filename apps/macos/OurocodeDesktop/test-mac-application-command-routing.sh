#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-app-command-routing.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalTypographyShortcut.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MacApplicationCommandRouting.swift" \
  "$APP_ROOT/Tests/MacApplicationCommandRoutingFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

MAIN_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/main.swift"
HOST_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'self.dispatchTypography(action, preferredTerminal: terminal)' "$MAIN_SOURCE"
rg -Fq 'action: #selector(increaseApplicationTextSize(_:))' "$MAIN_SOURCE"
rg -Fq 'action: #selector(decreaseApplicationTextSize(_:))' "$MAIN_SOURCE"
rg -Fq 'action: #selector(resetApplicationTextSize(_:))' "$MAIN_SOURCE"
rg -Fq 'terminalController?.isTypographyActionEnabled(.reset)' "$MAIN_SOURCE"
rg -Fq 'presentTerminalFontSizeHUD(status: "Default")' "$HOST_SOURCE"
if rg -Fq 'increaseText.target = terminal' "$MAIN_SOURCE" \
    || rg -Fq 'decreaseText.target = terminal' "$MAIN_SOURCE" \
    || rg -Fq 'actualSize.target = terminal' "$MAIN_SOURCE"; then
  echo "FAIL: View menu bypasses the shared application typography dispatcher" >&2
  exit 1
fi
echo "PASS: event monitor and View menu share one validated typography dispatcher"
