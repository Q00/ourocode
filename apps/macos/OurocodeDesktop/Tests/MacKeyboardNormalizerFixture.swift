import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum MacKeyboardNormalizerFixture {
  static func main() throws {
    guard let capsLockTransition = NSEvent.keyEvent(
      with: .flagsChanged,
      location: .zero,
      modifierFlags: .capsLock,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: 57
    ) else {
      fatalError("could not construct a modifier transition fixture")
    }
    let capsLockValue = MacKeyboardEvent(capsLockTransition)
    require(
      capsLockValue.keyCode == 57
        && capsLockValue.modifiers.contains(.capsLock)
        && capsLockValue.characters.isEmpty
        && capsLockValue.charactersIgnoringModifiers.isEmpty
        && !capsLockValue.isRepeat,
      "flagsChanged conversion queried or invented a text payload"
    )
    let korean = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "ㅁ",
        charactersIgnoringModifiers: "a"
      ),
      hadMarkedText: true,
      changedMarkedText: false,
      insertedText: ["한"]
    )
    require(korean == [.committedText("한")], "Korean IME commit leaked a hardware key")

    let ordinary = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(keyCode: 0, characters: "a", charactersIgnoringModifiers: "a"),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: ["a"]
    )
    require(
      ordinary == [.committedText("a")],
      "ordinary AppKit text was not committed exactly once")
    let interpretedASCII = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "",
        charactersIgnoringModifiers: "a"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: ["a"]
    )
    require(
      interpretedASCII == [.committedText("a")],
      "AppKit insertText was discarded when NSEvent.characters was empty")
    let charactersOnlyASCII = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "a",
        charactersIgnoringModifiers: "a"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: []
    )
    require(
      charactersOnlyASCII == [.committedText("a")],
      "insertedText-empty printable ASCII was not committed")
    let charactersOnlyKorean = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "한",
        charactersIgnoringModifiers: "a"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: []
    )
    require(
      charactersOnlyKorean == [.committedText("한")],
      "insertedText-empty printable Korean was not committed")
    let synthesizedBWithPlaceholderAKey = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "b",
        charactersIgnoringModifiers: "b"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: ["b"]
    )
    require(
      synthesizedBWithPlaceholderAKey == [.committedText("b")],
      "mismatched synthetic HID/scalar pair dropped committed alphabetic text"
    )
    let synthesizedKoreanWithoutMarkedText = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 0,
        characters: "한",
        charactersIgnoringModifiers: "a"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: ["한"]
    )
    require(
      synthesizedKoreanWithoutMarkedText == [.committedText("한")],
      "direct synthesized Unicode text leaked into a physical ANSI key"
    )
    for modifier in [NSEvent.ModifierFlags.control, .option, .command] {
      let modified = MacKeyboardNormalizer.keyDownEvents(
        event: MacKeyboardEvent(
          keyCode: 8,
          modifiers: modifier,
          characters: "c",
          charactersIgnoringModifiers: "c"
        ),
        hadMarkedText: false,
        changedMarkedText: false,
        insertedText: ["c"]
      )
      guard case .key = modified.first, modified.count == 1 else {
        fatalError("modified chord was converted into committed text")
      }
    }
    let interpretedReturn = MacKeyboardNormalizer.keyDownEvents(
      event: MacKeyboardEvent(
        keyCode: 36,
        characters: "\r",
        charactersIgnoringModifiers: "\r"
      ),
      hadMarkedText: false,
      changedMarkedText: false,
      insertedText: []
    )
    guard case .key(let interpretedReturnKey)? = interpretedReturn.first else {
      fatalError("insertedText-empty Return lost its HID event")
    }
    require(
      interpretedReturnKey.hidUsage == 0x28 && interpretedReturnKey.text.isEmpty,
      "insertedText-empty Return did not preserve its special-key contract"
    )
    let shiftedA = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 0,
        modifiers: .shift,
        characters: "A",
        charactersIgnoringModifiers: "a"
      )
    )
    require(
      shiftedA?.unshiftedCodepoint == 0x61
        && shiftedA?.consumedModifiers == .shift,
      "Shift-A did not preserve unmodified a and consumed Shift")
    let capsA = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 0,
        modifiers: .capsLock,
        characters: "A",
        charactersIgnoringModifiers: "a"
      )
    )
    require(
      capsA?.unshiftedCodepoint == 0x61
        && capsA?.consumedModifiers == .capsLock,
      "Caps-A did not preserve unmodified a and consumed Caps Lock")

    let controlC = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 8,
        modifiers: .control,
        characters: "\u{3}",
        charactersIgnoringModifiers: "c"
      )
    )
    require(controlC?.hidUsage == 0x06, "Ctrl-C HID usage is wrong")
    require(
      controlC?.modifiers == .control && controlC?.text == "", "Ctrl-C embedded raw control text")
    require(controlC?.unshiftedCodepoint == 0x63, "Ctrl-C lost its unshifted scalar")
    let controlCEvent = NormalizedTerminalInputEvent.key(controlC!)
    require(
      MacKeyboardNormalizer.mergingCommandSelectorFallback(
        primary: [controlCEvent],
        physical: [controlCEvent],
        committedText: "\u{3}"
      ) == [controlCEvent],
      "Ctrl-C doCommand fallback duplicated one physical key press"
    )


    let optionA = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 0,
        modifiers: .option,
        characters: "å",
        charactersIgnoringModifiers: "a"
      )
    )
    require(optionA?.modifiers == .option, "Option was not preserved as terminal Alt")
    require(
      optionA?.text == "" && optionA?.unshiftedCodepoint == 0x61,
      "Option was consumed into AppKit text")
    let rightOptionCodes: Set<UInt16> = [61]
    let rightOption = MacKeyboardNormalizer.modifierKey(
      from: MacKeyboardEvent(keyCode: 61, modifiers: .option),
      action: .press,
      activeRightModifiers: MacKeyboardNormalizer.activeRightModifiers(
        for: rightOptionCodes)
    )
    require(
      rightOption?.hidUsage == 0xe6 && rightOption?.action == .press
        && rightOption?.modifiers.contains([.option, .rightOption]) == true,
      "right Option flagsChanged identity was lost")
    let missedRightOptionRelease = MacKeyboardEvent(keyCode: 61, modifiers: [])
    require(
      MacKeyboardNormalizer.modifierAction(
        for: missedRightOptionRelease,
        wasTracked: false
      ) == .release,
      "a modifier release after authority reset was inverted into a press")
    let rightOptionRelease = MacKeyboardNormalizer.modifierKey(
      from: missedRightOptionRelease,
      action: .release,
      activeRightModifiers: []
    )
    require(
      rightOptionRelease?.hidUsage == 0xe6 && rightOptionRelease?.action == .release,
      "right Option release HID was lost after authority reset")

    let returnKey = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(keyCode: 36, characters: "\r", charactersIgnoringModifiers: "\r")
    )
    require(
      returnKey?.hidUsage == 0x28 && returnKey?.text == "", "Return was not a normalized HID key")
    let returnEvent = NormalizedTerminalInputEvent.key(returnKey!)
    require(
      MacKeyboardNormalizer.mergingCommandSelectorFallback(
        primary: [returnEvent],
        physical: [returnEvent],
        committedText: ""
      ) == [returnEvent],
      "Return doCommand fallback duplicated one physical key press"
    )

    let left = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 123,
        characters: "\u{f702}",
        charactersIgnoringModifiers: "\u{f702}"
      )
    )
    require(left?.hidUsage == 0x50, "left arrow HID usage is wrong")
    require(left?.text == "" && left?.unshiftedCodepoint == 0, "AppKit PUA arrow leaked into text")

    let repeated = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(
        keyCode: 0,
        characters: "a",
        charactersIgnoringModifiers: "a",
        isRepeat: true
      )
    )
    require(repeated?.action == .repeat, "key repeat lost its action")
    let released = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(keyCode: 0, characters: "a", charactersIgnoringModifiers: "a"),
      action: .release
    )
    require(released?.action == .release && released?.text == "", "key release carried press text")

    let control = MacKeyboardNormalizer.key(
      from: MacKeyboardEvent(keyCode: 0, characters: "\u{1}", charactersIgnoringModifiers: "\u{1}")
    )
    require(control?.text == "" && control?.unshiftedCodepoint == 0, "C0 control scalar leaked")
    _ = try NormalizedTerminalInputEvent.key(control!).validatedWireObject()
    _ = try NormalizedTerminalInputEvent.committedText("한").validatedWireObject()

    print(
      "PASS: AppKit key/IME fixture (Korean/a/Ctrl-C/Option/Return/arrow/repeat/release/control/PUA)"
    )
  }
}
