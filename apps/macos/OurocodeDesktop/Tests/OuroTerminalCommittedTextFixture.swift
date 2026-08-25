import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum OuroTerminalCommittedTextFixture {
    static func main() {
        let decomposed = "한글"
        let normalized = OuroTerminalCommittedText.normalize(decomposed)
        require(normalized == "한글", "decomposed Hangul was not normalized to syllables")
        require(normalized.unicodeScalars.count == 2, "Hangul still occupied one cell per jamo scalar")
        require(OuroTerminalCommittedText.normalize("abc 123") == "abc 123",
                "ASCII commit changed during canonical normalization")
        require(OuroTerminalCommittedText.normalize("é") == "é",
                "precomposed non-Hangul text changed")
        print("PASS: terminal commits normalize decomposed Hangul before grid delivery")
    }
}
