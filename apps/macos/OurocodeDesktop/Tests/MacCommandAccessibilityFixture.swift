import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum MacCommandAccessibilityFixture {
  static func main() {
    let commands = [
      MacCommandAccessibility.settings,
      MacCommandAccessibility.find,
      MacCommandAccessibility.findNext,
      MacCommandAccessibility.findPrevious,
      MacCommandAccessibility.makeTextBigger,
      MacCommandAccessibility.makeTextSmaller,
      MacCommandAccessibility.actualSize,
      MacCommandAccessibility.toggleFullScreen,
      MacCommandAccessibility.clearScreen,
      MacCommandAccessibility.selectAll,
      MacCommandAccessibility.scrollToTop,
      MacCommandAccessibility.scrollToBottom,
    ]

    require(
      MacCommandAccessibility.settings.keyEquivalent == ","
        && MacCommandAccessibility.settings.modifiers == [.command],
      "Settings must remain Command-comma"
    )
    require(
      MacCommandAccessibility.find.keyEquivalent == "f"
        && MacCommandAccessibility.find.modifiers == [.command],
      "terminal Find must remain Command-F"
    )
    require(
      MacCommandAccessibility.findNext.keyEquivalent == "g"
        && MacCommandAccessibility.findNext.modifiers == [.command],
      "Find Next must remain Command-G"
    )
    require(
      MacCommandAccessibility.findPrevious.keyEquivalent == "g"
        && MacCommandAccessibility.findPrevious.modifiers == [.command, .shift],
      "Find Previous must remain Shift-Command-G"
    )
    require(
      MacCommandAccessibility.makeTextBigger.keyEquivalent == "+"
        && MacCommandAccessibility.makeTextBigger.modifiers == [.command],
      "text zoom-in must remain Command-plus"
    )
    require(
      MacCommandAccessibility.makeTextSmaller.keyEquivalent == "-"
        && MacCommandAccessibility.actualSize.keyEquivalent == "0",
      "text zoom-out/reset shortcuts drifted"
    )
    require(
      MacCommandAccessibility.toggleFullScreen.keyEquivalent == "f"
        && MacCommandAccessibility.toggleFullScreen.modifiers == [.command, .control],
      "full-screen shortcut must remain Control-Command-F"
    )
    require(
      MacCommandAccessibility.clearScreen.keyEquivalent == "k"
        && MacCommandAccessibility.clearScreen.modifiers == [.command],
      "clear screen must remain Command-K"
    )
    require(
      MacCommandAccessibility.selectAll.keyEquivalent == "a"
        && MacCommandAccessibility.selectAll.modifiers == [.command],
      "select all must remain Command-A"
    )
    require(
      MacCommandAccessibility.scrollToTop.keyEquivalent
        == String(Character(UnicodeScalar(NSHomeFunctionKey)!))
        && MacCommandAccessibility.scrollToBottom.keyEquivalent
          == String(Character(UnicodeScalar(NSEndFunctionKey)!)),
      "terminal history must remain Command-Home/Command-End"
    )
    require(
      commands.allSatisfy {
        !$0.title.isEmpty && !$0.keyEquivalent.isEmpty && !$0.accessibilityLabel.isEmpty
      },
      "a keyboard command lost its visible title or VoiceOver label"
    )

    let labels = [
      MacCommandAccessibility.findSearchFieldLabel,
      MacCommandAccessibility.findResultsLabel,
      MacCommandAccessibility.previousMatchLabel,
      MacCommandAccessibility.nextMatchLabel,
      MacCommandAccessibility.settingsFontSizeLabel,
      MacCommandAccessibility.settingsCurrentFontSizeLabel,
      MacCommandAccessibility.settingsResetFontSizeLabel,
      MacCommandAccessibility.settingsVisualBellLabel,
      MacCommandAccessibility.settingsAudibleBellLabel,
    ]
    require(labels.allSatisfy { !$0.isEmpty }, "a Find or Settings control lost its AX label")
    require(Set(labels).count == labels.count, "Find and Settings AX labels are ambiguous")

    let item = NSMenuItem()
    MacCommandAccessibility.apply(MacCommandAccessibility.findPrevious, to: item)
    require(item.title == "Find Previous", "menu command did not apply its visible title")
    require(item.keyEquivalent == "g", "menu command did not apply its key equivalent")
    require(
      item.keyEquivalentModifierMask == [.command, .shift],
      "menu command did not apply its modifier mask"
    )
    require(
      item.accessibilityLabel() == "Reveal previous terminal match",
      "menu command did not expose its explicit VoiceOver label"
    )

    print("PASS: native edit, history, Find, Settings, zoom shortcuts and AX labels remain explicit")
  }
}
