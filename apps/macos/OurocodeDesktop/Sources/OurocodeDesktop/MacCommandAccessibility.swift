import AppKit

/// Native menu and VoiceOver contract for the small set of commands that
/// must remain discoverable even while the Metal terminal owns first
/// responder. Keeping these values outside `main.swift` lets a fast fixture
/// prevent keyboard and accessibility drift without constructing the app.
enum MacCommandAccessibility {
  struct MenuCommand: Equatable {
    let title: String
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    let accessibilityLabel: String
  }

  static let settings = MenuCommand(
    title: "Settings…",
    keyEquivalent: ",",
    modifiers: [.command],
    accessibilityLabel: "Open Ourocode settings"
  )
  static let find = MenuCommand(
    title: "Find in Terminal…",
    keyEquivalent: "f",
    modifiers: [.command],
    accessibilityLabel: "Find text in terminal scrollback"
  )
  static let findNext = MenuCommand(
    title: "Find Next",
    keyEquivalent: "g",
    modifiers: [.command],
    accessibilityLabel: "Reveal next terminal match"
  )
  static let findPrevious = MenuCommand(
    title: "Find Previous",
    keyEquivalent: "g",
    modifiers: [.command, .shift],
    accessibilityLabel: "Reveal previous terminal match"
  )
  static let makeTextBigger = MenuCommand(
    title: "Make Text Bigger",
    keyEquivalent: "+",
    modifiers: [.command],
    accessibilityLabel: "Make terminal text bigger"
  )
  static let makeTextSmaller = MenuCommand(
    title: "Make Text Smaller",
    keyEquivalent: "-",
    modifiers: [.command],
    accessibilityLabel: "Make terminal text smaller"
  )
  static let actualSize = MenuCommand(
    title: "Actual Size",
    keyEquivalent: "0",
    modifiers: [.command],
    accessibilityLabel: "Reset terminal text to actual size"
  )
  static let toggleFullScreen = MenuCommand(
    title: "Toggle Full Screen",
    keyEquivalent: "f",
    modifiers: [.command, .control],
    accessibilityLabel: "Enter or leave full screen"
  )
  static let clearScreen = MenuCommand(
    title: "Clear Screen",
    keyEquivalent: "k",
    modifiers: [.command],
    accessibilityLabel: "Clear the active terminal screen"
  )
  static let selectAll = MenuCommand(
    title: "Select All",
    keyEquivalent: "a",
    modifiers: [.command],
    accessibilityLabel: "Select all terminal scrollback"
  )
  static let scrollToTop = MenuCommand(
    title: "Scroll to Top",
    keyEquivalent: String(Character(UnicodeScalar(NSHomeFunctionKey)!)),
    modifiers: [.command],
    accessibilityLabel: "Scroll to the top of terminal history"
  )
  static let scrollToBottom = MenuCommand(
    title: "Scroll to Bottom",
    keyEquivalent: String(Character(UnicodeScalar(NSEndFunctionKey)!)),
    modifiers: [.command],
    accessibilityLabel: "Scroll to the bottom of terminal history"
  )

  static let findSearchFieldLabel = "Find in terminal scrollback"
  static let findResultsLabel = "Terminal find results"
  static let previousMatchLabel = "Previous match"
  static let nextMatchLabel = "Next match"
  static let settingsFontSizeLabel = "Terminal text size"
  static let settingsCurrentFontSizeLabel = "Current terminal text size"
  static let settingsResetFontSizeLabel = "Reset terminal text size"
  static let settingsVisualBellLabel = "Flash terminal for bell"
  static let settingsAudibleBellLabel = "Play system sound for bell"

  static func apply(_ command: MenuCommand, to item: NSMenuItem) {
    item.title = command.title
    item.keyEquivalent = command.keyEquivalent
    item.keyEquivalentModifierMask = command.modifiers
    item.setAccessibilityLabel(command.accessibilityLabel)
  }
}
