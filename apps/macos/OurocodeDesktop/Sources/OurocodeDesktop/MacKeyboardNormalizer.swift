#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit

  /// Value-only AppKit key data. Keeping the normalizer independent of a live
  /// `NSEvent` makes input policy deterministic and directly fixture-testable.
  struct MacKeyboardEvent: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    let characters: String
    let charactersIgnoringModifiers: String
    let isRepeat: Bool

    init(
      keyCode: UInt16,
      modifiers: NSEvent.ModifierFlags = [],
      characters: String = "",
      charactersIgnoringModifiers: String = "",
      isRepeat: Bool = false
    ) {
      self.keyCode = keyCode
      self.modifiers = modifiers
      self.characters = characters
      self.charactersIgnoringModifiers = charactersIgnoringModifiers
      self.isRepeat = isRepeat
    }

    init(_ event: NSEvent) {
      // AppKit raises an Objective-C exception when text-only accessors are
      // queried on `.flagsChanged` events. Modifier transitions have no text
      // payload, so keep their value representation explicitly text-free.
      let carriesText = event.type == .keyDown || event.type == .keyUp
      self.init(
        keyCode: event.keyCode,
        modifiers: event.modifierFlags,
        characters: carriesText ? (event.characters ?? "") : "",
        // `charactersIgnoringModifiers` still applies Shift. The broker needs
        // the true unmodified scalar to apply its own Ghostty mode rules.
        charactersIgnoringModifiers: carriesText
          ? (event.characters(byApplyingModifiers: []) ?? "")
          : "",
        isRepeat: carriesText && event.isARepeat
      )
    }
  }

  enum MacKeyboardNormalizer {
    static func key(
      from event: MacKeyboardEvent,
      action explicitAction: NormalizedTerminalKeyAction? = nil,
      composing: Bool = false,
      activeRightModifiers: NormalizedTerminalModifiers = []
    ) -> NormalizedTerminalKey? {
      guard let hidUsage = hidUsage(for: event.keyCode) else { return nil }
      let modifiers = normalizedModifiers(event.modifiers).union(activeRightModifiers)
      let action = explicitAction ?? (event.isRepeat ? .repeat : .press)
      let unshiftedCodepoint = printableScalar(event.charactersIgnoringModifiers)?.value ?? 0

      // Option is terminal Alt/Meta. Do not collapse it into a composed AppKit
      // character; the canonical Ghostty terminal decides the mode-aware bytes.
      let text: String
      if action == .release || modifiers.contains(.option) || modifiers.contains(.control)
        || modifiers.contains(.command) || composing
      {
        text = ""
      } else {
        text = printableText(event.characters)
      }

      var consumed: NormalizedTerminalModifiers = []
      if modifiers.contains(.shift), text != printableText(event.charactersIgnoringModifiers) {
        consumed.insert(.shift)
      }
      if modifiers.contains(.capsLock), text != printableText(event.charactersIgnoringModifiers) {
        consumed.insert(.capsLock)
      }

      return NormalizedTerminalKey(
        hidUsage: hidUsage,
        action: action,
        modifiers: modifiers,
        consumedModifiers: consumed,
        composing: composing,
        unshiftedCodepoint: unshiftedCodepoint,
        text: text
      )
    }

    static func modifierKey(
      from event: MacKeyboardEvent,
      action: NormalizedTerminalKeyAction,
      activeRightModifiers: NormalizedTerminalModifiers
    ) -> NormalizedTerminalKey? {
      guard modifier(for: event.keyCode) != nil else { return nil }
      let modifiers = normalizedModifiers(event.modifiers).union(activeRightModifiers)
      guard
        let key = key(
          from: event,
          action: action,
          activeRightModifiers: activeRightModifiers
        )
      else { return nil }
      return NormalizedTerminalKey(
        hidUsage: key.hidUsage,
        action: key.action,
        modifiers: modifiers,
        consumedModifiers: key.consumedModifiers,
        composing: key.composing,
        unshiftedCodepoint: key.unshiftedCodepoint,
        text: key.text
      )
    }

    static func modifierAction(
      for event: MacKeyboardEvent,
      wasTracked: Bool
    ) -> NormalizedTerminalKeyAction? {
      guard let base = modifier(for: event.keyCode) else { return nil }
      if wasTracked { return .release }
      return normalizedModifiers(event.modifiers).contains(base) ? .press : .release
    }

    static func activeRightModifiers(for keyCodes: Set<UInt16>) -> NormalizedTerminalModifiers {
      var result: NormalizedTerminalModifiers = []
      for keyCode in keyCodes {
        if let modifier = rightModifier(for: keyCode) { result.insert(modifier) }
      }
      return result
    }

    static func keyDownEvents(
      event: MacKeyboardEvent,
      hadMarkedText: Bool,
      changedMarkedText: Bool,
      insertedText: [String],
      activeRightModifiers: NormalizedTerminalModifiers = []
    ) -> [NormalizedTerminalInputEvent] {
      if hadMarkedText || changedMarkedText {
        return insertedText.filter { !$0.isEmpty }.map(NormalizedTerminalInputEvent.committedText)
      }
      // `interpretKeyEvents` is authoritative for the text committed by the
      // active input source. Synthetic input, alternate layouts, and some
      // AppKit text services can provide the right value through `insertText`
      // while leaving NSEvent.characters empty or layout-relative. Preserve
      // the physical HID key and modifiers, but encode the committed scalar.
      let interpreted = insertedText.joined()
      let authoritativeText = interpreted.isEmpty ? event.characters : interpreted
      let modifiers = normalizedModifiers(event.modifiers).union(activeRightModifiers)
      if !authoritativeText.isEmpty,
        modifiers.intersection([.control, .option, .command]).isEmpty,
        printableText(authoritativeText) == authoritativeText
      {
        // AppKit is the authority for unmodified printable text. Accessibility
        // synthesis, IMEs, and alternate layouts may provide placeholder or
        // mismatched virtual keys; forwarding those as HID can make Ghostty
        // discard valid letters. Modified chords and non-text keys continue
        // through the physical key contract below.
        return [.committedText(authoritativeText)]
      }
      let effectiveEvent = interpreted.isEmpty
        ? event
        : MacKeyboardEvent(
          keyCode: event.keyCode,
          modifiers: event.modifiers,
          characters: interpreted,
          charactersIgnoringModifiers: event.charactersIgnoringModifiers,
          isRepeat: event.isRepeat
        )
      guard let key = key(from: effectiveEvent, activeRightModifiers: activeRightModifiers) else {
        return []
      }
      return [.key(key)]
    }

    /// AppKit can report one physical key through both its ordinary key event
    /// and `doCommand(by:)` (Return and Ctrl-C are common examples). Merge the
    /// command-selector fallback without emitting the same broker event twice.
    static func mergingCommandSelectorFallback(
      primary: [NormalizedTerminalInputEvent],
      physical: [NormalizedTerminalInputEvent],
      committedText: String
    ) -> [NormalizedTerminalInputEvent] {
      var merged = primary
      for candidate in physical {
        if merged.contains(candidate) { continue }
        if case .committedText(let text) = candidate,
          !text.isEmpty,
          committedText.hasSuffix(text)
        {
          continue
        }
        merged.append(candidate)
      }
      return merged
    }

    static func normalizedModifiers(
      _ flags: NSEvent.ModifierFlags
    ) -> NormalizedTerminalModifiers {
      let device = flags.intersection(.deviceIndependentFlagsMask)
      var result: NormalizedTerminalModifiers = []
      if device.contains(.shift) { result.insert(.shift) }
      if device.contains(.control) { result.insert(.control) }
      if device.contains(.option) { result.insert(.option) }
      if device.contains(.command) { result.insert(.command) }
      if device.contains(.capsLock) { result.insert(.capsLock) }
      if device.contains(.numericPad) { result.insert(.numericPad) }

      // AppKit's public aggregate flags do not carry left/right identity. The
      // physical key's HID usage remains exact; right-side bits are included
      // only while normalizing that modifier's own flagsChanged event.
      return result
    }

    private static func modifier(for keyCode: UInt16) -> NormalizedTerminalModifiers? {
      switch keyCode {
      case 56: return .shift
      case 60: return .shift
      case 59: return .control
      case 62: return .control
      case 58: return .option
      case 61: return .option
      case 55: return .command
      case 54: return .command
      case 57: return .capsLock
      default: return nil
      }
    }

    private static func rightModifier(for keyCode: UInt16) -> NormalizedTerminalModifiers? {
      switch keyCode {
      case 60: return .rightShift
      case 62: return .rightControl
      case 61: return .rightOption
      case 54: return .rightCommand
      default: return nil
      }
    }

    private static func printableText(_ value: String) -> String {
      guard !value.isEmpty,
        value.utf8.count <= NormalizedTerminalInputEvent.maximumKeyTextBytes,
        value.unicodeScalars.allSatisfy({ isPrintable($0.value) })
      else { return "" }
      return value
    }

    private static func printableScalar(_ value: String) -> Unicode.Scalar? {
      guard value.unicodeScalars.count == 1,
        let scalar = value.unicodeScalars.first,
        isPrintable(scalar.value)
      else { return nil }
      return scalar
    }

    private static func isPrintable(_ value: UInt32) -> Bool {
      value > 0x1f && value != 0x7f && !(0xf700...0xf8ff).contains(value)
    }

    /// macOS virtual key code to USB HID Keyboard/Keypad usage. Unknown media
    /// keys are rejected instead of being guessed or translated to ANSI.
    private static func hidUsage(for keyCode: UInt16) -> UInt32? {
      hidUsages[keyCode]
    }

    private static let hidUsages: [UInt16: UInt32] = [
      0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0a,
      4: 0x0b, 34: 0x0c, 38: 0x0d, 40: 0x0e, 37: 0x0f, 46: 0x10, 45: 0x11,
      31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17, 32: 0x18,
      9: 0x19, 13: 0x1a, 7: 0x1b, 16: 0x1c, 6: 0x1d,
      18: 0x1e, 19: 0x1f, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24,
      28: 0x25, 25: 0x26, 29: 0x27,
      36: 0x28, 53: 0x29, 51: 0x2a, 48: 0x2b, 49: 0x2c, 27: 0x2d, 24: 0x2e,
      33: 0x2f, 30: 0x30, 42: 0x31, 41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36,
      47: 0x37, 44: 0x38, 57: 0x39,
      122: 0x3a, 120: 0x3b, 99: 0x3c, 118: 0x3d, 96: 0x3e, 97: 0x3f,
      98: 0x40, 100: 0x41, 101: 0x42, 109: 0x43, 103: 0x44, 111: 0x45,
      105: 0x68, 107: 0x69, 113: 0x6a, 106: 0x6b, 64: 0x6c, 79: 0x6d,
      80: 0x6e, 90: 0x6f,
      114: 0x49, 115: 0x4a, 116: 0x4b, 117: 0x4c, 119: 0x4d, 121: 0x4e,
      124: 0x4f, 123: 0x50, 125: 0x51, 126: 0x52,
      71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58, 83: 0x59,
      84: 0x5a, 85: 0x5b, 86: 0x5c, 87: 0x5d, 88: 0x5e, 89: 0x5f, 91: 0x60,
      92: 0x61, 82: 0x62, 65: 0x63, 81: 0x67,
      56: 0xe1, 60: 0xe5, 59: 0xe0, 62: 0xe4, 58: 0xe2, 61: 0xe6, 55: 0xe3,
      54: 0xe7,
    ]
  }
#endif
