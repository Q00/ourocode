import Darwin
import Foundation

enum OuroborosLaunchSelection: Equatable {
    case disabled
    case explicit(URL)
    case sharedDefault(autoStartSharedService: Bool, ouroborosExecutable: URL?, uvxExecutable: URL?)
    case invalid(String)
}

enum LaunchConfiguration {
    static let sharedOuroborosEndpoint = URL(string: "http://127.0.0.1:8976/mcp")!
    static let mcpV2CatalogFixtureMode = "mcp-v2-catalog"

    static let demoMode: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }()

    static let mcpV2CatalogFixtureEnabled = enablesMCPV2CatalogFixture(
        arguments: ProcessInfo.processInfo.arguments
    )

    static func enablesMCPV2CatalogFixture(arguments: [String]) -> Bool {
        guard let index = arguments.firstIndex(of: "--demo"), index + 1 < arguments.count else {
            return false
        }
        return arguments[index + 1] == mcpV2CatalogFixtureMode
    }

    /// The default shared service is loopback-only and uses the exact installed
    /// Ouroboros 0.51.6 profile. Startup remains independently suppressible for
    /// users who manage the same endpoint themselves.
    static let ouroborosSelection: OuroborosLaunchSelection = resolveOuroborosSelection(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser
    )

    static var mcpURL: URL? {
        switch ouroborosSelection {
        case .explicit(let url): return url
        case .sharedDefault: return sharedOuroborosEndpoint
        case .disabled, .invalid: return nil
        }
    }

    static func resolveOuroborosSelection(
        arguments: [String],
        environment: [String: String],
        homeDirectory: URL
    ) -> OuroborosLaunchSelection {
        if arguments.contains("--no-ouroboros") { return .disabled }

        let explicitURL: String?
        if arguments.contains("--mcp-url") {
            guard let value = value(after: "--mcp-url", in: arguments), !value.isEmpty else {
                return .invalid("--mcp-url requires a value")
            }
            explicitURL = value
        } else {
            explicitURL = environment["OUROCODE_MCP_URL"]
        }
        if let explicitURL {
            guard let url = URL(string: explicitURL), validExplicitMCPURL(url) else {
                return .invalid("The explicit MCP URL is not a safe loopback HTTP endpoint")
            }
            return .explicit(url)
        }

        let ouroborosOverride = absoluteExecutableOverride(
            flag: "--ouroboros-executable",
            environmentKey: "OUROCODE_OUROBOROS_EXECUTABLE",
            arguments: arguments,
            environment: environment
        )
        if case .failure(let reason) = ouroborosOverride { return .invalid(reason) }
        let uvxOverride = absoluteExecutableOverride(
            flag: "--uvx-executable",
            environmentKey: "OUROCODE_UVX_EXECUTABLE",
            arguments: arguments,
            environment: environment
        )
        if case .failure(let reason) = uvxOverride { return .invalid(reason) }

        return .sharedDefault(
            autoStartSharedService: !arguments.contains("--attach-shared-ouroboros-only"),
            ouroborosExecutable: ouroborosOverride.value ?? homeDirectory.appendingPathComponent(".local/bin/ouroboros"),
            uvxExecutable: uvxOverride.value ?? homeDirectory.appendingPathComponent(".local/bin/uvx")
        )
    }

    static let initialCommand: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--command"), index + 1 < arguments.count else {
            return nil
        }
        let command = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }()

    /// Explicit shell selection is useful for deterministic QA and for users
    /// whose login shell has environment-specific startup requirements. The
    /// ordinary product path remains the account's configured login shell.
    static let shellOverride: String? = {
        let arguments = ProcessInfo.processInfo.arguments
        let candidate: String?
        if let index = arguments.firstIndex(of: "--shell"), index + 1 < arguments.count {
            candidate = arguments[index + 1]
        } else {
            candidate = ProcessInfo.processInfo.environment["OUROCODE_SHELL"]
        }
        guard let candidate else { return nil }
        let expanded = (candidate as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: expanded) else { return nil }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }()

    static let shell: String = {
        if let shellOverride { return shellOverride }
        if let record = getpwuid(getuid()), let value = record.pointee.pw_shell {
            let accountShell = String(cString: value)
            if accountShell.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: accountShell) {
                return accountShell
            }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }()

    /// A login shell must not inherit an arbitrarily large launcher PATH from
    /// an IDE or agent host. macOS `/etc/zprofile` and the user's `.zprofile`
    /// expand this deterministic bootstrap before `.zshrc` is evaluated.
    static let loginBootstrapPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// Environment owned by the terminal contract. The broker intentionally
    /// inherits the rest of the user's launch environment; these values are
    /// the small, deterministic set a real interactive terminal must provide.
    static func terminalEnvironment(
        shell: String,
        accountLoginShell: Bool,
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        appVersion: String? = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
    ) -> [String: String] {
        let terminalVersion = appVersion.flatMap { $0.isEmpty ? nil : $0 } ?? "dev"
        var environment = [
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Ourocode",
            "TERM_PROGRAM_VERSION": terminalVersion,
            "OUROCODE_DESKTOP": "1",
            "SHELL": shell,
        ]
        if accountLoginShell {
            environment["PATH"] = loginBootstrapPath
        }
        // Finder launches commonly omit locale variables. macOS zsh and the
        // UTF-8 terminal grid must agree before .zshrc, prompt themes, or an
        // input method emit their first grapheme.
        let localeKeys = ["LC_ALL", "LC_CTYPE", "LANG"]
        if !localeKeys.contains(where: { inherited[$0]?.isEmpty == false }) {
            environment["LC_CTYPE"] = "UTF-8"
        }
        return environment
    }

    static let projectDirectory: String = {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--project-dir"), index + 1 < arguments.count {
            return normalizedDirectory(arguments[index + 1])
        }
        if let configured = ProcessInfo.processInfo.environment["OUROCODE_PROJECT_DIR"], !configured.isEmpty {
            return normalizedDirectory(configured)
        }

        let current = FileManager.default.currentDirectoryPath
        if current != "/" {
            return normalizedDirectory(current)
        }
        return FileManager.default.homeDirectoryForCurrentUser.path
    }()

    static let displayProjectDirectory: String = {
        (projectDirectory as NSString).abbreviatingWithTildeInPath
    }()

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    private static func validExplicitMCPURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host?.lowercased(), ["127.0.0.1", "localhost", "::1"].contains(host),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        return !url.path.isEmpty
    }

    private static func absoluteExecutableOverride(
        flag: String,
        environmentKey: String,
        arguments: [String],
        environment: [String: String]
    ) -> ExecutableOverrideResult {
        let raw: String?
        if arguments.contains(flag) {
            guard let value = value(after: flag, in: arguments), !value.isEmpty else {
                return .failure("\(flag) requires an absolute path")
            }
            raw = value
        } else {
            raw = environment[environmentKey]
        }
        guard let raw else { return .success(nil) }
        guard raw.hasPrefix("/") else { return .failure("\(flag) requires an absolute path") }
        return .success(URL(fileURLWithPath: raw).standardizedFileURL)
    }

    private static func normalizedDirectory(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            return FileManager.default.homeDirectoryForCurrentUser.path
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}

private enum ExecutableOverrideResult {
    case success(URL?)
    case failure(String)

    var value: URL? {
        guard case .success(let value) = self else { return nil }
        return value
    }
}
