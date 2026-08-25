import AppKit

/// Pure policy for commands that must work across every Ourocode-owned window.
/// The AppDelegate owns delivery; terminal views must not install a competing
/// typography shortcut path whose lifetime depends on first-responder state.
enum MacApplicationCommandRouting {
  enum TypographyTarget: Equatable {
    case eventWindow
    case activeWindow
    case unavailable
  }
  enum TerminalAction: Equatable {
    case clearScreen
    case scrollToTop
    case scrollToBottom
  }

  enum CloseDestination: Equatable {
    case terminalTab
    case keyWindow
    case unavailable
  }

  static func typographyTarget(
    hasEventWindowContext: Bool,
    hasActiveWindowContext: Bool
  ) -> TypographyTarget {
    if hasEventWindowContext { return .eventWindow }
    if hasActiveWindowContext { return .activeWindow }
    return .unavailable
  }

  static func typographyAction(
    applicationIsActive: Bool,
    hasApplicationWindow: Bool,
    hasEligibleTerminal: Bool,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) -> TerminalTypographyShortcut? {
    // Text size is an application command, not a first-responder command.
    // Session workspaces, find panels, settings and command palettes may own
    // the key-window role while the selected terminal remains visible. Warp,
    // Ghostty and other native terminals keep zoom available across those
    // surfaces; binding it to the main window made Command-plus appear broken.
    guard applicationIsActive, hasApplicationWindow, hasEligibleTerminal else { return nil }
    return TerminalTypographyShortcut.resolve(
      keyCode: keyCode,
      modifiers: modifiers,
      charactersIgnoringModifiers: charactersIgnoringModifiers
    )
  }

  /// Resolves terminal-wide commands before AppKit's first-responder chain.
  /// Metal owns a custom input view, so relying on a menu item's target alone
  /// makes Cmd-K/Home/End disappear whenever a sidebar or transient panel has
  /// focus. Character matching remains layout-aware; key-code fallbacks are
  /// only used for synthetic events that carry no character payload.
  static func terminalAction(
    applicationIsActive: Bool,
    hasApplicationWindow: Bool,
    keyCode: UInt16,
    modifiers: NSEvent.ModifierFlags,
    charactersIgnoringModifiers: String?
  ) -> TerminalAction? {
    guard applicationIsActive, hasApplicationWindow else { return nil }
    let commandOnly = modifiers.intersection([.command, .control, .option, .shift]) == [.command]
    guard commandOnly else { return nil }
    if let charactersIgnoringModifiers, !charactersIgnoringModifiers.isEmpty {
      switch charactersIgnoringModifiers.lowercased() {
      case "k": return .clearScreen
      default: break
      }
    } else {
      // ANSI K is 40; Home and End use AppKit's function-key codes 115/119.
      switch keyCode {
      case 40: return .clearScreen
      case 115: return .scrollToTop
      case 119: return .scrollToBottom
      default: break
      }
    }
    switch keyCode {
    case 115: return .scrollToTop
    case 119: return .scrollToBottom
    default: return nil
    }
  }

  static func closeDestination(
    hasKeyWindow: Bool,
    keyWindowIsTerminalWindow: Bool,
    keyWindowIsClosable: Bool,
    terminalCanCloseTab: Bool
  ) -> CloseDestination {
    guard hasKeyWindow else { return .unavailable }
    if keyWindowIsTerminalWindow {
      return terminalCanCloseTab ? .terminalTab : .unavailable
    }
    return keyWindowIsClosable ? .keyWindow : .unavailable
  }
}
