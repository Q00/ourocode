#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-mcp-v2-registry-fixture.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors -D MCP_V2_CATALOG_STANDALONE \
  "$APP_ROOT/Sources/OurocodeDesktop/MCPSourceRegistry.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MCPV2CatalogAdapter.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SharedCUAMCPAdapter.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/LocalMCPSourceDescriptor.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MCPV2CatalogDemoFixture.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/DesktopMCPSourceRegistry.swift" \
  "$APP_ROOT/Tests/MCPV2SourceRegistryFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"
