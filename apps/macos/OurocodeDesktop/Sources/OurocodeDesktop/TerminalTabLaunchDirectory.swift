import Foundation

enum TerminalTabLaunchDirectory {
    static func resolve(
        inheritedPath: String?,
        fallbackPath: String,
        fileManager: FileManager = .default
    ) -> String {
        if let inheritedPath,
           inheritedPath.hasPrefix("/"),
           isDirectory(inheritedPath, fileManager: fileManager) {
            return URL(fileURLWithPath: inheritedPath, isDirectory: true)
                .standardizedFileURL.path
        }
        if fallbackPath.hasPrefix("/"),
           isDirectory(fallbackPath, fileManager: fileManager) {
            return URL(fileURLWithPath: fallbackPath, isDirectory: true)
                .standardizedFileURL.path
        }
        return FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
    }

    private static func isDirectory(_ path: String, fileManager: FileManager) -> Bool {
        var isDirectory = ObjCBool(false)
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

enum TerminalTabCustomTitleStore {
    private static let key = "terminal.custom-titles.v1"
    static let maximumTitleLength = 80

    static func normalized(_ value: String) -> String? {
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return String(title.prefix(maximumTitleLength))
    }

    static func title(for terminalID: String, defaults: UserDefaults = .standard) -> String? {
        guard !terminalID.isEmpty,
              let stored = defaults.dictionary(forKey: key)?[terminalID] as? String else { return nil }
        return normalized(stored)
    }

    static func set(
        _ title: String?,
        for terminalID: String,
        defaults: UserDefaults = .standard
    ) {
        guard !terminalID.isEmpty else { return }
        var titles = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        if let title, let normalized = normalized(title) { titles[terminalID] = normalized }
        else { titles.removeValue(forKey: terminalID) }
        defaults.set(titles, forKey: key)
    }
}
