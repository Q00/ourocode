import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum OuroTerminalAccessibilityProjectionFixture {
  static func main() {
    var initial = OuroTerminalAccessibilityProjection(rowCount: 3)
    initial.update(rowIndex: 0, semantic: 1, line: "git status", selected: "")
    initial.update(rowIndex: 1, semantic: 0, line: "working tree clean", selected: "tree")

    var partial = initial
    partial.update(rowIndex: 2, semantic: 0, line: "next frame", selected: "")
    let retained = partial.snapshot(cursorLine: 2)
    require(retained.value == "git status\nworking tree clean\nnext frame", "partial frame lost retained rows")
    require(retained.commandRows == ["git status"], "partial frame lost semantic command rows")
    require(retained.selectedText == "tree", "partial frame lost retained selection")
    require(retained.cursorLine == 2, "cursor line was not projected")

    var startup = OuroTerminalAccessibilityProjection(rowCount: 3)
    startup.update(
      rowIndex: 0,
      semantic: 0,
      line: "~/Project ourocode ❯",
      selected: ""
    )
    let instantPrompt = startup.snapshot(cursorLine: 0)
    require(!instantPrompt.hasSemanticPrompt, "prompt-looking instant frame became semantic")
    require(!instantPrompt.hasSemanticInput, "instant frame invented semantic input")
    require(!instantPrompt.isSemanticPromptReady, "instant-prompt frame opened readiness")

    startup.update(rowIndex: 1, semantic: 1, line: "❯", selected: "")
    let promptOnly = startup.snapshot(cursorLine: 1)
    require(promptOnly.hasSemanticPrompt, "OSC 133 prompt row was not projected")
    require(!promptOnly.hasSemanticInput, "OSC 133 A-only frame invented B semantics")
    require(!promptOnly.isSemanticPromptReady, "OSC 133 A without B opened readiness")

    startup.update(
      rowIndex: 2,
      semantic: 0,
      line: "",
      selected: "",
      hasSemanticInput: true
    )
    let completedBoundary = startup.snapshot(cursorLine: 2)
    require(completedBoundary.hasSemanticPrompt, "partial frame lost retained prompt semantics")
    require(completedBoundary.hasSemanticInput, "OSC 133 input semantics were not projected")
    require(completedBoundary.isSemanticPromptReady, "complete OSC 133 prompt boundary stayed locked")

    let hostile = String(repeating: "👩🏽‍💻", count: 4_096)
    var bounded = OuroTerminalAccessibilityProjection(rowCount: 2)
    bounded.update(rowIndex: 0, semantic: 1, line: hostile, selected: hostile)
    bounded.update(rowIndex: 1, semantic: 0, line: hostile, selected: hostile)
    let snapshot = bounded.snapshot(cursorLine: nil)
    require(snapshot.value.utf8.count <= 16_384, "AX value exceeded its UTF-8 byte budget")
    require((snapshot.selectedText?.utf8.count ?? 0) <= 16_384, "AX selection exceeded its UTF-8 byte budget")
    require(snapshot.commandRows.joined(separator: "\n").utf8.count <= 16_384, "AX command rows exceeded their UTF-8 byte budget")
    require(snapshot.truncated, "bounded Unicode projection did not report truncation")

    print("PASS: accessibility projection retains bounded OSC 133 prompt/input readiness across partial frames")
  }
}
