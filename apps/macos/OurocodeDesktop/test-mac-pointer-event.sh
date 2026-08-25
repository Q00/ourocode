#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp /private/tmp/ourocode-mac-pointer-event.XXXXXX)
trap 'rm -f -- "$FIXTURE_BINARY"' EXIT

swiftc -warnings-as-errors -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$APP_ROOT/Sources/OurocodeDesktop/MacPointerEvent.swift" \
  "$APP_ROOT/Tests/MacPointerEventFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
