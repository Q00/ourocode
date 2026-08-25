#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-surface-admission.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc \
  -parse-as-library \
  -warnings-as-errors \
  "$ROOT/Sources/OurocodeDesktop/PaneSurfaceAdmissionPolicy.swift" \
  "$ROOT/Tests/PaneSurfaceAdmissionLedgerFixture.swift" \
  -o "$TMP_DIR/pane-surface-admission-fixture"

"$TMP_DIR/pane-surface-admission-fixture"

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
