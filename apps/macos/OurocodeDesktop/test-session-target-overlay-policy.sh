#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-target-overlay-policy.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTargetOverlayPolicy.swift" \
  "$APP_ROOT/Tests/OuroborosSessionTargetOverlayPolicyFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

CLIENT_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
rg -Fq 'OuroborosSessionTargetOverlayPolicy.revoke(' "$CLIENT_SOURCE"
rg -Fq 'identity: &base.sessionIdentity' "$CLIENT_SOURCE"
rg -Fq 'surface: &base.surface' "$CLIENT_SOURCE"
rg -Fq 'OuroborosSessionTargetSnapshotPolicy.isDiscoveredAttemptID(existing.id)' "$CLIENT_SOURCE"
