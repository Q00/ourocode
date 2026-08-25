#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-broker-flow-control.XXXXXX")
CLIENT_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-broker-client-flow-control.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY" "$CLIENT_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$APP_ROOT/Tests/BrokerFlowControlSmoke.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"

swiftc -O \
  "$APP_ROOT/Sources/OurocodeDesktop/NormalizedTerminalInput.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift" \
  "$APP_ROOT/Tests/BrokerClientV4Smoke.swift" \
  -o "$CLIENT_BINARY"

"$CLIENT_BINARY"
rg -Fq "maximumRetainedEventBytes = 2 * 1_024 * 1_024" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift"
rg -Fq "maximumAttachmentEventBytes = 256 * 1_024" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift"
rg -Fq "finishDeferredDetachIfReady" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift"
rg -Fq "Terminal output exceeded the bounded UI delivery mailbox" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift"
echo "PASS: production broker delivery uses bounded per-terminal/global mailboxes"
