import Foundation

/// The exact session surface represented by the terminal pane that currently
/// owns the user's keyboard.  This is a routing hint, not steering authority:
/// the MCP projection and authenticated `after_turn` transport still decide
/// whether a message may be delivered.
struct SessionPaneSteeringFocus: Equatable {
    let terminalID: String
    let brokerGeneration: UInt64
    let binding: TerminalSessionBinding

    var leaf: TerminalSessionLeafIdentity { binding.leaf }
}

enum SessionPaneSteeringFocusPolicy {
    /// Resolve only an exact, unique terminal/generation join. A focused pane
    /// without a current binding deliberately returns nil; labels and pane
    /// order are not identities and must never steer a sibling attempt.
    static func resolve(
        focusedTerminalID: String?,
        brokerGeneration: UInt64?,
        bindings: some Sequence<TerminalSessionBinding>
    ) -> SessionPaneSteeringFocus? {
        guard let focusedTerminalID,
              !focusedTerminalID.isEmpty,
              let brokerGeneration,
              brokerGeneration > 0 else {
            return nil
        }
        let candidates = bindings.filter {
            $0.terminalID == focusedTerminalID
                && $0.brokerGeneration == brokerGeneration
        }
        guard candidates.count == 1, let binding = candidates.first else {
            return nil
        }
        return SessionPaneSteeringFocus(
            terminalID: focusedTerminalID,
            brokerGeneration: brokerGeneration,
            binding: binding
        )
    }
}

enum SessionPaneSteeringRejection: String, Equatable {
    case noFocusedPane
    case noExactBinding
    case staleBinding
    case targetMismatch
    case projectionUntrusted
    case afterTurnUnavailable
    case emptyDraft
    case transportUnavailable
}

enum SessionPaneSteeringSendResolution: Equatable {
    case allowed(exactDraftKey: String)
    case rejected(SessionPaneSteeringRejection)
}

/// Pure admission gate used by the composer and fixtures. Keeping this policy
/// separate from the adapter prevents a pane focus event from becoming a
/// hidden send and makes stale/ambiguous fanout state fail closed.
enum SessionPaneSteeringSendPolicy {
    static func resolve(
        focus: SessionPaneSteeringFocus?,
        targetIdentity: TerminalSessionLeafIdentity?,
        targetModes: Set<String>,
        projectionTrusted: Bool,
        authenticatedTransportReady: Bool,
        draft: String,
        exactDraftKey: String?
    ) -> SessionPaneSteeringSendResolution {
        guard let focus else { return .rejected(.noFocusedPane) }
        guard projectionTrusted else { return .rejected(.projectionUntrusted) }
        guard authenticatedTransportReady else { return .rejected(.transportUnavailable) }
        guard let targetIdentity, targetIdentity == focus.leaf else {
            return .rejected(.targetMismatch)
        }
        guard targetModes.contains("after_turn") else {
            return .rejected(.afterTurnUnavailable)
        }
        guard let exactDraftKey, !exactDraftKey.isEmpty else {
            return .rejected(.noExactBinding)
        }
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .rejected(.emptyDraft)
        }
        return .allowed(exactDraftKey: exactDraftKey)
    }
}

enum SessionFocusedAgentComposerOutcome: Equatable {
    case focusComposer
    case unavailable(String)
}

/// Human-facing result for the keyboard/menu action. Routing remains
/// fail-closed, but every refusal has a visible and speakable explanation.
enum SessionFocusedAgentComposerPolicy {
    static let noLinkedAgent = "No Ouroboros agent linked to this pane"

    static func resolve(
        hasFocusedBinding: Bool,
        focusedIdentityMatchesTarget: Bool,
        advertisesAfterTurn: Bool,
        projectionTrusted: Bool,
        authenticatedTransportReady: Bool
    ) -> SessionFocusedAgentComposerOutcome {
        guard hasFocusedBinding else { return .unavailable(noLinkedAgent) }
        guard focusedIdentityMatchesTarget else {
            return .unavailable("The linked Ouroboros agent is no longer available")
        }
        guard advertisesAfterTurn else {
            return .unavailable("This agent does not accept after-turn messages")
        }
        guard projectionTrusted else {
            return .unavailable("Ouroboros session link is being verified")
        }
        guard authenticatedTransportReady else {
            return .unavailable("Ouroboros messaging authority is unavailable")
        }
        return .focusComposer
    }
}
