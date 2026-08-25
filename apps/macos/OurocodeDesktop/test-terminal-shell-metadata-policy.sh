#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourocode-shell-metadata.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalShellMetadataPolicy.swift" \
  "$APP_ROOT/Tests/TerminalShellMetadataPolicyFixture.swift" \
  -o "$TMP_DIR/fixture"
"$TMP_DIR/fixture"
