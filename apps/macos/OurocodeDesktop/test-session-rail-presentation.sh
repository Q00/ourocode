#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-rail-presentation.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailPresentationPolicy.swift" \
  "$APP_ROOT/Tests/SessionRailPresentationFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq 'SessionRailExpansionPolicy.requiredExpansionIDs(' "$RAIL"
rg -Fq 'isLiveBucket: { _ in false }' "$RAIL"
rg -Fq 'selectedNodeID: stableSelectedNodeID' "$RAIL"
rg -Fq 'children.append(contentsOf: makeSessionDestinations(' "$RAIL"
rg -Fq 'liveTerminalNodes(projection.terminals)' "$RAIL"
