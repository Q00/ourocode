import Foundation

/// Stable, display-independent identity for an MCP source.
struct MCPSourceID: Hashable, RawRepresentable, CustomStringConvertible {
    let rawValue: String

    init?(rawValue: String) {
        guard !rawValue.isEmpty,
              rawValue.count <= 64,
              rawValue.unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
                      .contains($0)
              }) else { return nil }
        self.rawValue = rawValue
    }

    var description: String { rawValue }
}

struct MCPSourceRegistration {
    let id: MCPSourceID
    let displayName: String
    let descriptor: LocalMCPSourceDescriptor?
    private let factory: () -> MCPSourceAdapter

    init(
        id: MCPSourceID,
        displayName: String,
        descriptor: LocalMCPSourceDescriptor? = nil,
        factory: @escaping () -> MCPSourceAdapter
    ) {
        self.id = id
        self.displayName = displayName
        self.descriptor = descriptor
        self.factory = factory
    }

    func makeAdapter() -> MCPSourceAdapter { factory() }
}

enum MCPSourceRegistryError: Error, Equatable {
    case emptyDisplayName(MCPSourceID)
    case duplicateID(MCPSourceID)
    case tooManySources(maximum: Int)
}

/// An immutable, bounded source registry. Transport credentials and endpoint
/// details stay inside each adapter factory and never become sidebar model
/// data. Invalid or ambiguous registrations fail closed during construction.
struct MCPSourceRegistry {
    static let maximumSources = 16

    let registrations: [MCPSourceRegistration]
    private let registrationsByID: [MCPSourceID: MCPSourceRegistration]

    init(_ registrations: [MCPSourceRegistration]) throws {
        guard registrations.count <= Self.maximumSources else {
            throw MCPSourceRegistryError.tooManySources(maximum: Self.maximumSources)
        }

        var indexed: [MCPSourceID: MCPSourceRegistration] = [:]
        for registration in registrations {
            guard !registration.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MCPSourceRegistryError.emptyDisplayName(registration.id)
            }
            guard indexed.updateValue(registration, forKey: registration.id) == nil else {
                throw MCPSourceRegistryError.duplicateID(registration.id)
            }
        }
        self.registrations = registrations
        self.registrationsByID = indexed
    }

    func registration(for id: MCPSourceID) -> MCPSourceRegistration? {
        registrationsByID[id]
    }

    func makeAdapters() -> [(registration: MCPSourceRegistration, adapter: MCPSourceAdapter)] {
        registrations.map { ($0, $0.makeAdapter()) }
    }
}
