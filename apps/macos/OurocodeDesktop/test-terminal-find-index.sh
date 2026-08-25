#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-find-index-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalFindIndex.swift" \
  "$APP_ROOT/Tests/TerminalFindIndexFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
