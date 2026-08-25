#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
RAIL="$APP_ROOT/Sources/OurocodeDesktop/SessionRailViewController.swift"
DETAIL="$APP_ROOT/Sources/OurocodeDesktop/MCPDetailOverlayView.swift"

rg -Fq "private var detailPopover: NSPopover?" "$RAIL"
rg -Fq "detailView.configureReadingSurface(width: readingWidth)" "$RAIL"
rg -Fq "popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)" "$RAIL"
rg -Fq "popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion" "$RAIL"
rg -Fq "expansionIDs.formUnion" "$RAIL"
rg -Fq "func configureReadingSurface(width: CGFloat)" "$DETAIL"
rg -Fq "Routing receipts not advertised" "$RAIL"
rg -Fq 'private weak var detailPreviousFirstResponder: NSResponder?' "$RAIL"
rg -Fq 'detailView.window?.makeFirstResponder(detailView)' "$RAIL"
rg -Fq 'restoreDetailFocus(previousResponder: previousResponder, nodeID: previousNodeID)' "$RAIL"
rg -Fq 'window.makeFirstResponder(outline)' "$RAIL"
if [[ $(rg -Fc 'NSAccessibility.post(element: view, notification: .layoutChanged)' "$RAIL") -lt 2 ]]; then
  echo "FAIL: opening and closing detail must both update the VoiceOver layout" >&2
  exit 1
fi
rg -Fq 'override func cancelOperation(_ sender: Any?)' "$DETAIL"
rg -Fq 'setAccessibilityLabel("Close details")' "$DETAIL"
rg -Fq 'systemSymbolName: "xmark.circle.fill"' "$DETAIL"
rg -Fq 'closeButton.toolTip = "Close Details (Esc)"' "$DETAIL"
rg -Fq 'titleLabel.lineBreakMode = .byWordWrapping' "$DETAIL"
rg -Fq 'contentStack.alignment = .leading' "$DETAIL"
rg -Fq 'recentScroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor)' "$DETAIL"
rg -Fq 'return "Expand for agent runs"' "$DETAIL"
rg -Fq 'recentHeightConstraint?.constant = 132' "$DETAIL"
rg -Fq 'usesExternalSize ? 360 : 320' "$DETAIL"
rg -Fq 'bodyParagraph.paragraphSpacing = 14' "$DETAIL"
rg -Fq 'NSAccessibilityCustomAction(name: "Close details")' "$DETAIL"
rg -Fq 'Press Escape or activate Close details to return to Connections.' "$DETAIL"
rg -Fq 'NSAccessibility.post(element: self, notification: .valueChanged)' "$DETAIL"
rg -Fq 'NSAccessibility.post(element: self, notification: .layoutChanged)' "$DETAIL"
rg -Fq 'notification: .announcementRequested' "$DETAIL"
echo "PASS: adaptive session detail preserves keyboard focus and announces accessible state changes"
