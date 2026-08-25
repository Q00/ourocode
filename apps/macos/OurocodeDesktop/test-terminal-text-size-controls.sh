#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"

# Terminal zoom stays in the standard native menu and Command shortcuts. The
# toolbar must not duplicate it with permanent minus/size/plus chrome.
for removed in \
  'private let decreaseTextSizeButton = NSButton' \
  'private let textSizeButton = NSButton' \
  'private let increaseTextSizeButton = NSButton' \
  'textSizeControls.addArrangedSubview'
do
  if grep -Fq "$removed" "$HOST"; then
    print -u2 "FAIL: redundant text-size toolbar chrome remains: $removed"
    exit 1
  fi
done
rg -Fq 'case .increase: increaseTerminalFontSize(nil)' "$HOST"
rg -Fq 'case .decrease: decreaseTerminalFontSize(nil)' "$HOST"
rg -Fq 'case .reset: resetTerminalFontSize(nil)' "$HOST"

echo "PASS: terminal zoom uses native Command shortcuts without toolbar duplication"
