#!/bin/zsh
set -euo pipefail

APP_ROOT="${0:A:h}"
HOST="$APP_ROOT/Sources/OurocodeDesktop/TerminalHostViewController.swift"

rg -Fq 'private final class TerminalTextSizeHUDView: NSView' "$HOST"
rg -Fq 'override func hitTest(_ point: NSPoint) -> NSView? { nil }' "$HOST"
rg -Fq 'private let textSizeHUD = TerminalTextSizeHUDView()' "$HOST"
rg -Fq 'textSizeHUD.setAccessibilityElement(false)' "$HOST"
rg -Fq 'textSizeHUDGeneration &+= 1' "$HOST"
rg -Fq 'self.textSizeHUDGeneration == generation' "$HOST"
rg -Fq 'textSizeHUD.layer?.removeAllAnimations()' "$HOST"
rg -Fq 'presentTerminalFontSizeHUD(status: "Default")' "$HOST"
rg -Fq 'presentTerminalFontSizeHUD(status: change.boundary?.rawValue)' "$HOST"
rg -Fq 'TerminalTypographyRuntimeTrace.record("coalesced", "font=\(previous)")' "$HOST"
rg -Fq 'announcement: "Terminal text size \(pointSize) points' "$HOST"
rg -Fq 'accessibilityDisplayShouldReduceMotion' "$HOST"
rg -Fq 'DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hide)' "$HOST"

echo "PASS: text zoom has one bounded, accessible, reduced-motion-aware HUD"
