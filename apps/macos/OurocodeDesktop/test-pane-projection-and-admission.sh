#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-pane-projection.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  -D OUROCODE_PANE_PROJECTION_FIXTURE \
  "$ROOT/Sources/OurocodeDesktop/NormalizedTerminalInput.swift" \
  "$ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$ROOT/Sources/OurocodeDesktop/BrokerClient.swift" \
  "$ROOT/Sources/OurocodeDesktop/PaneProjectionToken.swift" \
  "$ROOT/Sources/OurocodeDesktop/PaneSurfaceAdmissionPolicy.swift" \
  "$ROOT/Tests/PaneProjectionAndAdmissionFixture.swift" \
  -o "$TMP_DIR/pane-projection-fixture"

"$TMP_DIR/pane-projection-fixture"

cat > "$TMP_DIR/IndependentLedgerFixture.swift" <<'SWIFT'
import Foundation

@main
private enum IndependentLedgerFixture {
    static func main() {
        _ = PaneSurfaceAdmissionLedger()
    }
}
SWIFT

if swiftc \
  -parse-as-library \
  -warnings-as-errors \
  "$ROOT/Sources/OurocodeDesktop/PaneSurfaceAdmissionPolicy.swift" \
  "$TMP_DIR/IndependentLedgerFixture.swift" \
  -o "$TMP_DIR/independent-ledger-fixture" \
  2>"$TMP_DIR/independent-ledger-error.log"; then
  echo "Independent pane-surface ledgers must not compile" >&2
  exit 1
fi

if ! grep -q 'protection level' "$TMP_DIR/independent-ledger-error.log"; then
  echo "Independent-ledger negative fixture failed for an unexpected reason" >&2
  cat "$TMP_DIR/independent-ledger-error.log" >&2
  exit 1
fi

echo "PASS: independent pane-surface ledger construction is unavailable"
