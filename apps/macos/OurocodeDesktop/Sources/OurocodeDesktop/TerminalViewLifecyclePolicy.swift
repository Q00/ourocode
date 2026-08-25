import Foundation

/// Closing a projection and destroying its broker-owned process are different
/// user intents. Keep this type UI-independent so every close path (button,
/// menu, recovery callback, reconnect) is forced through the same contract.
enum TerminalViewDisposition: String, Equatable {
    /// Release this app's attachment and forget only the local projection.
    /// The stable broker terminal remains eligible for exact-ID recovery.
    case closeView

    /// Release any attachment, then explicitly terminate the broker terminal.
    /// This is irreversible and must only be entered after user confirmation.
    case terminateSession
}

struct TerminalViewLifecycleSnapshot: Equatable {
    let hasStableTerminalIdentity: Bool
    let hasAttachment: Bool
    let attachmentPreparationInFlight: Bool
    let creationInFlight: Bool
    let creationOutcomeUnknown: Bool
}

enum TerminalViewLifecycleAction: Equatable {
    /// Wait until create/list reconciliation proves whether a terminal exists.
    case waitForStableIdentity
    /// Cancel or abort recovery and wait for its completion callback. A late
    /// successful commit is handled by the next `.detachAttachment` action.
    case cancelAttachmentPreparation
    /// Cross the exact lease-aware FIFO detach barrier before removing UI.
    case detachAttachment
    /// Remove local UI and retain the broker-owned terminal.
    case removeView
    /// Send the explicit destructive broker operation.
    case terminateSession
}

enum TerminalViewLifecyclePolicy {
    static func nextAction(
        disposition: TerminalViewDisposition,
        snapshot: TerminalViewLifecycleSnapshot
    ) -> TerminalViewLifecycleAction {
        if snapshot.hasAttachment {
            return .detachAttachment
        }
        if snapshot.attachmentPreparationInFlight {
            return .cancelAttachmentPreparation
        }
        if !snapshot.hasStableTerminalIdentity,
           snapshot.creationInFlight || snapshot.creationOutcomeUnknown {
            return .waitForStableIdentity
        }
        if disposition == .terminateSession, snapshot.hasStableTerminalIdentity {
            return .terminateSession
        }
        return .removeView
    }
}
