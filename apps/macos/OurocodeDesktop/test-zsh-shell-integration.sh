#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-zsh-integration-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/ZshShellIntegration.swift" \
  "$APP_ROOT/Tests/ZshShellIntegrationFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
