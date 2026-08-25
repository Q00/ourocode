#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourocode-lease-settlement.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalLeaseSettlementPolicy.swift" \
  "$APP_ROOT/Tests/TerminalLeaseSettlementPolicyFixture.swift" \
  -o "$TMP_DIR/lease-settlement-fixture"
"$TMP_DIR/lease-settlement-fixture"

rg -Fq 'TerminalLeaseSettlementPolicy.shouldResumePendingCommit(' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSurfaceCoordinator.swift"

