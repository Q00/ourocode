import Foundation

struct CommandProviderID: Hashable, RawRepresentable {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.count <= 48,
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
                      .contains($0)
              }) else { return nil }
        self.rawValue = rawValue
    }
}

struct CommandID: Hashable {
    let provider: CommandProviderID
    let local: String
}

enum CommandSection: String, CaseIterable {
    case actions = "Actions"
    case terminals = "Terminal Tabs"
    case connections = "Connections"
    case sessions = "Sessions"
}

struct CommandDescriptor: Hashable {
    let id: CommandID
    let title: String
    let subtitle: String?
    let keywords: [String]
    let section: CommandSection
    let shortcut: String?
    let symbolName: String
    let isEnabled: Bool
    let rankHint: Int

    init(
        id: CommandID,
        title: String,
        subtitle: String? = nil,
        keywords: [String] = [],
        section: CommandSection,
        shortcut: String? = nil,
        symbolName: String,
        isEnabled: Bool = true,
        rankHint: Int = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.keywords = keywords
        self.section = section
        self.shortcut = shortcut
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.rankHint = rankHint
    }
}

enum CommandExecutionResult: Equatable {
    case executed
    case unavailable(String)
}

protocol CommandProvider: AnyObject {
    var commandProviderID: CommandProviderID { get }
    /// Cached metadata only. This path must not perform I/O, attach a terminal,
    /// refresh MCP state, or allocate a render projection.
    func commandSnapshot(limit: Int) -> [CommandDescriptor]
    /// Revalidates the stable ID against provider-owned live state.
    func perform(commandID: CommandID) -> CommandExecutionResult
}

enum CommandRegistryError: Error, Equatable {
    case duplicateProvider(CommandProviderID)
}

final class CommandRegistry {
    static let maximumProviderItems = 512
    static let maximumItems = 768

    private let providers: [CommandProvider]
    private let providersByID: [CommandProviderID: CommandProvider]

    init(providers: [CommandProvider]) throws {
        var indexed: [CommandProviderID: CommandProvider] = [:]
        for provider in providers {
            guard indexed.updateValue(provider, forKey: provider.commandProviderID) == nil else {
                throw CommandRegistryError.duplicateProvider(provider.commandProviderID)
            }
        }
        self.providers = providers
        providersByID = indexed
    }

    func snapshot() -> [CommandDescriptor] {
        var result: [CommandDescriptor] = []
        var seen = Set<CommandID>()
        for provider in providers {
            for descriptor in provider.commandSnapshot(limit: Self.maximumProviderItems)
                .prefix(Self.maximumProviderItems)
            {
                guard descriptor.id.provider == provider.commandProviderID,
                      seen.insert(descriptor.id).inserted else { continue }
                result.append(descriptor)
                if result.count == Self.maximumItems { return result }
            }
        }
        return result
    }

    func perform(_ id: CommandID) -> CommandExecutionResult {
        guard let provider = providersByID[id.provider] else {
            return .unavailable("This command provider is no longer available.")
        }
        return provider.perform(commandID: id)
    }
}

enum CommandPaletteSearch {
    static let maximumResults = 50

    static func results(
        for query: String,
        in commands: [CommandDescriptor],
        limit: Int = maximumResults
    ) -> [CommandDescriptor] {
        let normalized = fold(query)
        let tokens = normalized.split(separator: " ").map(String.init)
        return commands.enumerated().compactMap { index, command -> (CommandDescriptor, Int, Int)? in
            guard command.isEnabled else { return nil }
            let title = fold(command.title)
            let subtitle = fold(command.subtitle ?? "")
            let keywords = fold(command.keywords.joined(separator: " "))
            let searchable = "\(title) \(subtitle) \(keywords)"
            guard tokens.allSatisfy(searchable.contains) else { return nil }

            var score = command.rankHint
            if normalized.isEmpty { score += 1_000 }
            if title == normalized { score += 10_000 }
            else if title.hasPrefix(normalized) { score += 7_000 }
            else if title.contains(normalized) { score += 4_000 }
            if subtitle.hasPrefix(normalized) { score += 1_500 }
            if keywords.contains(normalized) { score += 750 }
            return (command, score, index)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.2 < rhs.2
        }
        .prefix(max(0, limit))
        .map(\.0)
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
