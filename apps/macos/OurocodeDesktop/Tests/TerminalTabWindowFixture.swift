import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalTabWindowFixture {
    static func main() {
        require(TerminalTabWindow.indices(total: 0, selected: 0) == [], "empty tabs drifted")
        require(TerminalTabWindow.indices(total: 3, selected: 2) == [0, 1, 2], "small set was hidden")
        require(TerminalTabWindow.indices(total: 18, selected: 0) == [0, 1, 2, 3, 4], "leading window drifted")
        require(TerminalTabWindow.indices(total: 18, selected: 9) == [7, 8, 9, 10, 11], "middle window drifted")
        require(TerminalTabWindow.indices(total: 18, selected: 17) == [13, 14, 15, 16, 17], "trailing window drifted")
        print("PASS: high tab counts keep a bounded local window")
    }
}
