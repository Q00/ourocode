#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-detail-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosRunProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionDetailProjection.swift" \
  "$APP_ROOT/Tests/OuroborosSessionDetailProjectionFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
