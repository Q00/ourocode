#!/usr/bin/env bash
set -euo pipefail

APP_ROOT="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$APP_ROOT/../../.." && pwd)"
OUTPUT="$(mktemp -d)/ourocode-session-message-contract-fixture"

xcrun swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageContract.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/SessionMessageStateStore.swift" \
  "$APP_ROOT/Tests/SessionMessageContractFixture.swift" \
  -o "$OUTPUT"

"$OUTPUT" "$REPO_ROOT/docs/rfcs/fixtures/session-message-v1-known-vector.json"
