#!/bin/zsh
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_ROOT="${TMPDIR:-/tmp}/ourocode-terminal-session-binding"
mkdir -p "$BUILD_ROOT"

swiftc \
  -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSessionBinding.swift" \
  "$APP_ROOT/Tests/TerminalSessionBindingFixture.swift" \
  -o "$BUILD_ROOT/fixture"
"$BUILD_ROOT/fixture"
