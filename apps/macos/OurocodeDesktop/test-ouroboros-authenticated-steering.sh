#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-authenticated-steering.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosAuthenticatedSteering.swift" \
  "$APP_ROOT/Tests/OuroborosAuthenticatedSteeringFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

CLIENT_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
RAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
DETAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/MCPDetailOverlayView.swift"
rg -Fq 'ouroboros_session_signal' "$CLIENT_SOURCE"
rg -Fq 'OuroborosAuthenticatedSteeringV1.toolArguments' "$CLIENT_SOURCE"
rg -Fq 'func refreshSteering(' "$CLIENT_SOURCE"
rg -Fq 'receipt.canRefreshLifecycle' "$CLIENT_SOURCE"
rg -Fq 'self.resumeSteeringReceiptPolling(adapter: sessionAdapter)' "$RAIL_SOURCE"
rg -Fq 'OuroborosSteeringReceiptPollingPolicy.maximumAttempts' "$RAIL_SOURCE"
rg -Fq 'priorExecutionReceiptText(executionID:' "$RAIL_SOURCE"
rg -Fq 'steeringTargetKeyRetention.touch(key)' "$RAIL_SOURCE"
rg -Fq 'detailView.updateSteeringHistory(' "$RAIL_SOURCE"
rg -Fq 'contentStack.addArrangedSubview(steeringHistoryLabel)' "$DETAIL_SOURCE"
rg -Fq 'func updateSteeringHistory(_ receipts: [OuroborosSteeringReceipt])' "$DETAIL_SOURCE"
