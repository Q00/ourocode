import Foundation

enum TerminalShellLaunchMode: Equatable {
  case configured
  case cleanZsh

  var executable: String? {
    switch self {
    case .configured: nil
    case .cleanZsh: "/bin/zsh"
    }
  }

  var arguments: [String]? {
    switch self {
    case .configured: nil
    case .cleanZsh: ["-f", "-i"]
    }
  }

  var installsZshIntegration: Bool { self == .configured }
}

struct TerminalShellStartupIdentity: Equatable {
  let tabID: UUID
  let generation: UInt64
}

enum TerminalShellStartupPolicy {
  static let delayedInterval: TimeInterval = 8

  static func isCurrent(
    _ identity: TerminalShellStartupIdentity?,
    tabID: UUID,
    generation: UInt64
  ) -> Bool {
    identity == TerminalShellStartupIdentity(tabID: tabID, generation: generation)
  }
}
