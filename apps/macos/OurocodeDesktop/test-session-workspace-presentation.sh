#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
MAIN="$APP_ROOT/Sources/OurocodeDesktop/main.swift"
RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
DETAIL="$APP_ROOT/Sources/OurocodeDesktop/MCPDetailOverlayView.swift"

for source in "$MAIN" "$RAIL" "$HOST" "$DETAIL"; do
  [[ -f "$source" ]] || { echo "FAIL: missing $source" >&2; exit 1; }
done

rg -Fq 'rail.onRequestPresentSessionWorkspace' "$MAIN"
rg -Fq 'terminal?.presentSessionWorkspace(detail)' "$MAIN"
rg -Fq 'rail.onRequestDismissSessionWorkspace' "$MAIN"
rg -Fq 'terminal?.dismissSessionWorkspace(detail)' "$MAIN"

rg -Fq 'detailUsesSessionWorkspace = true' "$RAIL"
rg -Fq 'onRequestDismissSessionWorkspace?(detailView)' "$RAIL"
rg -Fq 'if isSession, let presentWorkspace = onRequestPresentSessionWorkspace' "$RAIL"

rg -Fq 'func presentSessionWorkspace(_ content: MCPDetailOverlayView)' "$HOST"
rg -Fq 'content.configureSessionWorkspace()' "$HOST"
rg -Fq 'content.widthAnchor.constraint(lessThanOrEqualToConstant: 960)' "$HOST"
rg -Fq 'terminalContainer.setAccessibilityHidden(true)' "$HOST"
rg -Fq 'terminalContainer.setAccessibilityHidden(false)' "$HOST"
rg -Fq 'sessionWorkspaceContent?.onClose?()' "$HOST"

rg -Fq 'func configureSessionWorkspace()' "$DETAIL"
rg -Fq 'updateRecentEvents(currentRecentPresentation)' "$DETAIL"
rg -Fq '? "Read-only history"' "$DETAIL"
rg -Fq ': "Live session · Streaming"' "$DETAIL"
rg -Fq 'case .unavailable(let reason):' "$DETAIL"
rg -Fq 'sourceTopConstraint?.constant = 52' "$DETAIL"
rg -Fq 'backButton.keyEquivalent = "\u{1b}"' "$DETAIL"
rg -Fq 'NSAccessibilityCustomAction(name: "Back to Sessions")' "$DETAIL"
rg -Fq 'Press Escape or choose Back to Sessions to return to the Sessions list.' "$DETAIL"
rg -Fq 'recentText.setAccessibilityRole(.staticText)' "$DETAIL"
rg -Fq 'func updateWorkspaceKeyLoop()' "$DETAIL"
rg -Fq 'visible.append(composerField)' "$DETAIL"
rg -Fq 'visible.append(composerButton)' "$DETAIL"
rg -Fq 'view.nextKeyView = next' "$DETAIL"
rg -Fq 'SessionStreamRefreshPolicy.shouldAutoFollow' "$DETAIL"

[[ ! -e "$APP_ROOT/Sources/OurocodeDesktop/SessionActivityWorkspaceViewController.swift" ]]
[[ ! -e "$APP_ROOT/Sources/OurocodeDesktop/SessionWorkspacePresentationPolicy.swift" ]]
[[ ! -e "$APP_ROOT/Tests/SessionActivityWorkspaceFixture.swift" ]]
[[ ! -e "$APP_ROOT/test-session-activity-workspace.sh" ]]

echo "PASS: headless sessions use one accessible central workspace and never invent terminal authority"
