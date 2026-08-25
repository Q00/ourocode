#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-semantic-activation.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailSemanticActivation.swift" \
  "$APP_ROOT/Tests/SessionRailSemanticActivationFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq 'NSAccessibility.screenRect(fromView: self, rect: bounds)' "$RAIL"
rg -Fq 'SessionRailSemanticActivation.accessibilityIdentifier(nodeID: node.id)' "$RAIL"
rg -Fq 'performAccessibilityPrimaryAction(nodeID: node.id)' "$RAIL"
rg -Fq 'performSelectedPrimarySessionAction(nodeID: nodeID)' "$RAIL"
rg -Fq 'guard let node = resolveCurrentActivationNode(nodeID: nodeID)' "$RAIL"

echo "PASS: production SessionRail exposes one full-frame semantic AX target and ID-routed Return"
