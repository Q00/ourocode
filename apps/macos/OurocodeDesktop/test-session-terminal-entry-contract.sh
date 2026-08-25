#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-terminal-entry.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailPresentationPolicy.swift" \
  "$APP_ROOT/Tests/SessionTerminalEntryContractFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
HOST_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
MAIN_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

rg -Fq 'inspectSelectionIfNeeded(node)' "$RAIL_SOURCE"
rg -Fq 'outline.onPrimaryAction = { [weak self] nodeID in' "$RAIL_SOURCE"
rg -Fq 'override func accessibilityPerformPress() -> Bool' "$RAIL_SOURCE"
rg -Fq 'rowView.onAccessibilityPress = { [weak self] in' "$RAIL_SOURCE"
rg -Fq 'performAccessibilityPrimaryAction(nodeID: node.id)' "$RAIL_SOURCE"
rg -Fq 'performSelectedPrimarySessionAction(nodeID: node.id)' "$RAIL_SOURCE"
rg -Fq 'performPrimarySessionAction(node)' "$RAIL_SOURCE"
rg -Fq 'guard terminalActivationInFlightNodeID != node.id else { return }' "$RAIL_SOURCE"
rg -Fq 'SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(' "$RAIL_SOURCE"
rg -Fq 'performPrimarySessionAction(child)' "$RAIL_SOURCE"
rg -Fq 'case .openSession(let readOnly):' "$RAIL_SOURCE"
rg -Fq 'node.target == nil' "$RAIL_SOURCE"
rg -Fq 'runtime.sessionAdapter?.requestTargets(executionID: executionID)' "$RAIL_SOURCE"
rg -Fq 'SessionRailExpandablePolicy.resolve(' "$RAIL_SOURCE"
rg -Fq 'intentGeneration: requestGeneration' "$RAIL_SOURCE"
rg -Fq 'showDetail(nodeID: node.id)' "$RAIL_SOURCE"
rg -Fq 'applySelectionState(node, announce: announce)' "$RAIL_SOURCE"
rg -Fq 'sessionAdapter.onTargetDiscovery = { [weak self, weak runtime] result in' "$RAIL_SOURCE"
rg -Fq 'pendingTerminalActivationGeneration = nil' "$RAIL_SOURCE"
rg -Fq 'outcome: targets.isEmpty ? .empty : .discovered(targets.count)' \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
rg -Fq 'cancelTargetDiscoveries(reason: "Session observation stopped")' \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosMCPClient.swift"
if rg -Fq 'activateSelectionIfNeeded' "$RAIL_SOURCE"; then
  echo "FAIL: selection still owns terminal activation" >&2
  exit 1
fi
rg -Fq 'let requestIsCurrent = { [weak self] in' "$RAIL_SOURCE"
rg -Fq 'requestIsCurrent: requestIsCurrent' "$MAIN_SOURCE"
rg -Fq 'let activeWaiters = waiters.filter { $0.requestIsCurrent() }' "$HOST_SOURCE"
rg -Fq 'self.requestGeneration == activationGeneration' "$RAIL_SOURCE"
rg -Fq 'broker.list { [weak self] result in' "$HOST_SOURCE"
rg -Fq 'let expectedBindingsRevision = advertisedSessionBindingsRevision' "$HOST_SOURCE"
rg -Fq 'TerminalSessionBindingRevisionPolicy.accepts(' "$HOST_SOURCE"
rg -Fq 'currentBindings: self.advertisedSessionBindings' "$HOST_SOURCE"
rg -Fq 'private func openSessionSurfaceResolution(' "$HOST_SOURCE"
rg -Fq 'snapshot.leaves.map(\.terminalID)' "$HOST_SOURCE"
rg -Fq 'private func activateOpenSessionSurface(' "$HOST_SOURCE"
rg -Fq 'try workspace.focus(' "$HOST_SOURCE"
rg -Fq 'additionalPaneRuntimes[terminalID] != nil' "$HOST_SOURCE"
rg -Fq 'if let existingResult = self.activateOpenSessionSurface(' "$HOST_SOURCE"
rg -Fq 'TerminalSessionBrokerAdoptionPolicy.accepts(' "$HOST_SOURCE"
rg -Fq ').isOpen,' "$HOST_SOURCE"
rg -Fq 'self.closedViews.removeAll { $0.terminalID == terminalID }' "$HOST_SOURCE"
rg -Fq 'brokerTerminal: terminal' "$HOST_SOURCE"
rg -Fq 'self.showTab(at: self.tabs.count - 1)' "$HOST_SOURCE"
rg -Fq 'completion: completion' "$MAIN_SOURCE"

echo "PASS: session primary click opens honest detail or exact broker terminal wiring"
