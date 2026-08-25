import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
private enum TerminalFindIndexFixture {
  static func main() {
    let empty = TerminalFindIndex.build(text: "alpha", query: " \n ", totalRows: 1)
    require(empty == TerminalFindResult(matches: [], truncated: false), "blank query was indexed")

    let positioned = TerminalFindIndex.build(
      text: "zero\n  Alpha result  \nalpha alpha",
      query: "alpha",
      totalRows: 10,
      requestGeneration: 42
    )
    require(
      positioned.matches == [
        TerminalFindMatch(row: 1, preview: "Alpha result", requestGeneration: 42),
        TerminalFindMatch(row: 2, preview: "alpha alpha", requestGeneration: 42),
        TerminalFindMatch(row: 2, preview: "alpha alpha", requestGeneration: 42),
      ],
      "formatter lines were not kept in top-origin physical row space"
    )
    require(positioned.matches.allSatisfy { $0.requestGeneration == 42 },
            "request identity was not propagated to every match")
    require(!positioned.truncated, "small result was marked truncated")

    let spaced = TerminalFindIndex.build(
      text: "alpha\n alpha \nalpha ",
      query: " alpha ",
      totalRows: 3
    )
    require(
      spaced.matches == [TerminalFindMatch(row: 1, preview: "alpha")],
      "nonblank leading or trailing query spaces were discarded"
    )

    let diacritic = TerminalFindIndex.build(text: "Cafe\u{301}", query: "café", totalRows: 1)
    require(diacritic.matches.count == 1, "canonically equivalent diacritic match was missed")

    let longLine = String(repeating: "가", count: 170) + " needle"
    let bounded = TerminalFindIndex.build(text: longLine, query: "needle", totalRows: 1)
    require(bounded.matches.first?.preview.count == TerminalFindIndex.maximumPreviewCharacters,
            "preview exceeded its grapheme bound")
    require(bounded.matches.first?.preview.last == "…", "bounded preview has no ellipsis")

    let exactCap = TerminalFindIndex.build(
      text: String(repeating: "x", count: TerminalFindIndex.maximumMatches),
      query: "x",
      totalRows: 1
    )
    require(exactCap.matches.count == TerminalFindIndex.maximumMatches, "exact match cap lost results")
    require(!exactCap.truncated, "exact match cap was incorrectly marked truncated")

    let overCap = TerminalFindIndex.build(
      text: String(repeating: "x", count: TerminalFindIndex.maximumMatches + 1),
      query: "x",
      totalRows: 1
    )
    require(overCap.matches.count == TerminalFindIndex.maximumMatches, "match cap was not enforced")
    require(overCap.truncated, "overflowing result did not report truncation")

    print("PASS: terminal Find index is bounded, Unicode-aware, and row-addressable")
  }
}
