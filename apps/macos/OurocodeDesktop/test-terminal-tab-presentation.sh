#!/bin/zsh
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$APP_ROOT/.build/test-terminal-tab-presentation"
mkdir -p "$BUILD_DIR"

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/OuroborosSessionTerminalIdentity.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalSessionBinding.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalTabPresentation.swift" \
  "$APP_ROOT/Tests/TerminalTabPresentationFixture.swift" \
  -o "$BUILD_DIR/terminal-tab-presentation-fixture"

"$BUILD_DIR/terminal-tab-presentation-fixture"
