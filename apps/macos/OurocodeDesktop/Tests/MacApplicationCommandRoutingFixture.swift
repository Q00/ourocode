import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum MacApplicationCommandRoutingFixture {
  static func main() {
    require(
      MacApplicationCommandRouting.typographyTarget(
        hasEventWindowContext: true,
        hasActiveWindowContext: true
      ) == .eventWindow,
      "application zoom did not prefer the event window's terminal context"
    )
    require(
      MacApplicationCommandRouting.typographyTarget(
        hasEventWindowContext: false,
        hasActiveWindowContext: true
      ) == .activeWindow,
      "Connections or transient workspace focus did not fall back to the active terminal context"
    )
    require(
      MacApplicationCommandRouting.typographyTarget(
        hasEventWindowContext: false,
        hasActiveWindowContext: false
      ) == .unavailable,
      "application zoom invented a terminal target"
    )
    let cases: [(UInt16, NSEvent.ModifierFlags, String?, TerminalTypographyShortcut?)] = [
      (24, [.command], "=", .increase),
      (24, [.command, .shift], "+", .increase),
      (93, [.command], "+", .increase),
      (69, [.command, .numericPad], "+", .increase),
      (27, [.command], "-", .decrease),
      (78, [.command, .numericPad], "-", .decrease),
      (29, [.command], "0", .reset),
      (24, [.command], "å", nil),
      (24, [.command], nil, .increase),
      (24, [.control], "=", nil),
    ]
    for (keyCode, modifiers, characters, expected) in cases {
      require(
        MacApplicationCommandRouting.typographyAction(
          applicationIsActive: true,
          hasApplicationWindow: true,
          hasEligibleTerminal: true,
          keyCode: keyCode,
          modifiers: modifiers,
          charactersIgnoringModifiers: characters
        ) == expected,
        "typography route drifted for key \(keyCode), characters \(String(describing: characters))"
      )
    }
    require(
      MacApplicationCommandRouting.typographyAction(
        applicationIsActive: false,
        hasApplicationWindow: true,
        hasEligibleTerminal: true,
        keyCode: 24,
        modifiers: [.command],
        charactersIgnoringModifiers: "="
      ) == nil,
      "inactive app captured a typography shortcut"
    )
    require(
      MacApplicationCommandRouting.typographyAction(
        applicationIsActive: true,
        hasApplicationWindow: false,
        hasEligibleTerminal: true,
        keyCode: 24,
        modifiers: [.command],
        charactersIgnoringModifiers: "="
      ) == nil,
      "typography shortcut routed without an Ourocode window"
    )
    require(
      MacApplicationCommandRouting.typographyAction(
        applicationIsActive: true,
        hasApplicationWindow: true,
        hasEligibleTerminal: true,
        keyCode: 24,
        modifiers: [.command],
        charactersIgnoringModifiers: "="
      ) == .increase,
      "session workspace or transient Ourocode window disabled application zoom"
    )
    require(
      MacApplicationCommandRouting.typographyAction(
        applicationIsActive: true,
        hasApplicationWindow: true,
        hasEligibleTerminal: false,
        keyCode: 24,
        modifiers: [.command],
        charactersIgnoringModifiers: "="
      ) == nil,
      "application zoom changed a window with no eligible terminal"
    )
    require(
      TerminalTypographyPointSizeTransition.noOpFeedback(
        action: .reset,
        current: 16,
        minimum: 12,
        maximum: 48,
        defaultSize: 16
      ) == "Default",
      "Cmd-0 at default size had no visible feedback status"
    )
    require(
      TerminalTypographyPointSizeTransition.noOpFeedback(
        action: .decrease,
        current: 12,
        minimum: 12,
        maximum: 48,
        defaultSize: 16
      ) == "Minimum"
        && TerminalTypographyPointSizeTransition.noOpFeedback(
          action: .increase,
          current: 48,
          minimum: 12,
          maximum: 48,
          defaultSize: 16
        ) == "Maximum",
      "boundary zoom feedback status was not deterministic"
    )

    require(
      TerminalTypographyAvailability.isEnabled(
        .increase,
        hasEligibleTerminal: true,
        currentSize: 16,
        minimumSize: 12,
        maximumSize: 48,
        defaultSize: 16
      ),
      "eligible terminal could not increase text size"
    )
    require(
      !TerminalTypographyAvailability.isEnabled(
        .increase,
        hasEligibleTerminal: true,
        currentSize: 48,
        minimumSize: 12,
        maximumSize: 48,
        defaultSize: 16
      ),
      "maximum text size still enabled increase"
    )
    require(
      !TerminalTypographyAvailability.isEnabled(
        .decrease,
        hasEligibleTerminal: true,
        currentSize: 12,
        minimumSize: 12,
        maximumSize: 48,
        defaultSize: 16
      ),
      "minimum text size still enabled decrease"
    )
    require(
      !TerminalTypographyAvailability.isEnabled(
        .reset,
        hasEligibleTerminal: true,
        currentSize: 16,
        minimumSize: 12,
        maximumSize: 48,
        defaultSize: 16
      ),
      "default text size still enabled reset"
    )
    require(
      !TerminalTypographyAvailability.isEnabled(
        .increase,
        hasEligibleTerminal: false,
        currentSize: 16,
        minimumSize: 12,
        maximumSize: 48,
        defaultSize: 16
      ),
      "non-terminal key window enabled terminal typography"
    )
    let terminalCommands: [(UInt16, String?, MacApplicationCommandRouting.TerminalAction?)] = [
      (40, "k", .clearScreen),
      (40, nil, .clearScreen),
      (115, String(Character(UnicodeScalar(NSHomeFunctionKey)!)), .scrollToTop),
      (119, String(Character(UnicodeScalar(NSEndFunctionKey)!)), .scrollToBottom),
      (40, "x", nil),
    ]
    for (keyCode, characters, expected) in terminalCommands {
      require(
        MacApplicationCommandRouting.terminalAction(
          applicationIsActive: true,
          hasApplicationWindow: true,
          keyCode: keyCode,
          modifiers: [.command],
          charactersIgnoringModifiers: characters
        ) == expected,
        "terminal action route drifted for key (keyCode), characters (String(describing: characters))"
      )
    }
    require(
      MacApplicationCommandRouting.terminalAction(
        applicationIsActive: true,
        hasApplicationWindow: true,
        keyCode: 40,
        modifiers: [.command, .shift],
        charactersIgnoringModifiers: "k"
      ) == nil,
      "Shift-Command-K unexpectedly cleared the terminal"
    )
    require(
      MacApplicationCommandRouting.closeDestination(
        hasKeyWindow: true,
        keyWindowIsTerminalWindow: true,
        keyWindowIsClosable: true,
        terminalCanCloseTab: true
      ) == .terminalTab,
      "terminal Cmd-W did not route to Close Tab"
    )
    require(
      MacApplicationCommandRouting.closeDestination(
        hasKeyWindow: true,
        keyWindowIsTerminalWindow: false,
        keyWindowIsClosable: true,
        terminalCanCloseTab: true
      ) == .keyWindow,
      "Settings Cmd-W did not route to Close Window"
    )
    require(
      MacApplicationCommandRouting.closeDestination(
        hasKeyWindow: true,
        keyWindowIsTerminalWindow: true,
        keyWindowIsClosable: true,
        terminalCanCloseTab: false
      ) == .unavailable,
      "terminal close remained enabled without a closable tab"
    )
    require(
      MacApplicationCommandRouting.closeDestination(
        hasKeyWindow: false,
        keyWindowIsTerminalWindow: false,
        keyWindowIsClosable: false,
        terminalCanCloseTab: true
      ) == .unavailable,
      "Cmd-W routed without a key window"
    )
    print("PASS: application-wide terminal zoom, clear/history aliases and key-window-aware Cmd-W routing")
  }
}
