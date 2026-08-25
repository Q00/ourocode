import Foundation

/// Converts Ghostty's borrowed shell metadata into bounded UI/session state.
/// Remote file URLs and control-bearing values never become launch paths.
enum TerminalShellMetadataPolicy {
    static let maximumTitleBytes = 256
    static let maximumPathBytes = 4 * 1024

    static func title(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.utf8.count <= maximumTitleBytes,
              !containsControl(value) else { return nil }
        return value
    }

    static func directory(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty, raw.utf8.count <= maximumPathBytes,
              !containsControl(raw) else { return nil }

        if raw.hasPrefix("/") {
            return URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.path
        }

        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "file",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.host == nil || components.host?.lowercased() == "localhost",
              let path = components.percentEncodedPath.removingPercentEncoding,
              path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private static func containsControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || (0x7f...0x9f).contains(scalar.value)
        }
    }
}
