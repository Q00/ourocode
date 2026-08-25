import Foundation

enum TerminalTabPresentation {
  static func displayTitle(
    shellTitle: String,
    shellProvidedTitle: Bool,
    path: String,
    homePath: String,
    displaySequence: UInt64,
    sessionBinding: TerminalSessionBinding? = nil
  ) -> String {
    if let sessionBinding {
      return sessionBinding.tabTitle
    }
    let cleanTitle = shellTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if shellProvidedTitle, !cleanTitle.isEmpty {
      return semanticShellTitle(cleanTitle, path: path, homePath: homePath)
    }

    let location = directoryName(path: path, homePath: homePath)
    if location == "~" {
      return "Shell \(displaySequence)"
    }
    return "\(location) · \(displaySequence)"
  }

  /// OSC titles are authoritative, but a bare process name still needs the
  /// working location to distinguish fanout terminals at a glance. Rich titles
  /// such as "codex — RFC review" remain untouched.
  static func semanticShellTitle(_ title: String, path: String, homePath: String) -> String {
    let normalized = title.trimmingCharacters(in: .whitespacesAndNewlines)
    let location = directoryName(path: path, homePath: homePath)
    let bareProcess = normalized.range(
      of: #"^[A-Za-z0-9._+-]+$"#, options: .regularExpression
    ) != nil
    let hostIdentity = normalized.range(
      of: #"^[A-Za-z0-9._+-]+@[A-Za-z0-9._+-]+$"#, options: .regularExpression
    ) != nil
    guard (bareProcess || hostIdentity), location != "~" else { return normalized }
    // Host/user identity is useful in a tooltip and the tab picker, but it is
    // noise in the narrow tab strip. The working directory is the shortest
    // stable label that tells the user which terminal this is.
    return hostIdentity ? location : "\(normalized) · \(location)"
  }

  static func directoryName(path: String, homePath: String) -> String {
    let expandedPath = (path as NSString).expandingTildeInPath
    let expandedHome = (homePath as NSString).expandingTildeInPath
    let standardized = URL(fileURLWithPath: expandedPath).standardizedFileURL
    let home = URL(fileURLWithPath: expandedHome).standardizedFileURL
    if standardized == home { return "~" }
    let location = standardized.lastPathComponent
    return location.isEmpty ? "Shell" : location
  }
}
