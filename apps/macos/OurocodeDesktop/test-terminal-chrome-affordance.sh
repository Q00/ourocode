#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
FIXTURE_BINARY=$(mktemp /private/tmp/ourocode-terminal-chrome.XXXXXX)
trap 'rm -f -- "$FIXTURE_BINARY"' EXIT

swiftc -warnings-as-errors \
  "$APP_ROOT/Sources/OurocodeDesktop/Theme.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/BundledTerminalFont.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalChromeAffordance.swift" \
  "$APP_ROOT/Sources/OurocodeDesktop/ComputerUseSettings.swift" \
  "$APP_ROOT/Tests/TerminalChromeAffordanceFixture.swift" \
  -o "$FIXTURE_BINARY"

"$FIXTURE_BINARY"
rg -Fq 'configureSymbolButton(sourcesButton, symbol: "sidebar.left", label: "Show Connections")' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'let label = visible ? "Hide Connections" : "Show Connections"' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'private let commandPaletteButton = NSButton' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'symbol: "rectangle.and.text.magnifyingglass"' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'commandPaletteButton.toolTip = "Command Palette · ⌘P"' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'terminal.onOpenCommandPalette = { [weak palette, weak mainWindow] in' \
  "$APP_ROOT/Sources/OurocodeDesktop/main.swift"
if rg -Fq 'chrome.addSubview(tabScrollView)' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"; then
  print -u2 'FAIL: redundant terminal tab strip remains visible'
  exit 1
fi
if rg -Fq 'chromeControls.addArrangedSubview(allTabsButton)' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"; then
  print -u2 'FAIL: redundant all-tabs control remains visible'
  exit 1
fi
rg -Fq 'chromeControls.addArrangedSubview(commandPaletteButton)' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
rg -Fq 'chromeControls.addArrangedSubview(addButton)' \
  "$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"
