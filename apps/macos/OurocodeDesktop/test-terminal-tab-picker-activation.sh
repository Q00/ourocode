#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp /private/tmp/ourocode-tab-picker-activation.XXXXXX)
trap 'rm -f -- "$FIXTURE_BINARY"' EXIT

swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalTabPickerActivation.swift" \
  "$APP_ROOT/Tests/TerminalTabPickerActivationFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
