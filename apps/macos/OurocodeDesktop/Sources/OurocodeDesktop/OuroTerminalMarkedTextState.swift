#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit

  /// Bounded NSTextInputClient state for a terminal, which has no editable
  /// Cocoa backing store. AppKit still requires stable, valid insertion ranges
  /// to keep IME composition and direct Unicode insertion on the text path.
  final class OuroTerminalMarkedTextState {
    private let storage = NSMutableAttributedString()
    private(set) var selection = NSRange()

    var hasMarkedText: Bool { storage.length > 0 }
    var attributedText: NSAttributedString {
      storage.copy() as? NSAttributedString ?? NSAttributedString()
    }
    var string: String { storage.string }

    var markedRange: NSRange {
      hasMarkedText
        ? NSRange(location: 0, length: storage.length)
        : NSRange(location: NSNotFound, length: 0)
    }

    var selectedRange: NSRange {
      hasMarkedText ? selection : NSRange()
    }

    func replace(with value: NSAttributedString, selectedRange requested: NSRange) {
      storage.setAttributedString(value)
      selection = Self.clampedSelection(requested, utf16Length: storage.length)
    }

    @discardableResult
    func clear() -> Bool {
      guard hasMarkedText else {
        selection = NSRange()
        return false
      }
      storage.mutableString.setString("")
      selection = NSRange()
      return true
    }

    func attributedSubstring(forProposedRange requested: NSRange) -> NSAttributedString? {
      guard hasMarkedText,
        requested.location != NSNotFound,
        requested.location < storage.length
      else { return nil }
      let length = min(requested.length, storage.length - requested.location)
      guard length > 0 else { return nil }
      return storage.attributedSubstring(
        from: NSRange(location: requested.location, length: length)
      )
    }

    func actualRange(for requested: NSRange) -> NSRange {
      guard hasMarkedText,
        requested.location != NSNotFound,
        requested.location < storage.length
      else { return selectedRange }
      let length = min(requested.length, storage.length - requested.location)
      return NSRange(location: requested.location, length: length)
    }

    private static func clampedSelection(_ requested: NSRange, utf16Length: Int) -> NSRange {
      guard requested.location != NSNotFound else {
        return NSRange(location: utf16Length, length: 0)
      }
      let location = min(requested.location, utf16Length)
      let length = min(requested.length, utf16Length - location)
      return NSRange(location: location, length: length)
    }
  }

  enum OuroTerminalIMECommitPolicy {
    /// Selectors that mean "the user typed a boundary character", which is how
    /// a Korean input method finalizes its retained syllable without calling
    /// `insertText`. Space is the observed 2-Set case; newline and tab reach
    /// the same commit boundary and must not silently drop the syllable.
    /// The set is closed on purpose: a selector that does not end composition
    /// — `noop:` above all — must never flush a live preedit, or every jamo
    /// commits on its own keystroke instead of composing into a syllable.
    private static let compositionEndingSelectors: Set<String> = [
      "insertSpace:", "insertNewline:", "insertLineBreak:", "insertTab:",
    ]

    /// Selectors that shrink or abandon a preedit. When one of these emptied
    /// the composition, the syllable was deleted rather than committed, so
    /// echoing the pre-keystroke preedit would resurrect discarded text.
    private static let compositionDiscardingSelectors: Set<String> = [
      "deleteBackward:", "deleteForward:", "deleteWordBackward:",
      "deleteWordForward:", "deleteToBeginningOfLine:", "cancelOperation:",
    ]

    /// Returns the preedit that AppKit finalized without an `insertText`
    /// callback. A continuing non-empty preedit is committed only when this
    /// key interpretation carried a composition-ending selector, and a preedit
    /// emptied by a deleting selector is never committed.
    static func retainedCommit(
      hadMarkedText: Bool,
      markedTextAtStart: String,
      markedTextAfterInterpretation: String,
      insertedText: [String],
      commandSelectors: [String]
    ) -> String? {
      guard hadMarkedText, insertedText.isEmpty else { return nil }
      if markedTextAfterInterpretation.isEmpty {
        guard !commandSelectors.contains(where: compositionDiscardingSelectors.contains) else {
          return nil
        }
        return markedTextAtStart.isEmpty ? nil : markedTextAtStart
      }
      guard commandSelectors.contains(where: compositionEndingSelectors.contains) else {
        return nil
      }
      return markedTextAfterInterpretation
    }
  }
#endif
