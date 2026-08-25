import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum TerminalTabPresentationFixture {
  static func main() {
    let home = "/Users/person"
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "zsh",
        shellProvidedTitle: false,
        path: home,
        homePath: home,
        displaySequence: 7
      ) == "Shell 7",
      "an idle home-directory shell exposed an implementation-like tilde ordinal"
    )
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "zsh",
        shellProvidedTitle: false,
        path: "\(home)/Project/ourocode",
        homePath: home,
        displaySequence: 3
      ) == "ourocode · 3",
      "a project shell lost its useful location"
    )
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "codex — RFC review",
        shellProvidedTitle: true,
        path: home,
        homePath: home,
        displaySequence: 2
      ) == "codex — RFC review",
      "a shell-provided semantic title was replaced"
    )
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "codex",
        shellProvidedTitle: true,
        path: "\(home)/Project/ourocode",
        homePath: home,
        displaySequence: 9
      ) == "codex · ourocode",
      "a bare foreground process title did not retain its project identity"
    )
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "jaegyu.lee@jaegyulee",
        shellProvidedTitle: true,
        path: "\(home)/Project/ourocode",
        homePath: home,
        displaySequence: 4
      ) == "ourocode",
      "host-shaped shell titles were not reduced to the working directory"
    )
    let binding = TerminalSessionBinding(
      surface: OuroborosPTYSurfaceBindingV1(
        identity: TerminalSessionLeafIdentity(
          sourceID: "ouroboros",
          sessionID: "session-a",
          executionID: "execution-a",
          scopeID: "scope-a",
          attemptID: "attempt-a"
        ),
        terminalID: "pty-1",
        brokerGeneration: 7
      ),
      label: "Renderer review",
      status: "running",
      depth: 0
    )
    require(
      TerminalTabPresentation.displayTitle(
        shellTitle: "zsh",
        shellProvidedTitle: false,
        path: home,
        homePath: home,
        displaySequence: 10,
        sessionBinding: binding
      ) == "Renderer review",
      "an exact session binding did not replace the generic Shell label"
    )
    print("PASS: terminal tabs use human labels while preserving semantic shell titles")
  }
}
