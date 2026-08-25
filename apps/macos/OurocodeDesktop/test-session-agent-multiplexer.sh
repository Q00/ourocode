#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-agent-multiplexer.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

xcrun swiftc \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionAgentMultiplexerPolicy.swift" \
  "$APP_ROOT/Tests/SessionAgentMultiplexerFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

DETAIL="$APP_ROOT/Sources/OurocodeDesktop/MCPDetailOverlayView.swift"
RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
VIEW="$APP_ROOT/Sources/OurocodeDesktop/SessionAgentMultiplexerView.swift"

rg -Fq 'contentStack.addArrangedSubview(agentMultiplexer)' "$DETAIL"
rg -Fq 'visible.append(contentsOf: agentMultiplexer.keyViews)' "$DETAIL"
rg -Fq 'private func sendAgentSteering(nodeID: String, message rawMessage: String)' "$RAIL"
rg -Fq 'draftKey == exactDraftKey(for: node)' "$RAIL"
rg -Fq 'Headless cards are MCP steering, not terminal input.' "$VIEW"
rg -Fq '\(presentation.exactIdentity). Click the card or use \(presentation.primaryAction.label). \(presentation.steeringHelp)' "$VIEW"
if rg -Fq 'identity.isHidden = true' "$VIEW"; then
  echo "FAIL: exact steering identity is still hidden from sighted users" >&2
  exit 1
fi
rg -Fq 'summary.topAnchor.constraint(equalTo: identity.bottomAnchor' "$VIEW"
rg -Fq 'commandSelector == #selector(NSResponder.insertNewline(_:))' "$VIEW"
rg -Fq 'cardActivationButton.action = #selector(performPrimaryAction(_:))' "$VIEW"
rg -Fq 'Click the card or use' "$VIEW"
rg -Fq 'agentDiscoveryButton.action = #selector(retryAgentDiscovery(_:))' "$DETAIL"
rg -Fq 'self?.retrySelectedAgentDiscovery()' "$RAIL"
rg -Fq 'adapter.requestTargets(executionID: executionID, intentGeneration: generation)' "$RAIL"
rg -Fq 'No exact attempts are active right now. Refresh agents to check again' "$RAIL"
if rg -Fq 'field.target = self' "$VIEW"; then
  echo "FAIL: ending text-field editing can still submit steering" >&2
  exit 1
fi
rg -Fq 'queueButton.action = #selector(queue(_:))' "$VIEW"
if rg -Fq 'field.action = #selector(queue(_:))' "$VIEW"; then
  echo "FAIL: ending text-field editing can still submit steering" >&2
  exit 1
fi

# Draft persistence and submission must remain two separate callback paths.
rg -Fq 'onDraftChange?(id, field.stringValue)' "$VIEW"
rg -Fq 'onSubmit?(id, message)' "$VIEW"
if [[ $(rg -Fc 'queue(nil)' "$VIEW") -ne 1 ]]; then
  echo "FAIL: Return must queue the exact card draft exactly once" >&2
  exit 1
fi

echo "PASS: production group workspace exposes independently steerable exact-agent cards"
