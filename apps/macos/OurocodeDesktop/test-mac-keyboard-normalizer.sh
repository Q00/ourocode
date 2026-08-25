#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp /private/tmp/ourocode-mac-keyboard-normalizer.XXXXXX)
trap 'rm -f -- "$FIXTURE_BINARY"' EXIT

swiftc -warnings-as-errors -D OUROCODE_GHOSTTY_METAL_SURFACE \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerFlowControl.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageGatewayClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BrokerClient.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/NormalizedTerminalInput.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/MacKeyboardNormalizer.swift" \
  "$APP_ROOT/Tests/MacKeyboardNormalizerFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
