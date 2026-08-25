#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-shared-service-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SharedOuroborosService.swift" \
  "$APP_ROOT/Tests/SharedOuroborosServiceFixture.swift" \
  -o "$FIXTURE_BINARY"

cd "$APP_ROOT"
"$FIXTURE_BINARY"
