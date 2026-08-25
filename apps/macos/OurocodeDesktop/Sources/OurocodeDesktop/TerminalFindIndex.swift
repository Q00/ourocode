import Foundation

struct TerminalFindMatch: Equatable {
  let row: UInt64
  let preview: String
  /// Coordinator-owned request generation. A result from an old query or a
  /// previously visible broker stream must never scroll the current session.
  let requestGeneration: UInt64

  init(row: UInt64, preview: String, requestGeneration: UInt64 = 0) {
    self.row = row
    self.preview = preview
    self.requestGeneration = requestGeneration
  }
}

struct TerminalFindResult: Equatable {
  let matches: [TerminalFindMatch]
  let truncated: Bool
}

/// Builds a tiny navigation index from one on-demand formatter projection.
/// The full scrollback String is released after this call; only bounded line
/// previews and absolute row offsets survive in the UI.
enum TerminalFindIndex {
  static let maximumMatches = 1_024
  static let maximumPreviewCharacters = 160

  static func build(
    text: String,
    query: String,
    totalRows: UInt64,
    requestGeneration: UInt64 = 0
  ) -> TerminalFindResult {
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return TerminalFindResult(matches: [], truncated: false)
    }
    let needle = query
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var matches: [TerminalFindMatch] = []
    var truncated = false

    for (index, lineSlice) in lines.enumerated() {
      // Ghostty's formatter emits rows from the top of the physical page and
      // trims only trailing blank rows. It does not right-align the text
      // within scrollbar.total, so the formatter line index is the absolute
      // row coordinate. Keep the bound as a defensive contract check.
      guard UInt64(index) < totalRows else { break }
      let line = String(lineSlice)
      var cursor = line.startIndex
      while cursor < line.endIndex,
            let range = line.range(
              of: needle,
              options: [.caseInsensitive, .diacriticInsensitive],
              range: cursor..<line.endIndex
            )
      {
        guard matches.count < maximumMatches else {
          truncated = true
          return TerminalFindResult(matches: matches, truncated: truncated)
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let preview = trimmed.count <= maximumPreviewCharacters
          ? trimmed
          : String(trimmed.prefix(maximumPreviewCharacters - 1)) + "…"
        matches.append(
          TerminalFindMatch(
            row: UInt64(index),
            preview: preview,
            requestGeneration: requestGeneration
          )
        )
        cursor = range.upperBound > range.lowerBound
          ? range.upperBound
          : line.index(after: range.lowerBound)
      }
    }
    return TerminalFindResult(matches: matches, truncated: truncated)
  }
}
