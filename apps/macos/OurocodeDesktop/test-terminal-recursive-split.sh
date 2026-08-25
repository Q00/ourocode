#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
WORKSPACE="$APP_ROOT/Sources/OurocodeDesktop/TerminalWorkspaceTab.swift"
MENU="$APP_ROOT/Sources/OurocodeDesktop/main.swift"

# The native host must consume the bounded recursive model, not reinstate the
# historical one-to-two pane gate.
if rg -Fq 'workspace.paneCount == 1' "$HOST"; then
  echo "Terminal host still hard-codes the old two-pane ceiling" >&2
  exit 1
fi
rg -Fq 'TerminalSplitLayoutConfiguration.maximumProductionLeaves' "$HOST"
rg -Fq 'snapshot.presentationLeaves' "$HOST"
rg -Fq '@objc func closeFocusedPane' "$HOST"
rg -Fq '@objc func focusPaneLeft' "$HOST"
rg -Fq '@objc func focusPaneRight' "$HOST"
rg -Fq '@objc func focusPaneUp' "$HOST"
rg -Fq '@objc func focusPaneDown' "$HOST"
rg -Fq '@objc func equalizePanes' "$HOST"
rg -Fq '@objc func toggleMaximizeFocusedPane' "$HOST"
rg -Fq 'TerminalPaneLimitFeedbackPolicy.message' "$HOST"
rg -Fq 'notification: .announcementRequested' "$HOST"
rg -Fq 'TerminalPaneLimitFeedbackPolicy.shouldAnnounce' "$HOST"
rg -Fq 'isAtPaneLimit' "$HOST"
rg -Fq 'preparePrimaryPromotion' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalPaneRuntime.swift"
rg -Fq 'commitPrimaryPromotion' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalPaneRuntime.swift"
rg -Fq 'detachAfterInputBarrier(oldAttachment)' "$HOST"
rg -Fq 'try workspace.closePane(' "$HOST"
rg -Fq 'TerminalPaneTerminationPolicy.terminationTarget(' "$HOST"
rg -Fq 'self.broker.terminate(terminalID: terminationTarget)' "$HOST"

rg -Fq 'static let maximumProductionLeaves = 4' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSplitLayoutBridge.swift"
rg -Fq 'let presentationLeaves: [TerminalSplitLeafGeometry]' "$WORKSPACE"
rg -Fq 'func toggleMaximizeFocused' "$WORKSPACE"
rg -Fq 'func equalize(expectedRevision:' "$WORKSPACE"

for title in \
  'Close Focused Pane' \
  'Equalize Panes' \
  'Maximize / Restore Focused Pane' \
  'Focus Pane Left' \
  'Focus Pane Right' \
  'Focus Pane Up' \
  'Focus Pane Down'; do
  rg -Fq "withTitle: \"$title\"" "$MENU"
done

echo "PASS: native host and command surface consume the bounded recursive four-pane contract"
