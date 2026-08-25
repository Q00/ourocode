import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum NativeTerminalShortcutPolicyFixture {
    static func main() {
        let commands = NativeTerminalShortcutPolicy.directTabCommands()
        require(commands.count == 9, "native menu did not expose nine direct tab commands")
        require(commands.first?.commandNumber == 1, "first command number drifted")
        require(commands.first?.keyEquivalent == "1", "first key equivalent drifted")
        require(commands.last?.commandNumber == 9, "last command number drifted")
        require(commands.last?.keyEquivalent == "9", "last key equivalent drifted")

        for number in 1...9 {
            require(
                NativeTerminalShortcutPolicy.tabIndex(commandNumber: number, tabCount: 9) == number - 1,
                "Command-\(number) did not resolve its native tab position"
            )
        }
        require(
            NativeTerminalShortcutPolicy.tabIndex(commandNumber: 4, tabCount: 3) == nil,
            "a missing fourth tab remained selectable"
        )
        require(
            NativeTerminalShortcutPolicy.tabIndex(
                commandNumber: 2,
                tabCount: 3,
                unavailableIndices: [1]
            ) == nil,
            "a closing tab remained selectable"
        )
        require(
            NativeTerminalShortcutPolicy.tabIndex(commandNumber: 0, tabCount: 9) == nil,
            "Command-0 was confused with a direct tab shortcut"
        )
        require(
            NativeTerminalShortcutPolicy.tabIndex(commandNumber: 10, tabCount: 32) == nil,
            "tabs beyond the native direct range captured a number shortcut"
        )
        require(
            NativeTerminalShortcutPolicy.newWindowKeyEquivalent == "n",
            "New Window key equivalent drifted from Command-N"
        )
        print("PASS: native Command-1…9 tab selection and Command-N shortcut policy")
    }
}
