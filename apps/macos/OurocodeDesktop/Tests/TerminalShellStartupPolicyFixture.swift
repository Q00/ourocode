import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

@main
enum TerminalShellStartupPolicyFixture {
  static func main() {
    let tab = UUID()
    let identity = TerminalShellStartupIdentity(tabID: tab, generation: 17)
    require(TerminalShellStartupPolicy.isCurrent(identity, tabID: tab, generation: 17), "current identity rejected")
    require(!TerminalShellStartupPolicy.isCurrent(identity, tabID: UUID(), generation: 17), "stale tab accepted")
    require(!TerminalShellStartupPolicy.isCurrent(identity, tabID: tab, generation: 18), "stale generation accepted")
    require(TerminalShellLaunchMode.cleanZsh.executable == "/bin/zsh", "clean shell is not zsh")
    require(TerminalShellLaunchMode.cleanZsh.arguments == ["-f", "-i"], "clean shell reads startup files")
    require(!TerminalShellLaunchMode.cleanZsh.installsZshIntegration, "clean shell installs ZDOTDIR integration")
    require(TerminalShellLaunchMode.configured.installsZshIntegration, "configured shell lost integration")
    print("PASS: startup identity is exact and clean-shell recovery is isolated")
  }
}
