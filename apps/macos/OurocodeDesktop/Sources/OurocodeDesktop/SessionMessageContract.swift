import CryptoKit
import Foundation

/// Closed desktop value contract for RFC 0005. This file intentionally owns
/// no socket and cannot create authority; transport admission remains a broker
/// responsibility.
enum SessionMessageContractV1 {
    static let version: UInt64 = 1
    static let maximumMessageBytes = 8_192
    static let maximumReasonBytes = 1_000
    static let maximumReplyBytes = 1_000
    static let maximumIDBytes = 256
    static let maximumErrorBytes = 1_000
    static let maximumWireFrameBytes = 32 * 1_024
    static let maximumReceiptBytes = 16 * 1_024
    static let requiredCapabilities: Set<String> = [
        "mcp.session_message.authenticated.v1",
        "session.message.resolve_admit.v1",
        "session.message.status.v1",
        "session.message.receipt_cursor.v1",
    ]
}

enum SessionMessageModeV1: String, Equatable {
    case afterTurn = "after_turn"
}

struct SessionMessageRequestV1: Equatable {
    let id: UInt64
    let brokerGeneration: UInt64
    let authorityEpoch: UInt64
    let requestNonce: String
    let targetSessionID: String
    let expectedExecutionID: String?
    let expectedTargetGeneration: UInt64?
    let mode: SessionMessageModeV1
    let message: String
    let reason: String
    let expiresAt: String
    let correlationID: String?

    func wireData() throws -> Data {
        guard id > 0, brokerGeneration > 0 else { throw SessionMessageContractError.invalidInteger }
        try SessionMessageWireValue.validateNonce(requestNonce)
        try SessionMessageWireValue.validateID(targetSessionID)
        try expectedExecutionID.map(SessionMessageWireValue.validateID)
        try SessionMessageWireValue.validateText(message, maximumBytes: SessionMessageContractV1.maximumMessageBytes)
        try SessionMessageWireValue.validateText(reason, maximumBytes: SessionMessageContractV1.maximumReasonBytes)
        try SessionMessageWireValue.validateTimestamp(expiresAt)
        try correlationID.map(SessionMessageWireValue.validateID)
        var object: [String: Any] = [
            "version": SessionMessageContractV1.version,
            "id": id,
            "op": "session_message_resolve_and_admit",
            "broker_generation": brokerGeneration,
            "authority_epoch": authorityEpoch,
            "request_nonce": requestNonce,
            "target_session_id": targetSessionID,
            "mode": mode.rawValue,
            "message": message,
            "reason": reason,
            "expires_at": expiresAt,
        ]
        if let expectedExecutionID { object["expected_execution_id"] = expectedExecutionID }
        if let expectedTargetGeneration { object["expected_target_generation"] = expectedTargetGeneration }
        if let correlationID { object["correlation_id"] = correlationID }
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard data.count <= SessionMessageContractV1.maximumWireFrameBytes else {
            throw SessionMessageContractError.frameTooLarge
        }
        return data
    }
}

struct SessionMessageStatusRequestV1: Equatable {
    let id: UInt64
    let brokerGeneration: UInt64
    let authorityEpoch: UInt64
    let requestNonce: String

    func wireData() throws -> Data {
        guard id > 0, brokerGeneration > 0 else { throw SessionMessageContractError.invalidInteger }
        try SessionMessageWireValue.validateNonce(requestNonce)
        return try JSONSerialization.data(withJSONObject: [
            "version": SessionMessageContractV1.version,
            "id": id,
            "op": "session_message_status",
            "broker_generation": brokerGeneration,
            "authority_epoch": authorityEpoch,
            "request_nonce": requestNonce,
        ], options: [.sortedKeys])
    }
}

struct SessionMessageExactSessionIdentityV1: Equatable {
    let sessionID: String
    let executionID: String
    let scopeID: String
    let attemptID: String
    let generation: UInt64
}

enum SessionMessageExactSourceIdentityV1: Equatable {
    case user(principalID: String, authorityEpoch: UInt64)
    case session(SessionMessageExactSessionIdentityV1)
}

enum SessionMessageReceiptStateV1: String, Equatable {
    case queued
    case delivering
    case applied
    case completed
    case rejected
    case deliveryUncertain = "delivery_uncertain"

    var applicationProven: Bool { self == .applied || self == .completed }
    var isTerminal: Bool { self == .completed || self == .rejected }
}

struct SessionMessageReceiptV1: Equatable {
    let brokerGeneration: UInt64
    let id: UInt64
    let requestNonce: String
    let requestDigest: String
    let signalID: String
    let source: SessionMessageExactSourceIdentityV1
    let target: SessionMessageExactSessionIdentityV1
    let mode: SessionMessageModeV1
    let state: SessionMessageReceiptStateV1
    let durableCursor: UInt64
    let applicationProven: Bool
    let replayed: Bool
    let hopCount: UInt8
    let expiresAt: String
    let replySummary: String?
}

enum SessionMessageErrorCodeV1: String, Equatable {
    case badVersion = "bad_version"
    case badRequest = "bad_request"
    case unauthenticated
    case unauthorized
    case staleGeneration = "stale_generation"
    case staleAuthority = "stale_authority"
    case nonceConflict = "nonce_conflict"
    case sourceNotActive = "source_not_active"
    case targetNotFound = "target_not_found"
    case targetAmbiguous = "target_ambiguous"
    case targetNotActive = "target_not_active"
    case targetGenerationMismatch = "target_generation_mismatch"
    case receiptNotFound = "receipt_not_found"
    case crossForestDenied = "cross_forest_denied"
    case selfMessageDenied = "self_message_denied"
    case hopLimitExceeded = "hop_limit_exceeded"
    case capabilityUnsupported = "capability_unsupported"
    case expired
    case queueFull = "queue_full"
    case upstreamUnavailable = "upstream_unavailable"
    case outcomeUnknown = "outcome_unknown"
    case `internal`
}

struct SessionMessageErrorReplyV1: Equatable {
    let brokerGeneration: UInt64
    let id: UInt64
    let code: SessionMessageErrorCodeV1
    let message: String
}

enum SessionMessageReplyV1: Equatable {
    case receipt(SessionMessageReceiptV1)
    case failure(SessionMessageErrorReplyV1)
}

enum SessionMessageContractError: Error, Equatable, CustomStringConvertible {
    case malformedJSON
    case frameTooLarge
    case replyTooLarge
    case unknownOrMissingField
    case invalidInteger
    case invalidValue
    case identityMismatch
    case applicationProofMismatch
    case replyBeforeCompletion

    var description: String {
        switch self {
        case .malformedJSON: "Session message JSON is malformed"
        case .frameTooLarge: "Session message request exceeds its wire bound"
        case .replyTooLarge: "Session message reply exceeds its wire bound"
        case .unknownOrMissingField: "Session message value has unknown or missing fields"
        case .invalidInteger: "Session message integer is invalid"
        case .invalidValue: "Session message value violates the closed contract"
        case .identityMismatch: "Session message reply does not match this request"
        case .applicationProofMismatch: "Receipt application proof contradicts its state"
        case .replyBeforeCompletion: "Receipt includes a reply before completion"
        }
    }
}

enum SessionMessageWireCodecV1 {
    static func frame(_ payload: Data) throws -> Data {
        guard !payload.isEmpty, payload.count <= SessionMessageContractV1.maximumWireFrameBytes,
              let length = UInt32(exactly: payload.count) else {
            throw SessionMessageContractError.frameTooLarge
        }
        var bigEndian = length.bigEndian
        var data = Data(bytes: &bigEndian, count: MemoryLayout<UInt32>.size)
        data.append(payload)
        return data
    }

    static func decodeReply(
        _ data: Data,
        expectedID: UInt64,
        brokerGeneration: UInt64
    ) throws -> SessionMessageReplyV1 {
        guard !data.isEmpty else { throw SessionMessageContractError.malformedJSON }
        guard data.count <= SessionMessageContractV1.maximumReceiptBytes else {
            throw SessionMessageContractError.replyTooLarge
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionMessageContractError.malformedJSON
        }
        if object["result"] != nil {
            let receipt = try decodeReceipt(object)
            guard receipt.id == expectedID, receipt.brokerGeneration == brokerGeneration else {
                throw SessionMessageContractError.identityMismatch
            }
            return .receipt(receipt)
        }
        if object["error"] != nil {
            let error = try decodeError(object)
            guard error.id == expectedID, error.brokerGeneration == brokerGeneration else {
                throw SessionMessageContractError.identityMismatch
            }
            return .failure(error)
        }
        throw SessionMessageContractError.unknownOrMissingField
    }

    static func decodeRequest(_ data: Data) throws -> SessionMessageRequestV1 {
        guard !data.isEmpty, data.count <= SessionMessageContractV1.maximumWireFrameBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SessionMessageContractError.malformedJSON
        }
        try SessionMessageWireValue.requireExactKeys(
            object,
            required: ["version", "id", "op", "broker_generation", "authority_epoch", "request_nonce", "target_session_id", "mode", "message", "reason", "expires_at"],
            optional: ["expected_execution_id", "expected_target_generation", "correlation_id"]
        )
        guard try SessionMessageWireValue.uint(object, "version") == 1,
              try SessionMessageWireValue.string(object, "op") == "session_message_resolve_and_admit",
              let mode = SessionMessageModeV1(rawValue: try SessionMessageWireValue.string(object, "mode")) else {
            throw SessionMessageContractError.invalidValue
        }
        let value = SessionMessageRequestV1(
            id: try SessionMessageWireValue.nonzeroUInt(object, "id"),
            brokerGeneration: try SessionMessageWireValue.nonzeroUInt(object, "broker_generation"),
            authorityEpoch: try SessionMessageWireValue.uint(object, "authority_epoch"),
            requestNonce: try SessionMessageWireValue.string(object, "request_nonce"),
            targetSessionID: try SessionMessageWireValue.string(object, "target_session_id"),
            expectedExecutionID: try SessionMessageWireValue.optionalString(object, "expected_execution_id"),
            expectedTargetGeneration: try SessionMessageWireValue.optionalUInt(object, "expected_target_generation"),
            mode: mode,
            message: try SessionMessageWireValue.string(object, "message"),
            reason: try SessionMessageWireValue.string(object, "reason"),
            expiresAt: try SessionMessageWireValue.string(object, "expires_at"),
            correlationID: try SessionMessageWireValue.optionalString(object, "correlation_id")
        )
        _ = try value.wireData()
        return value
    }

    private static func decodeReceipt(_ object: [String: Any]) throws -> SessionMessageReceiptV1 {
        try SessionMessageWireValue.requireExactKeys(
            object,
            required: ["version", "broker_generation", "id", "result", "request_nonce", "request_digest", "signal_id", "source", "target", "mode", "state", "durable_cursor", "application_proven", "replayed", "hop_count", "expires_at", "reply_summary"]
        )
        guard try SessionMessageWireValue.uint(object, "version") == 1,
              try SessionMessageWireValue.string(object, "result") == "session_message_receipt",
              let mode = SessionMessageModeV1(rawValue: try SessionMessageWireValue.string(object, "mode")),
              let state = SessionMessageReceiptStateV1(rawValue: try SessionMessageWireValue.string(object, "state")) else {
            throw SessionMessageContractError.invalidValue
        }
        let receipt = SessionMessageReceiptV1(
            brokerGeneration: try SessionMessageWireValue.nonzeroUInt(object, "broker_generation"),
            id: try SessionMessageWireValue.nonzeroUInt(object, "id"),
            requestNonce: try SessionMessageWireValue.string(object, "request_nonce"),
            requestDigest: try SessionMessageWireValue.string(object, "request_digest"),
            signalID: try SessionMessageWireValue.string(object, "signal_id"),
            source: try decodeSource(try SessionMessageWireValue.object(object, "source")),
            target: try decodeSession(try SessionMessageWireValue.object(object, "target")),
            mode: mode,
            state: state,
            durableCursor: try SessionMessageWireValue.uint(object, "durable_cursor"),
            applicationProven: try SessionMessageWireValue.bool(object, "application_proven"),
            replayed: try SessionMessageWireValue.bool(object, "replayed"),
            hopCount: try SessionMessageWireValue.uint8(object, "hop_count"),
            expiresAt: try SessionMessageWireValue.string(object, "expires_at"),
            replySummary: try SessionMessageWireValue.optionalString(object, "reply_summary")
        )
        try SessionMessageWireValue.validateNonce(receipt.requestNonce)
        try SessionMessageWireValue.validateDigest(receipt.requestDigest)
        try SessionMessageWireValue.validateID(receipt.signalID)
        try SessionMessageWireValue.validateTimestamp(receipt.expiresAt)
        if receipt.applicationProven != state.applicationProven {
            throw SessionMessageContractError.applicationProofMismatch
        }
        if receipt.replySummary != nil, state != .completed {
            throw SessionMessageContractError.replyBeforeCompletion
        }
        if let replySummary = receipt.replySummary {
            try SessionMessageWireValue.validateText(replySummary, maximumBytes: SessionMessageContractV1.maximumReplyBytes)
        }
        return receipt
    }

    private static func decodeError(_ object: [String: Any]) throws -> SessionMessageErrorReplyV1 {
        try SessionMessageWireValue.requireExactKeys(
            object,
            required: ["version", "broker_generation", "id", "error", "code", "message"]
        )
        guard try SessionMessageWireValue.uint(object, "version") == 1,
              try SessionMessageWireValue.string(object, "error") == "session_message_error",
              let code = SessionMessageErrorCodeV1(rawValue: try SessionMessageWireValue.string(object, "code")) else {
            throw SessionMessageContractError.invalidValue
        }
        let message = try SessionMessageWireValue.string(object, "message")
        try SessionMessageWireValue.validateText(message, maximumBytes: SessionMessageContractV1.maximumErrorBytes)
        return SessionMessageErrorReplyV1(
            brokerGeneration: try SessionMessageWireValue.nonzeroUInt(object, "broker_generation"),
            id: try SessionMessageWireValue.nonzeroUInt(object, "id"),
            code: code,
            message: message
        )
    }

    private static func decodeSession(_ object: [String: Any]) throws -> SessionMessageExactSessionIdentityV1 {
        try SessionMessageWireValue.requireExactKeys(
            object,
            required: ["session_id", "execution_id", "scope_id", "attempt_id", "generation"]
        )
        let value = SessionMessageExactSessionIdentityV1(
            sessionID: try SessionMessageWireValue.string(object, "session_id"),
            executionID: try SessionMessageWireValue.string(object, "execution_id"),
            scopeID: try SessionMessageWireValue.string(object, "scope_id"),
            attemptID: try SessionMessageWireValue.string(object, "attempt_id"),
            generation: try SessionMessageWireValue.uint(object, "generation")
        )
        try [value.sessionID, value.executionID, value.scopeID, value.attemptID].forEach(SessionMessageWireValue.validateID)
        return value
    }

    private static func decodeSource(_ object: [String: Any]) throws -> SessionMessageExactSourceIdentityV1 {
        let kind = try SessionMessageWireValue.string(object, "kind")
        switch kind {
        case "user":
            try SessionMessageWireValue.requireExactKeys(object, required: ["kind", "principal_id", "authority_epoch"])
            let principalID = try SessionMessageWireValue.string(object, "principal_id")
            try SessionMessageWireValue.validateID(principalID)
            return .user(principalID: principalID, authorityEpoch: try SessionMessageWireValue.uint(object, "authority_epoch"))
        case "session":
            try SessionMessageWireValue.requireExactKeys(object, required: ["kind", "session_id", "execution_id", "scope_id", "attempt_id", "generation"])
            var sessionObject = object
            sessionObject.removeValue(forKey: "kind")
            return .session(try decodeSession(sessionObject))
        default:
            throw SessionMessageContractError.invalidValue
        }
    }
}

struct SessionMessageDigestPrincipalV1: Equatable {
    let uid: UInt32
    let bindingID: String
    let sessionID: String
    let executionID: String
    let scopeID: String
    let attemptID: String
    let authorityEpoch: UInt64
    let causeSignalID: String?
    let causeHopCount: UInt8?
}

enum SessionMessageRequestDigestV1 {
    static func digest(principal: SessionMessageDigestPrincipalV1, request: SessionMessageRequestV1) throws -> String {
        guard principal.authorityEpoch == request.authorityEpoch else {
            throw SessionMessageContractError.identityMismatch
        }
        try [principal.bindingID, principal.sessionID, principal.executionID, principal.scopeID, principal.attemptID]
            .forEach(SessionMessageWireValue.validateID)
        let nonce = try SessionMessageWireValue.nonceBytes(request.requestNonce)
        let hopCount: UInt8
        if let causeHopCount = principal.causeHopCount {
            guard causeHopCount < UInt8.max else { throw SessionMessageContractError.invalidInteger }
            hopCount = causeHopCount + 1
        } else {
            hopCount = 1
        }
        var preimage = Data()
        func field(_ data: Data) {
            var size = UInt64(data.count).bigEndian
            preimage.append(Data(bytes: &size, count: 8))
            preimage.append(data)
        }
        func text(_ value: String) { field(Data(value.utf8)) }
        func number<T: FixedWidthInteger>(_ value: T) {
            var bigEndian = value.bigEndian
            field(Data(bytes: &bigEndian, count: MemoryLayout<T>.size))
        }
        text("ourocode.session-message.request-digest.v1")
        text("ouroboros_session")
        number(principal.uid)
        text(principal.bindingID)
        text(principal.sessionID)
        text(principal.executionID)
        text(principal.scopeID)
        text(principal.attemptID)
        number(request.authorityEpoch)
        field(nonce)
        text(request.targetSessionID)
        field(request.expectedExecutionID.map { Data($0.utf8) } ?? Data())
        if let generation = request.expectedTargetGeneration { number(generation) } else { field(Data()) }
        text(request.mode.rawValue)
        field(Data(SHA256.hash(data: Data(request.message.utf8))))
        field(Data(SHA256.hash(data: Data(request.reason.utf8))))
        field(try SessionMessageWireValue.timestampNanoseconds128(request.expiresAt))
        field(principal.causeSignalID.map { Data($0.utf8) } ?? Data())
        field(Data([hopCount]))
        field(request.correlationID.map { Data($0.utf8) } ?? Data())
        return "sha256:" + SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
    }
}

private enum SessionMessageWireValue {
    static func requireExactKeys(_ object: [String: Any], required: Set<String>, optional: Set<String> = []) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw SessionMessageContractError.unknownOrMissingField
        }
    }

    static func string(_ object: [String: Any], _ key: String) throws -> String {
        guard let value = object[key] as? String else { throw SessionMessageContractError.invalidValue }
        return value
    }

    static func optionalString(_ object: [String: Any], _ key: String) throws -> String? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        guard let string = value as? String else { throw SessionMessageContractError.invalidValue }
        return string
    }

    static func object(_ object: [String: Any], _ key: String) throws -> [String: Any] {
        guard let value = object[key] as? [String: Any] else { throw SessionMessageContractError.invalidValue }
        return value
    }

    static func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        guard let number = object[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
            throw SessionMessageContractError.invalidValue
        }
        return number.boolValue
    }

    static func uint(_ object: [String: Any], _ key: String) throws -> UInt64 {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !number.stringValue.contains("."),
              !number.stringValue.contains("-"),
              let value = UInt64(number.stringValue) else {
            throw SessionMessageContractError.invalidInteger
        }
        return value
    }

    static func nonzeroUInt(_ object: [String: Any], _ key: String) throws -> UInt64 {
        let value = try uint(object, key)
        guard value > 0 else { throw SessionMessageContractError.invalidInteger }
        return value
    }

    static func optionalUInt(_ object: [String: Any], _ key: String) throws -> UInt64? {
        guard let value = object[key] else { return nil }
        if value is NSNull { return nil }
        return try uint(object, key)
    }

    static func uint8(_ object: [String: Any], _ key: String) throws -> UInt8 {
        guard let value = UInt8(exactly: try uint(object, key)) else {
            throw SessionMessageContractError.invalidInteger
        }
        return value
    }

    static func validateID(_ value: String) throws {
        try validateText(value, maximumBytes: SessionMessageContractV1.maximumIDBytes)
    }

    static func validateText(_ value: String, maximumBytes: Int) throws {
        guard !value.isEmpty, value.utf8.count <= maximumBytes,
              value == value.precomposedStringWithCanonicalMapping,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              value.unicodeScalars.contains(where: {
                  !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw SessionMessageContractError.invalidValue
        }
    }

    static func nonceBytes(_ value: String) throws -> Data {
        guard !value.contains("="),
              value.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw SessionMessageContractError.invalidValue
        }
        var standard = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard), (16...32).contains(data.count) else {
            throw SessionMessageContractError.invalidValue
        }
        let canonical = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard canonical == value else { throw SessionMessageContractError.invalidValue }
        return data
    }

    static func validateNonce(_ value: String) throws { _ = try nonceBytes(value) }

    static func validateDigest(_ value: String) throws {
        guard value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
            throw SessionMessageContractError.invalidValue
        }
    }

    static func validateTimestamp(_ value: String) throws {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil,
              ISO8601DateFormatter().date(from: value) != nil || fractionalFormatter.date(from: value) != nil else {
            throw SessionMessageContractError.invalidValue
        }
    }

    static func timestampNanoseconds128(_ value: String) throws -> Data {
        try validateTimestamp(value)
        let pattern = #"^(.*:\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(value.startIndex..., in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              let baseRange = Range(match.range(at: 1), in: value),
              let zoneRange = Range(match.range(at: 3), in: value) else {
            throw SessionMessageContractError.invalidValue
        }
        let base = String(value[baseRange]) + String(value[zoneRange])
        guard let date = ISO8601DateFormatter().date(from: base) else { throw SessionMessageContractError.invalidValue }
        var fraction: UInt64 = 0
        if match.range(at: 2).location != NSNotFound, let fractionRange = Range(match.range(at: 2), in: value) {
            let digits = String(value[fractionRange])
            fraction = UInt64(digits + String(repeating: "0", count: 9 - digits.count)) ?? 0
        }
        let seconds = Int64(date.timeIntervalSince1970.rounded())
        guard seconds >= 0 else { throw SessionMessageContractError.invalidValue }
        let (whole, overflow) = UInt64(seconds).multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { throw SessionMessageContractError.invalidInteger }
        let (nanos, additionOverflow) = whole.addingReportingOverflow(fraction)
        guard !additionOverflow else { throw SessionMessageContractError.invalidInteger }
        var high: UInt64 = 0
        var low = nanos.bigEndian
        high = high.bigEndian
        return Data(bytes: &high, count: 8) + Data(bytes: &low, count: 8)
    }

    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
