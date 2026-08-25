import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TerminalConversationPresentationFixture {
    static func main() {
        let output = TerminalConversationPresentation.surfaceFlags(
            rowSemantic: 0,
            cellSemantic: 0
        )
        require(output == 0, "ordinary output was styled as a conversation turn")

        let prompt = TerminalConversationPresentation.surfaceFlags(
            rowSemantic: 1,
            cellSemantic: 2
        )
        require(prompt & TerminalConversationPresentation.promptRowFlag != 0,
                "prompt row treatment was lost")
        require(prompt & TerminalConversationPresentation.promptFlag != 0,
                "prompt cell treatment was lost")
        require(prompt & TerminalConversationPresentation.promptStartRowFlag != 0,
                "prompt-start boundary treatment was lost")
        require(prompt & TerminalConversationPresentation.inputFlag == 0,
                "prompt text was misclassified as user input")

        let continuation = TerminalConversationPresentation.surfaceFlags(
            rowSemantic: 2,
            cellSemantic: 1
        )
        require(continuation & TerminalConversationPresentation.promptRowFlag != 0,
                "wrapped prompt row treatment was lost")
        require(continuation & TerminalConversationPresentation.inputFlag != 0,
                "command input treatment was lost")
        require(continuation & TerminalConversationPresentation.promptStartRowFlag == 0,
                "wrapped input row was styled as a new command turn")

        let unknown = TerminalConversationPresentation.surfaceFlags(
            rowSemantic: UInt32.max,
            cellSemantic: UInt32.max
        )
        require(unknown == 0, "unknown future semantics were styled optimistically")

        let reservedTerminalBits: UInt32 = (1 << 7) - 1
        require(
            (TerminalConversationPresentation.promptRowFlag
                | TerminalConversationPresentation.inputFlag
                | TerminalConversationPresentation.promptFlag
                | TerminalConversationPresentation.promptStartRowFlag) & reservedTerminalBits == 0,
            "conversation hints overlap existing renderer surface flags"
        )

        print("PASS: OSC 133 turns gain bounded renderer-only conversation hints")
    }
}
