import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum LaunchConfigurationFixture {
    static func main() {
        let finderEnvironment = LaunchConfiguration.terminalEnvironment(
            shell: "/bin/zsh",
            accountLoginShell: true,
            inherited: [:],
            appVersion: "1.2.3"
        )
        require(finderEnvironment["TERM"] == "xterm-256color", "TERM contract changed")
        require(finderEnvironment["COLORTERM"] == "truecolor", "truecolor contract changed")
        require(finderEnvironment["TERM_PROGRAM"] == "Ourocode", "terminal identity missing")
        require(finderEnvironment["TERM_PROGRAM_VERSION"] == "1.2.3", "version missing")
        require(finderEnvironment["SHELL"] == "/bin/zsh", "shell identity missing")
        require(finderEnvironment["LC_CTYPE"] == "UTF-8", "Finder UTF-8 fallback missing")
        require(
            finderEnvironment["PATH"] == LaunchConfiguration.loginBootstrapPath,
            "login bootstrap PATH changed"
        )

        let localized = LaunchConfiguration.terminalEnvironment(
            shell: "/bin/zsh",
            accountLoginShell: false,
            inherited: ["LANG": "ko_KR.UTF-8"],
            appVersion: nil
        )
        require(localized["LC_CTYPE"] == nil, "existing user locale was overwritten")
        require(localized["PATH"] == nil, "explicit shell received login PATH policy")
        require(localized["TERM_PROGRAM_VERSION"] == "dev", "development version fallback changed")

        let home = URL(fileURLWithPath: "/Users/fixture")
        let automatic = LaunchConfiguration.resolveOuroborosSelection(
            arguments: ["Ourocode"],
            environment: [:],
            homeDirectory: home
        )
        require(
            automatic == .sharedDefault(
                autoStartSharedService: true,
                ouroborosExecutable: home.appendingPathComponent(".local/bin/ouroboros"),
                uvxExecutable: home.appendingPathComponent(".local/bin/uvx")
            ),
            "installed shared Ouroboros is not the default"
        )

        let attachOnly = LaunchConfiguration.resolveOuroborosSelection(
            arguments: ["Ourocode", "--attach-shared-ouroboros-only"],
            environment: [:],
            homeDirectory: home
        )
        guard case .sharedDefault(let autoStart, _, _) = attachOnly else {
            require(false, "attach-only selection changed kind")
            return
        }
        require(!autoStart, "attach-only mode would mutate launchd state")

        require(
            !LaunchConfiguration.enablesMCPV2CatalogFixture(arguments: ["Ourocode"]),
            "ordinary production launch enabled the catalog fixture"
        )
        require(
            !LaunchConfiguration.enablesMCPV2CatalogFixture(
                arguments: ["Ourocode", "--demo", "fanout-8"]
            ),
            "an unrelated demo mode enabled the second MCP source"
        )
        require(
            LaunchConfiguration.enablesMCPV2CatalogFixture(
                arguments: ["Ourocode", "--demo", "mcp-v2-catalog"]
            ),
            "the explicit MCP v2 catalog demo did not enable its fixture"
        )
        require(
            !LaunchConfiguration.enablesMCPV2CatalogFixture(
                arguments: ["Ourocode", "--demo", "--no-ouroboros"]
            ),
            "a missing demo value was interpreted as fixture authority"
        )
    }
}
