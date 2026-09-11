#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourocode-tab-focus.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalTabFocusRestoration.swift" \
  "$APP_ROOT/Tests/TerminalTabFocusRestorationFixture.swift" \
  -o "$BUILD_DIR/fixture"

"$BUILD_DIR/fixture"

HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'pendingTerminalFocusTabID = tab.id' "$HOST"
rg -Fq 'terminalFocusPending: self.pendingTerminalFocusTabID != nil' "$HOST"
rg -Fq 'self.pendingTerminalFocusTabID = nil' "$HOST"

echo "PASS: explicit tab selection keeps terminal focus ownership through attachment"
