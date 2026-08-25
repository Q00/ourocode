import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

private final class ContractClient: NSObject, NSTextInputClient {
  let state = OuroTerminalMarkedTextState()
  var commits: [String] = []

  func insertText(_ string: Any, replacementRange: NSRange) {
    let value = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
    state.clear()
    if !value.isEmpty { commits.append(value) }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    let value = (string as? NSAttributedString)
      ?? NSAttributedString(string: (string as? String) ?? "")
    state.replace(with: value, selectedRange: selectedRange)
  }

  func unmarkText() { state.clear() }
  func selectedRange() -> NSRange { state.selectedRange }
  func markedRange() -> NSRange { state.markedRange }
  func hasMarkedText() -> Bool { state.hasMarkedText }
  func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? {
    let value = state.attributedSubstring(forProposedRange: range)
    if value != nil { actualRange?.pointee = state.actualRange(for: range) }
    return value
  }
  func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
    actualRange?.pointee = state.actualRange(for: range)
    return NSRect(x: 10, y: 20, width: 8, height: 16)
  }
  func characterIndex(for point: NSPoint) -> Int { 0 }
  func doCommand(by selector: Selector) {}
}

@main
enum OuroTextInputClientContractFixture {
  static func main() {
    let client = ContractClient()
    let context = NSTextInputContext(client: client)
    require(context.client === client, "NSTextInputContext lost its terminal client")
    require(client.selectedRange() == NSRange(), "empty client exposed NSNotFound selection")
    require(
      client.markedRange() == NSRange(location: NSNotFound, length: 0),
      "empty client exposed a valid {0,0} marked range instead of NSNotFound")

    client.setMarkedText(
      NSAttributedString(string: "한"),
      selectedRange: NSRange(location: 1, length: 0),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    require(client.hasMarkedText(), "Korean preedit was not retained locally")
    require(client.markedRange() == NSRange(location: 0, length: 1), "marked range is invalid")
    require(client.selectedRange() == NSRange(location: 1, length: 0), "IME caret was lost")

    var actual = NSRange(location: NSNotFound, length: 0)
    let rect = client.firstRect(
      forCharacterRange: NSRange(location: 1, length: 0),
      actualRange: &actual
    )
    require(actual == NSRange(location: 1, length: 0), "candidate rect returned invalid actualRange")
    require(rect.width > 0 && rect.height > 0, "candidate rect is empty")

    let invalid = client.attributedSubstring(
      forProposedRange: NSRange(location: NSNotFound, length: 1),
      actualRange: nil
    )
    require(invalid == nil, "NSNotFound substring request reached attributed storage")

    client.insertText("한글", replacementRange: NSRange(location: NSNotFound, length: 0))
    require(!client.hasMarkedText(), "direct Unicode commit left stale preedit")
    require(client.commits == ["한글"], "direct Unicode commit was not delivered exactly once")
    require(client.selectedRange() == NSRange(), "post-commit insertion range became invalid")

    let retainedKoreanTail = OuroTerminalIMECommitPolicy.retainedCommit(
      hadMarkedText: true,
      markedTextAtStart: "트",
      markedTextAfterInterpretation: "트",
      insertedText: [],
      commandSelectors: ["insertSpace:"]
    )
    require(
      retainedKoreanTail == "트",
      "Korean Space command lost the final retained marked syllable"
    )
    require(
      OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: true,
        markedTextAtStart: "트",
        markedTextAfterInterpretation: "트",
        insertedText: [],
        commandSelectors: []
      ) == nil,
      "continuing Korean composition was committed prematurely"
    )
    require(
      OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: true,
        markedTextAtStart: "트",
        markedTextAfterInterpretation: "",
        insertedText: ["트"],
        commandSelectors: ["insertSpace:"]
      ) == nil,
      "insertText and command-boundary fallback duplicated a Korean commit"
    )
    require(
      OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: true,
        markedTextAtStart: "ㄱ",
        markedTextAfterInterpretation: "ㄱ",
        insertedText: [],
        commandSelectors: ["noop:"]
      ) == nil,
      "a non-committing selector flushed a live jamo preedit"
    )
    require(
      OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: true,
        markedTextAtStart: "냐",
        markedTextAfterInterpretation: "냐",
        insertedText: [],
        commandSelectors: ["insertNewline:"]
      ) == "냐",
      "Return at a Korean commit boundary discarded the retained syllable"
    )
    require(
      OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: true,
        markedTextAtStart: "ㄴ",
        markedTextAfterInterpretation: "",
        insertedText: [],
        commandSelectors: ["deleteBackward:"]
      ) == nil,
      "backspace that emptied the preedit resurrected the deleted jamo"
    )

    client.setMarkedText(
      "가",
      selectedRange: NSRange(location: NSNotFound, length: 99),
      replacementRange: NSRange(location: NSNotFound, length: 0)
    )
    require(
      client.selectedRange() == NSRange(location: 1, length: 0),
      "invalid AppKit selection was not clamped to the UTF-16 preedit boundary"
    )

    print("PASS: NSTextInputClient keeps stable ranges and commits Korean command-boundary text exactly once")
  }
}
