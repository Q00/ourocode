#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ourocode-native-shortcuts.XXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

swiftc -parse-as-library -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/NativeTerminalShortcutPolicy.swift" \
  "$APP_ROOT/Tests/NativeTerminalShortcutPolicyFixture.swift" \
  -o "$BUILD_DIR/fixture"

"$BUILD_DIR/fixture"

# Native menu key equivalents, not a second keyDown monitor, own Command-number
# and Command-N dispatch. These source contracts catch accidental regression to
# an inaccessible hardware-keyCode-only implementation.
rg -Fq 'action: #selector(AppDelegate.newWindow(_:))' "$APP_ROOT/Sources/OurocodeDesktop/main.swift"
rg -Fq 'keyEquivalent: NativeTerminalShortcutPolicy.newWindowKeyEquivalent' "$APP_ROOT/Sources/OurocodeDesktop/main.swift"
rg -Fq 'action: #selector(TerminalHostViewController.selectTabByNumber(_:))' "$APP_ROOT/Sources/OurocodeDesktop/main.swift"
rg -Fq '@objc func selectTabByNumber(_ sender: Any?)' "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
if rg -Fq 'let numberKeyCodes: [UInt16: Int]' "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"; then
  echo "FAIL: private hardware-keyCode tab routing still competes with AppKit" >&2
  exit 1
fi

echo "PASS: AppKit main menu is the single native shortcut authority"
