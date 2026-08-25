/// Pure policy behind Ourocode's native macOS window and direct-tab shortcuts.
/// AppKit owns key-equivalent dispatch; this type only decides which stable
/// tab position a menu command may activate.
enum NativeTerminalShortcutPolicy {
    static let directTabLimit = 9
    static let newWindowKeyEquivalent = "n"

    static func directTabCommands() -> [(commandNumber: Int, keyEquivalent: String)] {
        (1...directTabLimit).map { ($0, String($0)) }
    }

    static func tabIndex(
        commandNumber: Int,
        tabCount: Int,
        unavailableIndices: Set<Int> = []
    ) -> Int? {
        guard (1...directTabLimit).contains(commandNumber) else { return nil }
        let index = commandNumber - 1
        guard index < tabCount, !unavailableIndices.contains(index) else { return nil }
        return index
    }
}

