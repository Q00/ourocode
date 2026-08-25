#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-pane-steering.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSessionBinding.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailPresentationPolicy.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionPaneSteeringFocus.swift" \
  "$APP_ROOT/Tests/SessionPaneSteeringFocusFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

HOST_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
RAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
MAIN_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

rg -Fq 'var onFocusedSessionPaneChange: ((SessionPaneSteeringFocus?) -> Void)?' "$HOST_SOURCE"
rg -Fq 'SessionPaneSteeringFocusPolicy.resolve(' "$HOST_SOURCE"
rg -Fq 'publishFocusedSessionPane()' "$HOST_SOURCE"
rg -Fq 'func focusSessionPane(_ focus: SessionPaneSteeringFocus?)' "$RAIL_SOURCE"
rg -Fq '@objc func focusSteeringComposer(_ sender: Any?)' "$RAIL_SOURCE"
rg -Fq 'node.kind == .sessionLeaf' "$RAIL_SOURCE"
rg -Fq 'focusedSessionPane?.leaf != selectedTarget?.sessionIdentity' "$RAIL_SOURCE"
rg -Fq 'terminal.onFocusedSessionPaneChange = { [weak rail] focus in' "$MAIN_SOURCE"
rg -Fq 'rail?.focusSessionPane(focus)' "$MAIN_SOURCE"
rg -Fq 'withTitle: "Message Focused Agent…"' "$MAIN_SOURCE"
rg -Fq 'focusAgentComposer.keyEquivalentModifierMask = [.command, .option]' "$MAIN_SOURCE"

echo "PASS: focused pane is wired to exact session-leaf steering without sharing terminal input"
