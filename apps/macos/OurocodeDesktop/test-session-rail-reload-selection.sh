#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp "${TMPDIR:-/tmp}/ourocode-session-reload-selection.XXXXXX")
trap 'rm -f "$FIXTURE_BINARY"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailDetailFocusRestoration.swift" \
  "$APP_ROOT/Tests/SessionRailReloadSelectionFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
rg -Fq "outlineSelectionChangeResolution" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "case .restoreSemanticSelection:" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "restoreSemanticOutlineSelection()" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "private(set) var isHandlingExplicitSelectionInput = false" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "outline.isHandlingExplicitSelectionInput" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
if rg -Fq "NSApp.currentEvent" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"; then
  echo "FAIL: stale NSApp.currentEvent cannot prove explicit outline input" >&2
  exit 1
fi
rg -Fq "isOutlineReloadSettling = true" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
sed -n '/private func activateMode(/,/private func shouldOpenSingleLiveSession/p' \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift" \
  | rg -Fq "selectedNodeID = nil"
rg -Fq "let stableSelectedNodeID = selectedNodeID" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "rebuildTree(captureCurrentExpansion: false)" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "applySelectionState(node, announce: false)" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "detailVisible," \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "detailUsesSessionWorkspace," \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "Real pointer/accessibility actions still flow" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
rg -Fq "detailOwnedFocusAtDismissal" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
echo "PASS: production rail restores by stable ID without mode leakage, target-refresh churn, or transient workspace dismissal"
