#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-shared-mcp-migration-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SharedOuroborosService.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SharedMCPHostMigrationPlanner.swift" \
  "$APP_ROOT/Tests/SharedMCPHostMigrationPlannerFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
