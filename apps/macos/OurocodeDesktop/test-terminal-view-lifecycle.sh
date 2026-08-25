#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-terminal-lifecycle.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT HUP INT TERM

swiftc \
  -warnings-as-errors \
  "$ROOT/Sources/OurocodeDesktop/TerminalViewLifecyclePolicy.swift" \
  "$ROOT/Tests/TerminalViewLifecyclePolicyFixture.swift" \
  -o "$TMP_DIR/terminal-view-lifecycle-fixture"

"$TMP_DIR/terminal-view-lifecycle-fixture"
