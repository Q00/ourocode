import Foundation

private final class FixtureProvider: CommandProvider {
    let commandProviderID: CommandProviderID
    var commands: [CommandDescriptor]
    var performed: [CommandID] = []

    init(id: String, commands: [CommandDescriptor] = []) {
        commandProviderID = CommandProviderID(rawValue: id)!
        self.commands = commands
    }

    func commandSnapshot(limit: Int) -> [CommandDescriptor] {
        Array(commands.prefix(limit))
    }

    func perform(commandID: CommandID) -> CommandExecutionResult {
        guard commands.contains(where: { $0.id == commandID }) else {
            return .unavailable("stale")
        }
        performed.append(commandID)
        return .executed
    }
}

@main
enum CommandRegistryFixture {
    static func main() throws {
        let terminalID = CommandProviderID(rawValue: "terminal")!
        let provider = FixtureProvider(id: "terminal")
        let exact = CommandDescriptor(
            id: CommandID(provider: terminalID, local: "settings"),
            title: "Settings",
            keywords: ["preferences"],
            section: .actions,
            symbolName: "gearshape"
        )
        let substring = CommandDescriptor(
            id: CommandID(provider: terminalID, local: "tab-settings"),
            title: "Project Settings Notes",
            subtitle: "~/Café",
            keywords: ["terminal tab"],
            section: .terminals,
            symbolName: "terminal"
        )
        let keyword = CommandDescriptor(
            id: CommandID(provider: terminalID, local: "prefs"),
            title: "Open Configuration",
            keywords: ["settings preferences"],
            section: .actions,
            symbolName: "gear"
        )
        provider.commands = [substring, keyword, exact]
        let registry = try CommandRegistry(providers: [provider])

        require(registry.snapshot().count == 3, "registry dropped unique commands")
        require(
            CommandPaletteSearch.results(for: "settings", in: registry.snapshot()).map(\.id)
                == [exact.id, substring.id, keyword.id],
            "exact/prefix/keyword ranking was not deterministic"
        )
        require(
            CommandPaletteSearch.results(for: "cafe", in: registry.snapshot()).first?.id == substring.id,
            "diacritic-insensitive subtitle search failed"
        )
        require(registry.perform(exact.id) == .executed, "stable command did not dispatch")
        provider.commands.removeAll()
        require(registry.perform(exact.id) == .unavailable("stale"), "stale command was not revalidated")

        do {
            _ = try CommandRegistry(providers: [provider, FixtureProvider(id: "terminal")])
            require(false, "duplicate provider identity was accepted")
        } catch CommandRegistryError.duplicateProvider(let duplicate) {
            require(duplicate == terminalID, "duplicate provider error lost identity")
        }

        let duplicateProvider = FixtureProvider(id: "duplicate", commands: [
            CommandDescriptor(
                id: CommandID(provider: CommandProviderID(rawValue: "duplicate")!, local: "same"),
                title: "First",
                section: .actions,
                symbolName: "1.circle"
            ),
            CommandDescriptor(
                id: CommandID(provider: CommandProviderID(rawValue: "duplicate")!, local: "same"),
                title: "Second",
                section: .actions,
                symbolName: "2.circle"
            ),
        ])
        try require(
            try CommandRegistry(providers: [duplicateProvider]).snapshot().map(\.title) == ["First"],
            "duplicate command identity did not fail closed"
        )
        print("PASS: bounded command registry, stable dispatch and deterministic search")
    }

    private static func require(
        _ condition: @autoclosure () throws -> Bool,
        _ message: String
    ) rethrows {
        guard try condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
