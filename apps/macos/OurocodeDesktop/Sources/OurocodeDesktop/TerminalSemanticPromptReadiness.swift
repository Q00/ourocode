import Foundation

/// Tracks optional shell semantics without making them an input prerequisite.
///
/// A valid first frame and broker attachment are the terminal's input
/// authority. OSC 133 row/cell metadata may arrive later (Powerlevel10k,
/// instant-prompt, and user plugins are allowed to delay or omit it), so it is
/// recorded as an enhancement rather than a reason to hide or lock a usable
/// terminal.
struct TerminalSemanticPromptReadiness: Equatable {
  enum Observation: Equatable {
    case waiting
    case opened
    case alreadyOpened
    case ignoredStale
  }

  private(set) var tabID: UUID?
  private(set) var generation: UInt64?
  private(set) var semanticRequirementSatisfied = false
  private(set) var activationIssued = false

  mutating func begin(
    tabID: UUID,
    generation: UInt64,
    requiresSemanticPrompt: Bool,
    previouslyObserved: Bool
  ) {
    self.tabID = tabID
    self.generation = generation
    semanticRequirementSatisfied = !requiresSemanticPrompt || previouslyObserved
    activationIssued = false
  }

  mutating func reset() {
    tabID = nil
    generation = nil
    semanticRequirementSatisfied = false
    activationIssued = false
  }

  /// A pane runtime that has already crossed its own first-frame and broker
  /// activation barriers can be promoted into the tab's primary surface. The
  /// promotion must not wait for a second OSC 133 prompt from the shell.
  mutating func recordDirectActivation(tabID: UUID, generation: UInt64) {
    self.tabID = tabID
    self.generation = generation
    semanticRequirementSatisfied = true
    activationIssued = true
  }

  /// Returns `.opened` exactly once for a valid tab/generation. Later complete
  /// OSC 133 metadata is retained but never revokes terminal input authority.
  mutating func observe(
    tabID: UUID,
    generation: UInt64,
    hasSemanticPrompt: Bool,
    hasSemanticInput: Bool
  ) -> Observation {
    guard self.tabID == tabID, self.generation == generation else {
      return .ignoredStale
    }
    if !activationIssued {
      activationIssued = true
      if hasSemanticPrompt && hasSemanticInput {
        semanticRequirementSatisfied = true
      }
      return .opened
    }
    if hasSemanticPrompt && hasSemanticInput {
      semanticRequirementSatisfied = true
    }
    return .alreadyOpened
  }
}
