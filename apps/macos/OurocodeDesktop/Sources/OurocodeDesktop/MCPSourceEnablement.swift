import Foundation

struct MCPSourceEnablementStore {
    private static let defaultsKey = "enabledMCPSourceIDs"
    private static let legacyMigrationKey = "enabledMCPSourceIDs.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func enabledSourceIDs(allSourceIDs: [String]) -> Set<String> {
        if defaults.bool(forKey: Self.legacyMigrationKey),
           let stored = defaults.array(forKey: Self.defaultsKey) as? [String] {
            return Set(stored).intersection(allSourceIDs)
        }
        defaults.set(true, forKey: Self.legacyMigrationKey)
        defaults.set(allSourceIDs, forKey: Self.defaultsKey)
        return Set(allSourceIDs)
    }

    func setEnabled(_ enabled: Bool, sourceID: String, allSourceIDs: [String]) {
        var current = enabledSourceIDs(allSourceIDs: allSourceIDs)
        if enabled {
            current.insert(sourceID)
        } else {
            current.remove(sourceID)
        }
        defaults.set(allSourceIDs.filter(current.contains), forKey: Self.defaultsKey)
    }
}

enum MCPSourceTogglePolicy {
    static func nextState(currentlyEnabled: Bool) -> Bool { !currentlyEnabled }

    static func statusLabel(enabled: Bool, runtimeStatus: String) -> String {
        enabled ? runtimeStatus.capitalized : "Off"
    }

    static func detail(enabled: Bool, runtimeDetail: String) -> String {
        enabled ? runtimeDetail : "Disabled · enable to connect"
    }
}
