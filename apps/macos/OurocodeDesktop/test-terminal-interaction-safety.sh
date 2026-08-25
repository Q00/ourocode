#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
COORDINATOR="$APP_ROOT/Sources/OurocodeDesktop/TerminalSurfaceCoordinator.swift"
TERMINAL="$APP_ROOT/Sources/OurocodeDesktop/OuroMetalTerminalView.swift"

# A bounded visible-tab projection may reuse native buttons, but it must tell
# accessibility clients that the layout changed and restore keyboard focus by
# semantic session identity after the projection moves.
rg -Fq 'NSAccessibility.post(element: tabStrip, notification: .layoutChanged)' "$HOST"
rg -Fq 'var representedTabID: UUID?' "$HOST"
rg -Fq 'requestGeneration: projectionGeneration' "$HOST"
rg -Fq 'rebuildTabControl(preserveFocusedTab: false)' "$HOST"
rg -Fq 'self.view.window?.makeFirstResponder(self.tabButtons[focusedSlot])' "$HOST"

# Recognized OSC 8 links are consumed even when Launch Services cannot open
# them, so a failed open cannot fall through into terminal mouse input.
rg -Fq 'let opened = NSWorkspace.shared.open(url)' "$COORDINATOR"
rg -Fq 'if !opened { NSSound.beep() }' "$COORDINATOR"
if sed -n '/func terminalView(_ view: OuroMetalTerminalView, openHyperlinkAt/,/^    }/p' \
    "$COORDINATOR" | rg -Fq 'return NSWorkspace.shared.open(url)'; then
  echo "OSC 8 handler still leaks failed opens into terminal input" >&2
  exit 1
fi

# VoiceOver must announce the real coalesced bell count, not a literal token.
rg -Fq '.announcement: count == 1 ? "Terminal bell" : "\(count) terminal bells",' "$TERMINAL"
if rg -Fq '"(count) terminal bells"' "$TERMINAL"; then
  echo "Bell announcement still contains a literal count token" >&2
  exit 1
fi

# A drawable queued for the old tab can present after a newer recovery has
# started. Its callback must reject the stale transition generation before it
# clears the shared in-flight bit or opens any input route.
PRESENTATION_BODY=$(sed -n \
  '/private func completeGhosttyPresentation(/,/private func activateGhosttyInput(/p' \
  "$HOST")
GENERATION_GUARD_LINE=$(print -r -- "$PRESENTATION_BODY" | \
  rg -n -m1 -F 'guard transitionGeneration == generation else { return }' | cut -d: -f1)
TRANSITION_CLEAR_LINE=$(print -r -- "$PRESENTATION_BODY" | \
  rg -n -m1 -F 'transitionInFlight = false' | cut -d: -f1)
if [[ -z "$GENERATION_GUARD_LINE" || -z "$TRANSITION_CLEAR_LINE" \
    || "$GENERATION_GUARD_LINE" -ge "$TRANSITION_CLEAR_LINE" ]]; then
  echo "Stale first-present can clear a newer terminal recovery" >&2
  exit 1
fi

# Once the exact first frame and input lease are active, optional OSC 133
# metadata must not re-lock the terminal from the focus restoration path.
FOCUS_BODY=$(sed -n \
  '/private func focusMirrorWhenReady()/,/private func unlockInputIfSupported/p' \
  "$HOST")
print -r -- "$FOCUS_BODY" | rg -Fq 'semanticPromptReadiness.activationIssued'
if print -r -- "$FOCUS_BODY" | rg -Fq \
    'semanticPromptReadiness.semanticRequirementSatisfied'; then
  echo "Focus restoration still re-locks input behind optional OSC 133 metadata" >&2
  exit 1
fi

echo "PASS: tab AX identity, OSC 8, bell, and stale first-present are fail-safe"
