import Foundation

/// Command-click is intentionally narrower than a generic URL opener. OSC 8
/// is terminal output, so only bounded network URLs without credentials are
/// eligible for an explicit user gesture.
enum TerminalHyperlinkPolicy {
  static let maximumUTF8Bytes = 4_096

  static func url(_ raw: String) -> URL? {
    guard !raw.isEmpty, raw.utf8.count <= maximumUTF8Bytes,
          !raw.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
          let value = URL(string: raw),
          let scheme = value.scheme?.lowercased(),
          scheme == "https" || scheme == "http",
          value.host?.isEmpty == false,
          value.user == nil,
          value.password == nil,
          value.fragment?.utf8.count ?? 0 <= maximumUTF8Bytes
    else { return nil }
    return value
  }
}
