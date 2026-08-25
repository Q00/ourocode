#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-detail-activation.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosRunProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionDetailProjection.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MCPSessionActivation.swift" \
  "$APP_ROOT/Tests/MCPSessionActivationFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
CLIENT_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
rg -Fq 'let exactIdentity = node.kind == .sessionLeaf ? node.sessionIdentity : nil' "$RAIL_SOURCE"
rg -Fq 'activeSessionActivation.scopeID == exactIdentity?.scopeID' "$RAIL_SOURCE"
rg -Fq 'activation.scopeID == (node.kind == .sessionLeaf ? node.sessionIdentity?.scopeID : nil)' "$RAIL_SOURCE"
rg -Fq 'exactAttempt: exactAttemptIdentity.map {' "$RAIL_SOURCE"
rg -Fq 'guard self.activeSessionActivation == nil else { return }' "$RAIL_SOURCE"
rg -Fq 'guard !activation.requiresExactAttempt,' "$CLIENT_SOURCE"
rg -Fq 'attemptFilter: activation.attemptFilter' "$CLIENT_SOURCE"

echo "PASS: rail and adapter preserve exact leaf identity and keep run projection group-only"
