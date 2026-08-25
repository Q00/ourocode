#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-mcp-catalog-search.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailPresentationPolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MCPCatalogSearchPolicy.swift" \
  "$APP_ROOT/Tests/MCPCatalogSearchPolicyFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
rg -Fq 'private let catalogSearchField = NSSearchField(string: "")' \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq 'DispatchQueue.main.asyncAfter(' \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq 'catalogSearchRetainedNodeID' \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
echo "PASS: production Connections rail uses native debounced MCP search"
