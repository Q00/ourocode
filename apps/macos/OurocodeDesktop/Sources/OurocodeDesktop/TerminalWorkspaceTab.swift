#if OUROCODE_GHOSTTY_RENDERER
import Foundation

/// Errors raised while constructing the app-side workspace projection.
///
/// A workspace is deliberately a projection model: it does not create a PTY,
/// retain a broker attachment, or own a renderer.  The broker terminal ID is
/// the only runtime identity crossing into the layout tree.
enum TerminalWorkspaceTabError: Error, Equatable, LocalizedError {
    case emptyTerminalID
    case duplicateTerminalID(String)
    case unauthorizedTerminalID(String)
    case missingPane(String)
    case staleLayoutRevision(expected: UInt64, actual: UInt64)
    case invalidProjectionAuthority(String)
    case layoutIdentityMismatch

    var errorDescription: String? {
        switch self {
        case .emptyTerminalID:
            return "A workspace pane requires an exact broker terminal ID."
        case let .duplicateTerminalID(terminalID):
            return "The broker terminal ID \(terminalID) is already projected by another workspace."
        case let .unauthorizedTerminalID(terminalID):
            return "The broker did not authorize terminal ID \(terminalID) for this workspace mutation."
        case let .missingPane(terminalID):
            return "No pane is projected for broker terminal ID \(terminalID)."
        case let .staleLayoutRevision(expected, actual):
            return "The pane layout changed from revision \(expected) to \(actual) before this action completed."
        case let .invalidProjectionAuthority(terminalID):
            return "The current broker attachment cannot authorize pane \(terminalID)."
        case .layoutIdentityMismatch:
            return "The workspace model and split layout no longer describe the same terminal leaves."
        }
    }
}

/// Metadata needed to admit and identify a pane surface.  This is not an
/// attachment or a renderer allocation; the surface coordinator and broker
/// remain the owners of those authorities.
struct TerminalPaneAdmissionMetadata: Equatable, Sendable {
    let tier: PaneSurfaceAdmissionTier
    let paneGeneration: UInt64
}

/// The result of deciding how a one-leaf view should be removed.  Performing
/// either action remains the responsibility of TerminalHostViewController and
/// BrokerClient; this value only prevents close-view from being mistaken for
/// destructive session termination.
enum TerminalWorkspaceRemovalDecision: Equatable {
    case releaseView(terminalID: String)
    case terminateBrokerSession(terminalID: String)
}

/// A broker-terminal leaf in the workspace projection.
///
/// No PTY, renderer, attachment, process, scrollback, or socket is stored
/// here.  `generation` invalidates callbacks when this pane is replaced by a
/// future projection, while the exact terminal ID remains stable.
@MainActor
final class TerminalPane {
    let id: UUID
    let terminalID: String
    private(set) var generation: UInt64
    private let admissionTier: PaneSurfaceAdmissionTier
    var admission: TerminalPaneAdmissionMetadata {
        TerminalPaneAdmissionMetadata(tier: admissionTier, paneGeneration: generation)
    }

    init(
        terminalID: String,
        id: UUID = UUID(),
        generation: UInt64 = 1,
        tier: PaneSurfaceAdmissionTier = .normal
    ) throws {
        guard !terminalID.isEmpty else {
            throw TerminalWorkspaceTabError.emptyTerminalID
        }
        guard generation > 0 else {
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        }
        self.id = id
        self.terminalID = terminalID
        self.generation = generation
        admissionTier = tier
    }

    /// Invalidate callbacks captured before a pane projection replacement.
    func advanceGeneration() {
        generation &+= 1
        if generation == 0 { generation = 1 }
    }

    func projectionToken(
        tabID: UUID,
        tabGeneration: UInt64,
        attachment: BrokerAttachment,
        surfaceInstanceID: UUID,
        runtimeGeneration: UInt64
    ) -> PaneProjectionToken? {
        PaneProjectionToken(
            tabID: tabID,
            tabProjectionGeneration: tabGeneration,
            paneID: id,
            paneGeneration: generation,
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        )
    }
}

struct TerminalWorkspaceTabSnapshot: Equatable {
    let tabID: UUID
    let projectionGeneration: UInt64
    let layoutRevision: UInt64
    let focusedTerminalID: String
    let leaves: [TerminalSplitLeafGeometry]
    /// Presentation geometry may contain only the maximized focused leaf.
    /// `leaves` always retains the complete identity tree for authority checks.
    let presentationLeaves: [TerminalSplitLeafGeometry]
    let maximizedTerminalID: String?
}

/// One workspace tab backed by exact broker terminal leaves.
///
/// This model owns only split identity, focus, and pane generations. It never
/// creates a PTY, attachment, renderer, or process. The host must acquire a
/// broker terminal before admitting it here and must project one independently
/// authorized surface per visible leaf.
@MainActor
final class TerminalWorkspaceTab {
    let id: UUID
    let displaySequence: UInt64
    var title: String
    let layoutBridge: TerminalSplitLayoutBridge
    private(set) var panes: [String: TerminalPane]
    private(set) var focusedTerminalID: String
    private(set) var maximizedTerminalID: String?
    private(set) var projectionGeneration: UInt64 = 1

    init(
        terminalID: String,
        displaySequence: UInt64,
        title: String,
        occupiedTerminalIDs: Set<String> = [],
        tabID: UUID = UUID()
    ) throws {
        guard !terminalID.isEmpty else {
            throw TerminalWorkspaceTabError.emptyTerminalID
        }
        guard !occupiedTerminalIDs.contains(terminalID) else {
            throw TerminalWorkspaceTabError.duplicateTerminalID(terminalID)
        }
        id = tabID
        self.displaySequence = displaySequence
        self.title = title
        layoutBridge = try TerminalSplitLayoutBridge(initialTerminalID: terminalID)
        let pane = try TerminalPane(terminalID: terminalID)
        panes = [terminalID: pane]
        focusedTerminalID = terminalID
        maximizedTerminalID = nil
    }

    var paneCount: Int { panes.count }

    var canCloseFocusedPane: Bool { panes.count > 1 }

    var isFocusedPaneMaximized: Bool { maximizedTerminalID == focusedTerminalID }

    func canSplitFocused() throws -> Bool {
        guard maximizedTerminalID == nil else { return false }
        return try layoutBridge.canSplitFocused()
    }

    func pane(for terminalID: String) throws -> TerminalPane {
        guard let pane = panes[terminalID] else {
            throw TerminalWorkspaceTabError.missingPane(terminalID)
        }
        return pane
    }

    /// Return an immutable snapshot and assert that the model and Rust layout
    /// still have exactly the same terminal identity set.
    func snapshot() throws -> TerminalWorkspaceTabSnapshot {
        let layoutSnapshot = try layoutBridge.snapshot()
        let layoutIDs = Set(layoutSnapshot.leaves.map(\.terminalID))
        guard layoutIDs == Set(panes.keys),
              layoutSnapshot.focusedTerminalID == focusedTerminalID else {
            throw TerminalWorkspaceTabError.layoutIdentityMismatch
        }
        let presentationLeaves: [TerminalSplitLeafGeometry]
        if let maximizedTerminalID,
           let maximized = layoutSnapshot.leaves.first(where: {
               $0.terminalID == maximizedTerminalID
           }) {
            presentationLeaves = [TerminalSplitLeafGeometry(
                nodeID: maximized.nodeID,
                terminalID: maximized.terminalID,
                x: 0,
                y: 0,
                width: 1_000_000,
                height: 1_000_000
            )]
        } else {
            presentationLeaves = layoutSnapshot.leaves
        }
        return TerminalWorkspaceTabSnapshot(
            tabID: id,
            projectionGeneration: projectionGeneration,
            layoutRevision: layoutSnapshot.revision,
            focusedTerminalID: layoutSnapshot.focusedTerminalID,
            leaves: layoutSnapshot.leaves,
            presentationLeaves: presentationLeaves,
            maximizedTerminalID: maximizedTerminalID
        )
    }

    func focus(terminalID: String, expectedRevision: UInt64) throws {
        try requireCurrentRevision(expectedRevision)
        _ = try pane(for: terminalID)
        guard focusedTerminalID != terminalID else { return }
        try layoutBridge.focus(terminalID: terminalID)
        focusedTerminalID = terminalID
        if maximizedTerminalID != nil { maximizedTerminalID = terminalID }
        advanceProjectionGeneration()
    }

    /// Atomically admits a broker terminal as a new focused split leaf. The
    /// pane object is prepared before the Rust tree mutates; a rejected split
    /// therefore cannot leave the Swift pane map and layout out of sync.
    @discardableResult
    func splitFocused(
        axis: TerminalSplitAxis,
        newTerminalID: String,
        expectedRevision: UInt64,
        authoritativeTerminalIDs: Set<String>,
        placement: TerminalSplitPlacement = .after,
        tier: PaneSurfaceAdmissionTier = .normal
    ) throws -> UInt64 {
        try requireCurrentRevision(expectedRevision)
        guard authoritativeTerminalIDs.contains(newTerminalID),
              Set(panes.keys).isSubset(of: authoritativeTerminalIDs) else {
            throw TerminalWorkspaceTabError.unauthorizedTerminalID(newTerminalID)
        }
        guard !panes.keys.contains(newTerminalID) else {
            throw TerminalWorkspaceTabError.duplicateTerminalID(newTerminalID)
        }
        let pane = try TerminalPane(terminalID: newTerminalID, tier: tier)
        // A hidden tree must never be structurally mutated behind a maximized
        // presentation. The host disables this path; the model restores as a
        // final fail-safe before admitting the new authoritative leaf.
        maximizedTerminalID = nil
        let dividerNodeID = try layoutBridge.splitFocused(
            axis: axis,
            newTerminalID: newTerminalID,
            placement: placement
        )
        panes[newTerminalID] = pane
        focusedTerminalID = newTerminalID
        advanceProjectionGeneration()
        _ = try snapshot()
        return dividerNodeID
    }

    /// Moves focus using the Rust tree's spatial policy. Focus changes revoke
    /// prior pane projection tokens before the host hands input to the new
    /// leaf; a blocked move leaves the generation untouched.
    @discardableResult
    func moveFocus(
        _ direction: TerminalSplitFocusDirection,
        expectedRevision: UInt64
    ) throws -> TerminalSplitFocusChange {
        try requireCurrentRevision(expectedRevision)
        let change = try layoutBridge.moveFocus(direction)
        guard change.moved else { return change }
        _ = try pane(for: change.focusedTerminalID)
        focusedTerminalID = change.focusedTerminalID
        if maximizedTerminalID != nil { maximizedTerminalID = change.focusedTerminalID }
        advanceProjectionGeneration()
        _ = try snapshot()
        return change
    }

    /// Removes only the local pane projection. Broker PTY termination remains
    /// an explicit host decision and is never implied by closing a split view.
    @discardableResult
    func closePane(terminalID: String, expectedRevision: UInt64) throws -> String {
        try requireCurrentRevision(expectedRevision)
        let closingPane = try pane(for: terminalID)
        try layoutBridge.close(terminalID: terminalID)
        closingPane.advanceGeneration()
        panes.removeValue(forKey: terminalID)
        let layoutSnapshot = try layoutBridge.snapshot()
        focusedTerminalID = layoutSnapshot.focusedTerminalID
        if maximizedTerminalID == terminalID { maximizedTerminalID = nil }
        advanceProjectionGeneration()
        _ = try snapshot()
        return focusedTerminalID
    }

    /// Restores all recursive divider ratios. This mutates only the layout
    /// projection; renderer and broker owners consume the returned resize
    /// intent after recomputing their own final cell geometry.
    @discardableResult
    func equalize(expectedRevision: UInt64) throws -> TerminalSplitResizeIntent? {
        try requireCurrentRevision(expectedRevision)
        let wasMaximized = maximizedTerminalID != nil
        maximizedTerminalID = nil
        let intent = try layoutBridge.equalize()
        if intent != nil || wasMaximized { advanceProjectionGeneration() }
        _ = try snapshot()
        return intent
    }

    /// Maximization is presentation-only: all PTYs, renderer identities, and
    /// the recursive Rust tree remain alive and unchanged for O(1) restore.
    func maximizeFocused(expectedRevision: UInt64) throws {
        try requireCurrentRevision(expectedRevision)
        guard panes.count > 1, maximizedTerminalID != focusedTerminalID else { return }
        maximizedTerminalID = focusedTerminalID
        advanceProjectionGeneration()
        _ = try snapshot()
    }

    func restoreMaximized(expectedRevision: UInt64) throws {
        try requireCurrentRevision(expectedRevision)
        guard maximizedTerminalID != nil else { return }
        maximizedTerminalID = nil
        advanceProjectionGeneration()
        _ = try snapshot()
    }

    func toggleMaximizeFocused(expectedRevision: UInt64) throws {
        if isFocusedPaneMaximized {
            try restoreMaximized(expectedRevision: expectedRevision)
        } else {
            try maximizeFocused(expectedRevision: expectedRevision)
        }
    }

    private func requireCurrentRevision(_ expectedRevision: UInt64) throws {
        let actualRevision = try layoutBridge.snapshot().revision
        guard expectedRevision == actualRevision else {
            throw TerminalWorkspaceTabError.staleLayoutRevision(
                expected: expectedRevision,
                actual: actualRevision
            )
        }
    }

    func projectionToken(
        for terminalID: String,
        attachment: BrokerAttachment,
        surfaceInstanceID: UUID,
        runtimeGeneration: UInt64
    ) throws -> PaneProjectionToken {
        let pane = try pane(for: terminalID)
        guard attachment.terminal.id == terminalID,
              let token = pane.projectionToken(
            tabID: id,
            tabGeneration: projectionGeneration,
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        ) else {
            throw TerminalWorkspaceTabError.invalidProjectionAuthority(terminalID)
        }
        return token
    }

    func advanceProjectionGeneration() {
        projectionGeneration &+= 1
        if projectionGeneration == 0 { projectionGeneration = 1 }
    }

    /// Decide the non-destructive or destructive path for this exact leaf.
    /// The one-leaf layout remains intact until the host completes its normal
    /// detach/terminate lifecycle; this method never mutates broker state.
    func removalDecision(
        for terminalID: String,
        disposition: TerminalViewDisposition
    ) throws -> TerminalWorkspaceRemovalDecision {
        _ = try pane(for: terminalID)
        switch disposition {
        case .closeView:
            return .releaseView(terminalID: terminalID)
        case .terminateSession:
            return .terminateBrokerSession(terminalID: terminalID)
        }
    }
}
#endif
