import Foundation

/// Immutable identity captured when a pane schedules a callback or input event.
///
/// A tab switch, pane replacement, broker reconnect, terminal reassignment, or
/// attachment lease change creates a different token. Consumers must compare
/// the complete token on the main queue before mutating UI or sending input.
struct PaneProjectionToken: Equatable, Hashable, Sendable {
    let tabID: UUID
    let tabProjectionGeneration: UInt64
    let paneID: UUID
    let paneGeneration: UInt64
    let terminalID: String
    let brokerGeneration: UInt64
    let attachmentIdentity: PaneAttachmentIdentityToken

    /// Capture a pane callback token from a real broker attachment. The
    /// attachment's fileprivate connection authority is projected by the
    /// narrow value factory in BrokerClient.swift and is never re-entered here.
    init?(
        tabID: UUID,
        tabProjectionGeneration: UInt64,
        paneID: UUID,
        paneGeneration: UInt64,
        attachment: BrokerAttachment,
        surfaceInstanceID: UUID,
        runtimeGeneration: UInt64
    ) {
        guard let attachmentIdentity = attachment.paneProjectionIdentity(
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        ) else {
            return nil
        }
        self.tabID = tabID
        self.tabProjectionGeneration = tabProjectionGeneration
        self.paneID = paneID
        self.paneGeneration = paneGeneration
        terminalID = attachmentIdentity.terminalID
        brokerGeneration = attachmentIdentity.brokerGeneration
        self.attachmentIdentity = attachmentIdentity
        guard isInternallyConsistent else { return nil }
    }

    fileprivate var isInternallyConsistent: Bool {
        tabID != Self.zeroUUID
            && tabProjectionGeneration > 0
            && paneID != Self.zeroUUID
            && paneGeneration > 0
            && !terminalID.isEmpty
            && brokerGeneration > 0
            && !attachmentIdentity.leaseID.isEmpty
            && attachmentIdentity.terminalID == terminalID
            && attachmentIdentity.brokerGeneration > 0
            && attachmentIdentity.brokerGeneration == brokerGeneration
            && attachmentIdentity.connectionID != Self.zeroUUID
            && attachmentIdentity.inputEpoch > 0
            && attachmentIdentity.surfaceInstanceID != Self.zeroUUID
            && attachmentIdentity.runtimeGeneration > 0
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

/// Identity of one resize transaction, separated from input/render authority.
///
/// `layoutEpoch` belongs to broker resize ordering, not to the lifetime of an
/// attachment or Metal surface. Keeping it out of PaneProjectionToken allows a
/// resize to advance without revoking otherwise-current input authority.
struct PaneResizeTransactionToken: Equatable, Hashable, Sendable {
    let projectionToken: PaneProjectionToken
    let layoutEpoch: UInt64

    init?(projectionToken: PaneProjectionToken, layoutEpoch: UInt64) {
        guard projectionToken.isInternallyConsistent, layoutEpoch > 0 else {
            return nil
        }
        self.projectionToken = projectionToken
        self.layoutEpoch = layoutEpoch
    }

    fileprivate var isInternallyConsistent: Bool {
        projectionToken.isInternallyConsistent && layoutEpoch > 0
    }
}

/// Fail-closed comparison for callbacks crossing a pane projection boundary.
enum PaneProjectionTokenGuard {
    static func accepts(
        _ callbackToken: PaneProjectionToken,
        current currentToken: PaneProjectionToken?
    ) -> Bool {
        guard let currentToken,
              callbackToken.isInternallyConsistent,
              currentToken.isInternallyConsistent
        else {
            return false
        }

        // Keep this as whole-value equality. Adding a new identity component
        // to PaneProjectionToken automatically makes it part of the guard.
        return callbackToken == currentToken
    }
}

/// Fail-closed comparison for callbacks crossing a broker resize boundary.
enum PaneResizeTransactionTokenGuard {
    static func accepts(
        _ callbackToken: PaneResizeTransactionToken,
        current currentToken: PaneResizeTransactionToken?
    ) -> Bool {
        guard let currentToken,
              callbackToken.isInternallyConsistent,
              currentToken.isInternallyConsistent else {
            return false
        }
        return callbackToken == currentToken
    }
}
