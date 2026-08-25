#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="$(mktemp -d)/ourocode-session-message-gateway-client-fixture"

xcrun swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$APP_ROOT/Tests/SessionMessageGatewayClientFixture.swift" \
  -o "$OUTPUT"

"$OUTPUT"
