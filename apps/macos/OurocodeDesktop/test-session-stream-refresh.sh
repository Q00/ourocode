#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-stream.XXXXXX")
trap 'rm -f "$BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionDetailProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosRunProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionStreamRefreshPolicy.swift" \
  "$APP_ROOT/Tests/SessionStreamRefreshPolicyFixture.swift" \
  -o "$BINARY"
"$BINARY"
