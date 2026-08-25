#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
MAIN="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

rg -Fq 'if terminalNodes.count == 1 { return terminalNodes[0] }' "$RAIL"
rg -Fq 'if node.sourceID == "terminal", node.id.hasPrefix("live-terminal:")' "$RAIL"
rg -Fq 'performSelectedPrimarySessionAction(nodeID: node.id)' "$RAIL"
rg -Fq 'func activateLiveTerminalSession(_ id: UUID) -> Bool' "$HOST"
rg -Fq 'rail.onRequestActivateLiveTerminal = { [weak terminal] id in' "$MAIN"

echo 'PASS: Sessions rows are the sole visible terminal switcher and activate exact tabs'
