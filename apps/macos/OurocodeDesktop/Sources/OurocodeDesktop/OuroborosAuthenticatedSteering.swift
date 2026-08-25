import Foundation
import CryptoKit

/// Structured receipt from Ouroboros Synapse. A successful MCP call means only
/// that the signal was accepted/queued unless the server's authoritative meta
/// explicitly proves application.
enum OuroborosSteeringReceiptState: String, Equatable {
    case requested
    case accepted
    case queued
    case delivering
    case applied
    case completed
    case rejected
    case deliveryUncertain = "delivery_uncertain"

    var isTerminal: Bool {
        switch self {
        case .completed, .rejected, .deliveryUncertain: true
        case .requested, .accepted, .queued, .delivering, .applied: false
        }
    }
}

/// One authoritative lifecycle projection for an immutable user steering
/// request. Request identity is retained because Ouroboros 0.51.6 exposes no
/// separate status tool: after the first durable receipt, replaying these same
/// arguments returns the current projection without enqueueing a second effect.
struct OuroborosSteeringReceipt: Equatable {
    let summary: String
    let state: OuroborosSteeringReceiptState?
    let applicationProven: Bool
    let signalID: String?
    let idempotencyKey: String?
    let target: OuroborosSteeringTargetV1?
    let message: String?
    let failureCode: String?
    let failureReason: String?
    let reply: String?
    let retryable: Bool?

    init(
        summary: String,
        state: OuroborosSteeringReceiptState?,
        applicationProven: Bool,
        signalID: String? = nil,
        idempotencyKey: String? = nil,
        target: OuroborosSteeringTargetV1? = nil,
        message: String? = nil,
        failureCode: String? = nil,
        failureReason: String? = nil,
        reply: String? = nil,
        retryable: Bool? = nil
    ) {
        self.summary = summary
        self.state = state
        self.applicationProven = applicationProven
        self.signalID = signalID
        self.idempotencyKey = idempotencyKey
        self.target = target
        self.message = message
        self.failureCode = failureCode
        self.failureReason = failureReason
        self.reply = reply
        self.retryable = retryable
    }

    var canRefreshLifecycle: Bool {
        signalID != nil
            && idempotencyKey != nil
            && target != nil
            && message != nil
            && state?.isTerminal == false
    }
}

enum OuroborosSteeringReceiptDecoder {
    static func decode(
        result: [String: Any],
        summary: String,
        requestTarget: OuroborosSteeringTargetV1? = nil,
        requestMessage: String? = nil,
        requestIdempotencyKey: String? = nil
    ) -> OuroborosSteeringReceipt {
        let meta = result["_meta"] as? [String: Any]
            ?? result["meta"] as? [String: Any]
            ?? [:]
        let state = (meta["state"] as? String).flatMap(OuroborosSteeringReceiptState.init(rawValue:))
        let metaSummary = meta["summary"] as? String
        let failureReason: String?
        if state == .rejected || state == .deliveryUncertain {
            failureReason = meta["detail"] as? String ?? metaSummary ?? summary
        } else {
            failureReason = nil
        }
        let applicationProven = meta["application_proven"] as? Bool == true
            && (state == .applied || state == .completed)
        return OuroborosSteeringReceipt(
            summary: metaSummary ?? summary,
            state: state,
            applicationProven: applicationProven,
            signalID: meta["signal_id"] as? String,
            idempotencyKey: meta["idempotency_key"] as? String ?? requestIdempotencyKey,
            target: requestTarget,
            message: requestMessage,
            failureCode: meta["rejection_code"] as? String ?? meta["failure_code"] as? String,
            failureReason: failureReason,
            reply: meta["reply"] as? String,
            retryable: meta["automatic_retry_allowed"] as? Bool ?? meta["retryable"] as? Bool
        )
    }
}

enum OuroborosSteeringReceiptPresentation {
    static func shouldShowHistory(inSessionWorkspace: Bool, receiptCount: Int) -> Bool {
        inSessionWorkspace && receiptCount > 0
    }

    static func historyText(_ receipts: [OuroborosSteeringReceipt]) -> String? {
        guard !receipts.isEmpty else { return nil }
        return receipts.suffix(4).map { receipt in
            let attempt = receipt.target?.attemptID ?? "unknown attempt"
            let signal = receipt.signalID ?? "unknown signal"
            let proof = receipt.applicationProven ? "application proven" : "application not proven"
            return "attempt \(attempt) · \(stateLabel(receipt.state)) · signal \(signal) · \(proof)"
        }.joined(separator: "\n")
    }

    static func text(_ receipt: OuroborosSteeringReceipt, priorCount: Int = 0) -> String {
        let state = stateLabel(receipt.state)
        var parts = [state]
        if let reason = receipt.failureReason, !reason.isEmpty { parts.append(reason) }
        else if let reply = receipt.reply, !reply.isEmpty { parts.append(reply) }
        else {
            let oneLine = receipt.summary.replacingOccurrences(of: "\n", with: " ")
            if !oneLine.isEmpty { parts.append(oneLine) }
        }
        if receipt.state == .rejected || receipt.state == .deliveryUncertain {
            switch receipt.retryable {
            case true: parts.append("Retry available")
            case false: parts.append("Do not retry")
            case nil: parts.append("Retryability not provided")
            }
        }
        if priorCount > 0 { parts.append("\(priorCount) earlier message\(priorCount == 1 ? "" : "s")") }
        let combined = parts.joined(separator: " · ")
        return combined.count <= 180 ? combined : String(combined.prefix(179)) + "…"
    }

    static func stateLabel(_ state: OuroborosSteeringReceiptState?) -> String {
        switch state {
        case .requested: "Requested"
        case .accepted: "Accepted"
        case .queued: "Queued"
        case .delivering: "Delivering"
        case .applied: "Applied"
        case .completed: "Completed"
        case .rejected: "Rejected"
        case .deliveryUncertain: "Delivery uncertain"
        case nil: "Received"
        }
    }
}

enum OuroborosSteeringReceiptPollingPolicy {
    static let maximumAttempts = 126
    private static let initialDelays: [TimeInterval] = [0.5, 0.8, 1.3, 2.1, 3.4, 5.0]

    static func delay(at attempt: Int) -> TimeInterval {
        guard attempt >= 0 else { return initialDelays[0] }
        return initialDelays[min(attempt, initialDelays.count - 1)]
    }

    static var maximumObservationSeconds: TimeInterval {
        (0..<maximumAttempts).reduce(0) { $0 + delay(at: $1) }
    }
}

/// Keeps one latest projection per immutable signal while retaining older
/// messages for the whole execution, including attempts that have since been
/// replaced in the live session tree.
struct OuroborosSteeringReceiptLedger: Equatable {
    private static let maximumExecutions = 8
    private static let maximumReceiptsPerExecution = 32
    private(set) var receiptsByExecution: [String: [OuroborosSteeringReceipt]] = [:]
    private var executionOrder: [String] = []

    mutating func record(_ receipt: OuroborosSteeringReceipt) {
        guard let executionID = receipt.target?.executionID,
              let signalID = receipt.signalID else { return }
        var records = receiptsByExecution[executionID] ?? []
        if records.isEmpty { executionOrder.append(executionID) }
        if let index = records.firstIndex(where: { $0.signalID == signalID }) {
            records[index] = receipt
        } else {
            records.append(receipt)
        }
        receiptsByExecution[executionID] = Array(records.suffix(Self.maximumReceiptsPerExecution))
        while executionOrder.count > Self.maximumExecutions {
            receiptsByExecution[executionOrder.removeFirst()] = nil
        }
    }

    func priorMessageCount(for receipt: OuroborosSteeringReceipt) -> Int {
        guard let executionID = receipt.target?.executionID,
              let signalID = receipt.signalID else { return 0 }
        return receiptsByExecution[executionID, default: []]
            .filter { $0.signalID != signalID }
            .count
    }

    func receipts(executionID: String) -> [OuroborosSteeringReceipt] {
        receiptsByExecution[executionID] ?? []
    }
}

struct OuroborosSteeringTargetKeyRetention: Equatable {
    private let limit: Int
    private(set) var keys: [String] = []

    init(limit: Int = 256) {
        precondition(limit > 0)
        self.limit = limit
    }

    mutating func touch(_ key: String) -> [String] {
        keys.removeAll { $0 == key }
        keys.append(key)
        guard keys.count > limit else { return [] }
        return (0..<(keys.count - limit)).map { _ in keys.removeFirst() }
    }
}

struct OuroborosSteeringTargetV1: Equatable {
    let executionID: String
    let scopeID: String
    let attemptID: String
    let contractVersion: Int?
    let modes: Set<String>
}

enum OuroborosAuthenticatedSteeringV1 {
    static let maximumIdentifierBytes = 1_024
    static let maximumMessageBytes = 8_192

    static func toolArguments(
        target: OuroborosSteeringTargetV1,
        message: String,
        idempotencyKey: String,
        expiresAt: String? = nil
    ) -> [String: Any]? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard target.modes.contains("after_turn"),
              validIdentifier(target.executionID, maximumBytes: maximumIdentifierBytes),
              validIdentifier(target.scopeID, maximumBytes: maximumIdentifierBytes),
              validIdentifier(target.attemptID, maximumBytes: maximumIdentifierBytes),
              !trimmed.isEmpty,
              trimmed.utf8.count <= maximumMessageBytes,
              validIdentifier(idempotencyKey, maximumBytes: 256) else { return nil }
        if let expiresAt {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard !expiresAt.isEmpty, formatter.date(from: expiresAt) != nil else { return nil }
        }
        if let contractVersion = target.contractVersion, contractVersion < 1 { return nil }

        var arguments: [String: Any] = [
            "target_session_scope_id": target.scopeID,
            "target_session_attempt_id": target.attemptID,
            "expected_execution_id": target.executionID,
            "mode": "after_turn",
            "message": trimmed,
            "source": "user",
            "contract_effect": "additive",
            "reason": "User steering from Ourocode",
            "idempotency_key": idempotencyKey,
        ]
        if let expiresAt { arguments["expires_at"] = expiresAt }
        if let contractVersion = target.contractVersion {
            arguments["expected_contract_version"] = contractVersion
        }
        return arguments
    }

    /// Retries of one exact target/message produce the same durable signal ID.
    /// This prevents a lost HTTP reply from turning a user's retry into a
    /// duplicate effect. The exact attempt identity keeps later attempts free
    /// to receive the same prose as a new signal.
    static func idempotencyKey(target: OuroborosSteeringTargetV1, message: String) -> String? {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validIdentifier(target.executionID, maximumBytes: maximumIdentifierBytes),
              validIdentifier(target.scopeID, maximumBytes: maximumIdentifierBytes),
              validIdentifier(target.attemptID, maximumBytes: maximumIdentifierBytes),
              !trimmed.isEmpty,
              trimmed.utf8.count <= maximumMessageBytes else { return nil }
        var framed = Data("ourocode-steering-v1".utf8)
        for value in [target.executionID, target.scopeID, target.attemptID, trimmed] {
            var length = UInt64(value.utf8.count).bigEndian
            framed.append(Data(bytes: &length, count: MemoryLayout<UInt64>.size))
            framed.append(Data(value.utf8))
        }
        return "ourocode-" + SHA256.hash(data: framed).map { String(format: "%02x", $0) }.joined()
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }
}
