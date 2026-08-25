import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
enum TerminalSemanticPromptReadinessFixture {
  static func main() {
    let shellOne = UUID()
    let shellTwo = UUID()
    var gate = TerminalSemanticPromptReadiness()
    var openCount = 0

    gate.begin(
      tabID: shellOne,
      generation: 41,
      requiresSemanticPrompt: true,
      previouslyObserved: false
    )
    let instantPrompt = gate.observe(
      tabID: shellOne,
      generation: 41,
      hasSemanticPrompt: false,
      hasSemanticInput: false
    )
    if instantPrompt == .opened { openCount += 1 }
    require(instantPrompt == .opened, "valid first frame stayed locked behind optional OSC 133")

    let promptWithoutInput = gate.observe(
      tabID: shellOne,
      generation: 41,
      hasSemanticPrompt: true,
      hasSemanticInput: false
    )
    if promptWithoutInput == .opened { openCount += 1 }
    require(promptWithoutInput == .alreadyOpened, "late OSC 133 A reopened input authority")

    let completePrompt = gate.observe(
      tabID: shellOne,
      generation: 41,
      hasSemanticPrompt: true,
      hasSemanticInput: true
    )
    if completePrompt == .opened { openCount += 1 }
    require(completePrompt == .alreadyOpened, "late complete semantics reopened input authority")
    require(gate.semanticRequirementSatisfied, "complete OSC 133 metadata was not retained")

    let duplicatePrompt = gate.observe(
      tabID: shellOne,
      generation: 41,
      hasSemanticPrompt: true,
      hasSemanticInput: true
    )
    if duplicatePrompt == .opened { openCount += 1 }
    require(openCount == 1, "one semantic generation opened input more than once")

    gate.begin(
      tabID: shellTwo,
      generation: 42,
      requiresSemanticPrompt: true,
      previouslyObserved: false
    )
    let staleTab = gate.observe(
      tabID: shellOne,
      generation: 42,
      hasSemanticPrompt: true,
      hasSemanticInput: true
    )
    let staleGeneration = gate.observe(
      tabID: shellTwo,
      generation: 41,
      hasSemanticPrompt: true,
      hasSemanticInput: true
    )
    require(staleTab == .ignoredStale, "stale tab semantic observation was accepted")
    require(staleGeneration == .ignoredStale, "stale generation semantic observation was accepted")
    require(!gate.semanticRequirementSatisfied, "stale semantic observation changed readiness")

    let current = gate.observe(
      tabID: shellTwo,
      generation: 42,
      hasSemanticPrompt: true,
      hasSemanticInput: true
    )
    require(current == .opened && gate.activationIssued, "current tab/generation did not open")

    let restored = UUID()
    gate.begin(
      tabID: restored,
      generation: 43,
      requiresSemanticPrompt: false,
      previouslyObserved: false
    )
    let restoredFirstFrame = gate.observe(
      tabID: restored,
      generation: 43,
      hasSemanticPrompt: false,
      hasSemanticInput: false
    )
    require(restoredFirstFrame == .opened, "non-integrated restored tab was semantic-gated")

    gate.begin(
      tabID: shellOne,
      generation: 44,
      requiresSemanticPrompt: true,
      previouslyObserved: true
    )
    let previouslyReadyOffscreenPrompt = gate.observe(
      tabID: shellOne,
      generation: 44,
      hasSemanticPrompt: false,
      hasSemanticInput: false
    )
    require(
      previouslyReadyOffscreenPrompt == .opened,
      "previously-ready zsh tab re-gated when prompt scrolled offscreen"
    )

    let promoted = UUID()
    gate.recordDirectActivation(tabID: promoted, generation: 45)
    require(gate.tabID == promoted, "promotion did not bind the exact tab identity")
    require(gate.generation == 45, "promotion did not bind the exact transition generation")
    require(gate.activationIssued, "promotion did not preserve the existing input activation")
    require(gate.semanticRequirementSatisfied, "promotion incorrectly waited for OSC 133")

    print("PASS: first frame opens once, late semantics are retained, and stale observations are ignored")
  }
}
