#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-focused-agent-ax.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSessionBinding.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionPaneSteeringFocus.swift" \
  "$APP_ROOT/Tests/SessionFocusedAgentKeyboardAccessibilityFixture.swift" \
  -o "$FIXTURE_BINARY"
"$FIXTURE_BINARY"

RAIL_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
MAIN_SOURCE="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

rg -Fq 'SessionFocusedAgentComposerPolicy.resolve(' "$RAIL_SOURCE"
rg -Fq 'showNotice(reason)' "$RAIL_SOURCE"
rg -Fq 'notification: .announcementRequested' "$RAIL_SOURCE"
rg -Fq '.announcement: reason' "$RAIL_SOURCE"
rg -Fq 'withTitle: "Message Focused Agent…"' "$MAIN_SOURCE"
rg -Fq 'focusAgentComposer.keyEquivalentModifierMask = [.command, .option]' "$MAIN_SOURCE"
rg -Fq 'railController?.focusSteeringComposer(sender)' "$MAIN_SOURCE"

echo "PASS: Command-Option-Return exposes visible and accessibility feedback without global fallback"
