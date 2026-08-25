import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalPathDropFixture {
    static func main() {
        let value = TerminalPathDrop.shellInput(for: [
            URL(fileURLWithPath: "/tmp/hello world"),
            URL(fileURLWithPath: "/tmp/O'Brien")
        ])
        require(value == "'/tmp/hello world' '/tmp/O'\\''Brien' ", "paths were not shell-quoted")
        require(TerminalPathDrop.shellInput(for: [URL(string: "https://example.com")!]) == nil,
                "non-file URL was accepted")
        require(TerminalPathDrop.shellInput(for: []) == nil, "empty drop was accepted")
        print("PASS: file drops become quoted, non-executing shell input")
    }
}
