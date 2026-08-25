#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BUILD_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ourocode-broker-presentation.XXXXXX")
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalBrokerPresentationPolicy.swift" \
  "$APP_ROOT/Tests/TerminalBrokerPresentationPolicyFixture.swift" \
  -o "$BUILD_DIR/fixture"

"$BUILD_DIR/fixture"
