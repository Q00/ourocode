import Foundation

@main
enum TerminalTabLaunchDirectoryFixture {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ourocode-tab-cwd-\(UUID().uuidString)", isDirectory: true)
        let inherited = root.appendingPathComponent("inherited", isDirectory: true)
        let fallback = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: inherited, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        require(
            TerminalTabLaunchDirectory.resolve(
                inheritedPath: inherited.path,
                fallbackPath: fallback.path
            ) == inherited.standardizedFileURL.path,
            "live tab cwd was not inherited"
        )
        require(
            TerminalTabLaunchDirectory.resolve(
                inheritedPath: root.appendingPathComponent("missing").path,
                fallbackPath: fallback.path
            ) == fallback.standardizedFileURL.path,
            "missing tab cwd did not fall back to project directory"
        )
        require(
            TerminalTabLaunchDirectory.resolve(
                inheritedPath: "relative/path",
                fallbackPath: fallback.path
            ) == fallback.standardizedFileURL.path,
            "relative cwd was trusted"
        )

        let suite = "ourocode-title-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let long = String(repeating: "A", count: 120)
        TerminalTabCustomTitleStore.set(long, for: "terminal-1", defaults: defaults)
        require(
            TerminalTabCustomTitleStore.title(for: "terminal-1", defaults: defaults)?.count
                == TerminalTabCustomTitleStore.maximumTitleLength,
            "custom tab title was not bounded"
        )
        TerminalTabCustomTitleStore.set("   ", for: "terminal-1", defaults: defaults)
        require(
            TerminalTabCustomTitleStore.title(for: "terminal-1", defaults: defaults) == nil,
            "blank custom title did not reset"
        )
        print("PASS: new tabs inherit a live absolute cwd and custom titles stay bounded")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
