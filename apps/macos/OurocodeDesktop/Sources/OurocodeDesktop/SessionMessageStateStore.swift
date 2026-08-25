import Foundation

struct SessionMessageAuthorityV1: Equatable {
    let brokerGeneration: UInt64
    let authorityEpoch: UInt64
    let bindingID: String
}

enum SessionMessageCapabilityStateV1: Equatable {
    case unavailable(reason: String)
    case verifying
    case ready(SessionMessageAuthorityV1)
    case revoked(reason: String)

    var authority: SessionMessageAuthorityV1? {
        guard case .ready(let authority) = self else { return nil }
        return authority
    }

    var composerExplanation: String {
        switch self {
        case .unavailable(let reason): return "Read-only · \(reason)"
        case .verifying: return "Read-only · Verifying desktop authority…"
        case .ready: return "Ready for authenticated next-turn delivery"
        case .revoked(let reason): return "Read-only · Authority revoked · \(reason)"
        }
    }

    static func negotiate(
        advertisedCapabilities: Set<String>,
        reciprocalPeerVerified: Bool,
        durableBindingAcknowledged: Bool,
        knownVectorVerified: Bool,
        authority: SessionMessageAuthorityV1?
    ) -> SessionMessageCapabilityStateV1 {
        let missing = SessionMessageContractV1.requiredCapabilities.subtracting(advertisedCapabilities)
        guard missing.isEmpty else {
            return .unavailable(reason: "Authenticated session messaging is not advertised")
        }
        guard reciprocalPeerVerified, durableBindingAcknowledged, knownVectorVerified else {
            return .verifying
        }
        guard let authority, authority.brokerGeneration > 0 else {
            return .unavailable(reason: "No durable desktop authority")
        }
        return .ready(authority)
    }
}

struct SessionMessageDraftKeyV1: Hashable {
    let sourceID: String
    let targetSessionID: String
    let expectedExecutionID: String?
}

enum SessionMessageEffectV1: Equatable {
    case editing
    case submitting(requestNonce: String)
    case receipt(SessionMessageReceiptV1)
    case rejected(code: SessionMessageErrorCodeV1, message: String, requestNonce: String)
    case deliveryUncertain(requestNonce: String, explanation: String)

    var unresolvedNonce: String? {
        switch self {
        case .submitting(let nonce), .rejected(_, _, let nonce), .deliveryUncertain(let nonce, _): return nonce
        case .receipt(let receipt) where !receipt.state.isTerminal: return receipt.requestNonce
        case .receipt, .editing: return nil
        }
    }

    var permitsNewSend: Bool {
        switch self {
        case .editing, .rejected: true
        case .receipt(let receipt): receipt.state.isTerminal
        case .submitting, .deliveryUncertain: false
        }
    }
}

struct SessionMessageDraftRecordV1: Equatable {
    var draft: String
    var effect: SessionMessageEffectV1
}

/// In-memory UI state only. Ouroboros owns durable truth; this store preserves
/// a nonce across ambiguous local outcomes so reconnect/status never creates a
/// second effect by accident.
struct SessionMessageStateStoreV1 {
    private(set) var records: [SessionMessageDraftKeyV1: SessionMessageDraftRecordV1] = [:]

    subscript(key: SessionMessageDraftKeyV1) -> SessionMessageDraftRecordV1 {
        records[key] ?? SessionMessageDraftRecordV1(draft: "", effect: .editing)
    }

    mutating func updateDraft(_ draft: String, for key: SessionMessageDraftKeyV1) {
        var record = self[key]
        guard record.effect.permitsNewSend else { return }
        record.draft = draft
        if case .receipt = record.effect { record.effect = .editing }
        records[key] = record
    }

    mutating func begin(_ request: SessionMessageRequestV1, for key: SessionMessageDraftKeyV1) throws {
        var record = self[key]
        guard record.effect.permitsNewSend else { throw SessionMessageStateStoreError.outcomeUnresolved }
        guard request.targetSessionID == key.targetSessionID,
              request.expectedExecutionID == key.expectedExecutionID else {
            throw SessionMessageStateStoreError.targetMismatch
        }
        _ = try request.wireData()
        record.draft = request.message
        record.effect = .submitting(requestNonce: request.requestNonce)
        records[key] = record
    }

    mutating func receive(_ reply: SessionMessageReplyV1, for key: SessionMessageDraftKeyV1) throws {
        var record = self[key]
        guard let pendingNonce = record.effect.pendingNonceForResolution else {
            throw SessionMessageStateStoreError.noPendingRequest
        }
        switch reply {
        case .receipt(let receipt):
            guard receipt.requestNonce == pendingNonce else { throw SessionMessageStateStoreError.nonceMismatch }
            record.effect = receipt.state == .deliveryUncertain
                ? .deliveryUncertain(requestNonce: receipt.requestNonce, explanation: "Delivery outcome is unknown; check status")
                : .receipt(receipt)
            if receipt.state == .completed { record.draft = "" }
        case .failure(let error):
            if error.code == .outcomeUnknown || error.code == .upstreamUnavailable {
                record.effect = .deliveryUncertain(requestNonce: pendingNonce, explanation: error.message)
            } else {
                record.effect = .rejected(code: error.code, message: error.message, requestNonce: pendingNonce)
            }
        }
        records[key] = record
    }

    mutating func transportOutcomeUnknown(for key: SessionMessageDraftKeyV1, explanation: String) throws {
        var record = self[key]
        guard case .submitting(let nonce) = record.effect else {
            throw SessionMessageStateStoreError.noPendingRequest
        }
        record.effect = .deliveryUncertain(requestNonce: nonce, explanation: explanation)
        records[key] = record
    }

    func statusRequest(id: UInt64, authority: SessionMessageAuthorityV1, for key: SessionMessageDraftKeyV1) throws -> SessionMessageStatusRequestV1 {
        guard let nonce = self[key].effect.unresolvedNonce else {
            throw SessionMessageStateStoreError.noPendingRequest
        }
        return SessionMessageStatusRequestV1(
            id: id,
            brokerGeneration: authority.brokerGeneration,
            authorityEpoch: authority.authorityEpoch,
            requestNonce: nonce
        )
    }

    mutating func revokeAuthority(reason: String) {
        for key in records.keys {
            guard var record = records[key] else { continue }
            if case .submitting(let nonce) = record.effect {
                record.effect = .deliveryUncertain(requestNonce: nonce, explanation: reason)
                records[key] = record
            }
        }
    }
}

private extension SessionMessageEffectV1 {
    var pendingNonceForResolution: String? {
        switch self {
        case .submitting(let nonce), .deliveryUncertain(let nonce, _): nonce
        case .receipt(let receipt) where !receipt.state.isTerminal: receipt.requestNonce
        default: nil
        }
    }
}

enum SessionMessageStateStoreError: Error, Equatable {
    case outcomeUnresolved
    case targetMismatch
    case noPendingRequest
    case nonceMismatch
}
