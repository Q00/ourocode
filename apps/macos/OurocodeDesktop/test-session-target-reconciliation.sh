#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-target-snapshot.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

xcrun swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTargetOverlayPolicy.swift" \
  "$APP_ROOT/Tests/OuroborosSessionTargetSnapshotFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

CLIENT="$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
rg -Fq 'OuroborosSessionTargetSnapshotPolicy.deduplicated(keyedTargets)' "$CLIENT"
rg -Fq 'self.replaceDiscoveredTargets(' "$CLIENT"
rg -Fq 'baseTabsRevokingTargetOverlays(group.tabs)' "$CLIENT"
rg -Fq 'OuroborosSessionTargetSnapshotPolicy.isDiscoveredAttemptID(existing.id)' "$CLIENT"
rg -Fq 'Target discovery returned conflicting duplicate attempt identities' "$CLIENT"
rg -Fq 'clearAllTargets(preservingExecutionID: activeSessionDetail?.executionID)' "$CLIENT"
rg -Fq 'revalidateActiveTargetsIfNeeded()' "$CLIENT"
rg -Fq 'let retainedTabs: [OuroborosSessionTab]' "$CLIENT"
rg -Fq 'tabs: retainedTabs' "$CLIENT"

echo "PASS: MCP target discovery snapshot-replaces attempts and keeps an open multiplexer actionable across metadata polls"
