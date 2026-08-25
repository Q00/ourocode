struct OuroTerminalAccessibilitySnapshot: Equatable {
  static let maximumUTF8Bytes = 16 * 1_024

  let value: String
  let selectedText: String?
  let cursorLine: Int?
  let commandRows: [String]
  let truncated: Bool
  /// True only when Ghostty's row projection observed an OSC 133 prompt row.
  /// A visible prompt string or OSC 7 metadata is deliberately not enough.
  let hasSemanticPrompt: Bool
  /// True only when Ghostty classified at least one cell as command input
  /// after the OSC 133 prompt boundary.
  let hasSemanticInput: Bool

  var isSemanticPromptReady: Bool { hasSemanticPrompt && hasSemanticInput }

  static let empty = OuroTerminalAccessibilitySnapshot(
    value: "",
    selectedText: nil,
    cursorLine: nil,
    commandRows: [],
    truncated: false,
    hasSemanticPrompt: false,
    hasSemanticInput: false
  )
}

/// Retains the selected terminal's current grid semantics across partial
/// damage frames. It is one bounded viewport projection, not a transcript or
/// a second scrollback model.
struct OuroTerminalAccessibilityProjection: Equatable {
  private var rows: [String]
  private var selectedRows: [String]
  private var semantics: [UInt32]
  private var semanticPromptRows: [Bool]
  private var semanticInputRows: [Bool]

  init(rowCount: Int) {
    let count = max(0, rowCount)
    rows = Array(repeating: "", count: count)
    selectedRows = Array(repeating: "", count: count)
    semantics = Array(repeating: 0, count: count)
    semanticPromptRows = Array(repeating: false, count: count)
    semanticInputRows = Array(repeating: false, count: count)
  }

  mutating func update(
    rowIndex: Int,
    semantic: UInt32,
    line: String,
    selected: String,
    hasSemanticInput: Bool = false
  ) {
    guard rows.indices.contains(rowIndex) else { return }
    rows[rowIndex] = Self.prefix(line, maximumUTF8Bytes: 16_384)
    selectedRows[rowIndex] = Self.prefix(selected, maximumUTF8Bytes: 16_384)
    semantics[rowIndex] = semantic
    semanticPromptRows[rowIndex] = semantic == 1 || semantic == 2
    semanticInputRows[rowIndex] = hasSemanticInput
  }

  func snapshot(cursorLine: Int?) -> OuroTerminalAccessibilitySnapshot {
    var retained: [(index: Int, line: String)] = []
    var retainedBytes = 0
    var truncated = false
    for index in rows.indices.reversed() {
      let line = rows[index]
      let separatorBytes = retained.isEmpty ? 0 : 1
      let remaining = OuroTerminalAccessibilitySnapshot.maximumUTF8Bytes - retainedBytes
      guard separatorBytes <= remaining else {
        truncated = true
        continue
      }
      let availableLineBytes = remaining - separatorBytes
      let boundedLine = Self.prefix(line, maximumUTF8Bytes: availableLineBytes)
      if boundedLine.utf8.count < line.utf8.count { truncated = true }
      retained.append((index, boundedLine))
      retainedBytes += boundedLine.utf8.count + separatorBytes
      if retainedBytes == OuroTerminalAccessibilitySnapshot.maximumUTF8Bytes { break }
    }
    retained.reverse()

    var selected = ""
    var selectedBytes = 0
    var commandRows: [String] = []
    var commandBytes = 0
    for item in retained {
      let selectedPart = Self.prefix(
        selectedRows[item.index],
        maximumUTF8Bytes: OuroTerminalAccessibilitySnapshot.maximumUTF8Bytes - selectedBytes
      )
      selected.append(selectedPart)
      selectedBytes += selectedPart.utf8.count

      guard semantics[item.index] == 1, !item.line.isEmpty, commandRows.count < 64 else {
        continue
      }
      let separatorBytes = commandRows.isEmpty ? 0 : 1
      let available = OuroTerminalAccessibilitySnapshot.maximumUTF8Bytes - commandBytes
      guard separatorBytes <= available else { continue }
      let command = Self.prefix(item.line, maximumUTF8Bytes: available - separatorBytes)
      guard !command.isEmpty else { continue }
      commandRows.append(command)
      commandBytes += command.utf8.count + separatorBytes
    }

    return OuroTerminalAccessibilitySnapshot(
      value: retained.map(\.line).joined(separator: "\n"),
      selectedText: selected.isEmpty ? nil : selected,
      cursorLine: cursorLine,
      commandRows: commandRows,
      truncated: truncated,
      hasSemanticPrompt: retained.contains { semanticPromptRows[$0.index] },
      hasSemanticInput: retained.contains { semanticInputRows[$0.index] }
    )
  }

  static func prefix(_ value: String, maximumUTF8Bytes: Int) -> String {
    guard maximumUTF8Bytes > 0 else { return "" }
    guard value.utf8.count > maximumUTF8Bytes else { return value }

    var end = value.startIndex
    var byteCount = 0
    while end < value.endIndex {
      let next = value.index(after: end)
      let characterBytes = value[end..<next].utf8.count
      guard characterBytes <= maximumUTF8Bytes - byteCount else { break }
      byteCount += characterBytes
      end = next
    }
    return String(value[..<end])
  }
}
