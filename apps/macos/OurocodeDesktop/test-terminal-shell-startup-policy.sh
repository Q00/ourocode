#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalShellStartupPolicy.swift" \
  "$APP_ROOT/Tests/TerminalShellStartupPolicyFixture.swift" \
  -o "$TMP_DIR/terminal-shell-startup-policy"
"$TMP_DIR/terminal-shell-startup-policy"

HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Uq 'appendTab\(\n[[:space:]]*initialCommand: nil,\n[[:space:]]*shellLaunchMode: \.accountZsh,' "$HOST"
rg -Fq 'tab.shellLaunchMode == .accountZsh' "$HOST"

echo "PASS: new tabs bypass a process-wide shell override and launch account zsh"
