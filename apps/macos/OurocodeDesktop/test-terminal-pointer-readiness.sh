#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
COORDINATOR="$APP_ROOT/Sources/OurocodeDesktop/TerminalSurfaceCoordinator.swift"
OWNERSHIP_FIXTURE="$APP_ROOT/Tests/TerminalPointerReadinessOwnershipFixture.swift"

rg -Fq 'var onPointerReady: (() -> Void)?' "$COORDINATOR"
rg -Fq 'private var pointerReadinessNoticePending = false' "$COORDINATOR"
rg -Fq 'private var pointerGeometryRequestEpoch: UInt64?' "$COORDINATOR"
rg -Fq 'private var pointerReadinessRepairPending = false' "$COORDINATOR"
rg -Fq 'func requestPointerReadyNotice()' "$COORDINATOR"
rg -Fq 'pointerGeometryAcknowledgedEpoch == activeLayoutEpoch' "$COORDINATOR"
rg -Fq 'if pointerResizeBarrier == nil, pointerReadinessNoticePending {' "$COORDINATOR"
rg -Fq 'self.compatibilityLabel.stringValue = "Pointer paused · syncing"' "$HOST"
rg -Fq 'self.compatibilityLabel.stringValue == "Pointer paused · syncing"' "$HOST"
rg -Fq 'surface.requestPointerReadyNotice()' "$HOST"
rg -Fq 'surface.onLockedInteraction = { [weak self, weak surface]' "$HOST"
rg -Fq 'self.compatibilityLabel.isHidden = true' "$HOST"
# The repair gate is passed to the policy as an explicit state value. Keep the
# assertion coupled to that contract instead of a formatting-specific inline
# negation, so refactors cannot make the test fail while preserving behavior.
rg -Fq 'repairPending: pointerReadinessRepairPending' "$COORDINATOR"
rg -Fq 'candidateLayoutEpoch = prepared.terminal.layoutEpoch' "$COORDINATOR"

cancel_body="$(sed -n '/private func cancelAllPointerGestures()/,/^    }/p' "$COORDINATOR")"
if print -r -- "$cancel_body" | rg -Fq 'pointerGeometryAcknowledgedEpoch = nil'; then
  echo "Focus loss still invalidates unchanged pointer geometry" >&2
  exit 1
fi

if rg -Fq 'Pointer routing unavailable' "$HOST"; then
  echo "Terminal still presents a transient geometry sync as a permanent capability failure" >&2
  exit 1
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourocode-pointer-readiness.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM
swiftc -warnings-as-errors "$OWNERSHIP_FIXTURE" -o "$TMP_DIR/ownership-fixture"
"$TMP_DIR/ownership-fixture"

echo "PASS: pointer geometry sync uses a level-triggered readiness notice"
