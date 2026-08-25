import CryptoKit
import Foundation

/// Provider-neutral, read-only projection of a routing decision owned by
/// Ouroboros. Nothing in this file classifies user text or chooses a model.
struct OuroborosRoutingCapability: Equatable {
    static let capabilityName = "ouroboros.routing.receipts"

    let schemaVersion: Int
    let snapshotTool: String
    let events: Set<String>
    let signingKeyID: String
    let signingPublicKey: Data
    let maximumResponseBytes: Int
    let maximumRecords: Int

    static func negotiate(capabilities: [String: Any]) -> OuroborosRoutingCapabilityNegotiation {
        guard let experimental = capabilities["experimental"] as? [String: Any],
              let advertised = experimental[capabilityName] else {
            return .unavailable
        }
        guard let value = advertised as? [String: Any],
              let schemaVersion = value["schema_version"] as? Int,
              schemaVersion == 1,
              let snapshotTool = boundedIdentifier(value["snapshot_tool"]),
              let rawEvents = value["events"] as? [String],
              rawEvents.count <= 8,
              let signing = value["signing"] as? [String: Any],
              signing["algorithm"] as? String == "ed25519",
              let keyID = boundedIdentifier(signing["key_id"]),
              let encodedKey = signing["public_key"] as? String,
              let publicKey = Data(base64Encoded: encodedKey),
              publicKey.count == 32 else {
            return .rejected(.malformedCapability)
        }
        let requiredEvents: Set<String> = [
            "routing.snapshot",
            "routing.decided",
            "routing.override_accepted",
            "routing.override_rejected"
        ]
        let events = Set(rawEvents)
        guard requiredEvents.isSubset(of: events) else {
            return .rejected(.malformedCapability)
        }
        let responseLimit = value["maximum_response_bytes"] as? Int ?? 262_144
        let recordLimit = value["maximum_records"] as? Int ?? 128
        guard (16_384...262_144).contains(responseLimit),
              (1...256).contains(recordLimit) else {
            return .rejected(.malformedCapability)
        }
        return .available(
            OuroborosRoutingCapability(
                schemaVersion: schemaVersion,
                snapshotTool: snapshotTool,
                events: events,
                signingKeyID: keyID,
                signingPublicKey: publicKey,
                maximumResponseBytes: responseLimit,
                maximumRecords: recordLimit
            )
        )
    }

    private static func boundedIdentifier(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= 128,
              !value.contains(where: \Character.isNewline) else { return nil }
        return value
    }
}

enum OuroborosRoutingCapabilityNegotiation: Equatable {
    case unavailable
    case available(OuroborosRoutingCapability)
    case rejected(OuroborosRoutingContractFailure)
}

enum OuroborosRoutingContractState: Equatable {
    case unavailable
    case loading
    case ready(OuroborosRoutingBatch)
    case rejected(OuroborosRoutingContractFailure)
}

enum OuroborosRoutingContractFailure: String, Error, Equatable {
    case malformedCapability = "malformed_capability"
    case responseTooLarge = "response_too_large"
    case malformedEnvelope = "malformed_envelope"
    case signatureMissing = "signature_missing"
    case signatureInvalid = "signature_invalid"
    case signerMismatch = "signer_mismatch"
    case expired = "expired"
    case invalidLifetime = "invalid_lifetime"
    case staleGeneration = "stale_generation"
    case cursorMismatch = "cursor_mismatch"
    case sequenceGap = "sequence_gap"
    case recordLimitExceeded = "record_limit_exceeded"
    case prohibitedContent = "prohibited_content"
}

struct OuroborosRoutingProvenance: Equatable {
    let source: String
    let authorityID: String
    let policyVersion: String
    let signingKeyID: String
}

struct OuroborosRequestedRoutingPolicy: Equatable {
    let effort: String
    let maximumCostUSD: Double?
    let latencySLOMilliseconds: UInt64?
    let allowedProviders: [String]
    let privacyClass: String?
}

/// The route Ouroboros actually bound. A requested tier is never copied into
/// this value and Ourocode never derives one from a provider or model name.
struct OuroborosActualRoute: Equatable {
    let provider: String
    let model: String
    let effort: String
    let serviceTier: String
    let runtime: String
    let capabilities: [String]
}

struct OuroborosComplexityAssessment: Equatable {
    let assessmentID: String
    let executionID: String
    let sessionScopeID: String
    let attemptID: String
    let generation: UInt64
    let score: Double
    let confidence: Double
    let reasonCodes: [String]
    let requiredCapabilities: [String]
    let featureSchemaVersion: String
    let historyWindowID: String?
    let createdAt: Date
}

struct OuroborosRoutingDecision: Equatable {
    let decisionID: String
    let assessment: OuroborosComplexityAssessment
    let generation: UInt64
    let requested: OuroborosRequestedRoutingPolicy
    let actual: OuroborosActualRoute
    let reasonCodes: [String]
    let supersedesDecisionID: String?
    let createdAt: Date
}

enum OuroborosRoutingOverrideStatus: String, Equatable {
    case accepted
    case rejected
}

struct OuroborosRoutingOverrideReceipt: Equatable {
    let overrideID: String
    let decisionID: String
    let executionID: String
    let sessionScopeID: String
    let attemptID: String
    let generation: UInt64
    let status: OuroborosRoutingOverrideStatus
    let requested: OuroborosRequestedRoutingPolicy
    let actual: OuroborosActualRoute?
    let source: String
    let reasonCodes: [String]
    let createdAt: Date
}

enum OuroborosRoutingEvent: Equatable {
    case decided(sequence: UInt64, OuroborosRoutingDecision)
    case override(sequence: UInt64, OuroborosRoutingOverrideReceipt)

    var sequence: UInt64 {
        switch self {
        case .decided(let sequence, _), .override(let sequence, _): sequence
        }
    }
}

struct OuroborosRoutingBatch: Equatable {
    let generation: UInt64
    let cursor: String
    let nextCursor: String?
    let sequenceStart: UInt64
    let sequenceEnd: UInt64
    let issuedAt: Date
    let expiresAt: Date
    let provenance: OuroborosRoutingProvenance
    let events: [OuroborosRoutingEvent]
}

struct OuroborosRoutingDecodeExpectation: Equatable {
    let minimumGeneration: UInt64?
    let requestedCursor: String?

    static let initial = OuroborosRoutingDecodeExpectation(minimumGeneration: nil, requestedCursor: nil)
}

struct OuroborosRoutingReceiptDecoder {
    private let capability: OuroborosRoutingCapability
    private let now: () -> Date

    init(capability: OuroborosRoutingCapability, now: @escaping () -> Date = Date.init) {
        self.capability = capability
        self.now = now
    }

    func decode(
        _ envelopeData: Data,
        expectation: OuroborosRoutingDecodeExpectation = .initial
    ) -> Result<OuroborosRoutingBatch, OuroborosRoutingContractFailure> {
        guard envelopeData.count <= capability.maximumResponseBytes else {
            return .failure(.responseTooLarge)
        }
        guard let envelope = try? JSONSerialization.jsonObject(with: envelopeData) as? [String: Any],
              envelope["schema_version"] as? Int == capability.schemaVersion else {
            return .failure(.malformedEnvelope)
        }
        guard let signature = envelope["signature"] as? [String: Any],
              let algorithm = signature["algorithm"] as? String,
              let keyID = signature["key_id"] as? String,
              let encodedSignature = signature["value"] as? String else {
            return .failure(.signatureMissing)
        }
        guard algorithm == "ed25519", keyID == capability.signingKeyID else {
            return .failure(.signerMismatch)
        }
        guard let encodedPayload = envelope["signed_payload"] as? String,
              encodedPayload.utf8.count <= capability.maximumResponseBytes * 2,
              let payload = Data(base64Encoded: encodedPayload),
              payload.count <= capability.maximumResponseBytes,
              let signatureData = Data(base64Encoded: encodedSignature) else {
            return .failure(.malformedEnvelope)
        }
        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: capability.signingPublicKey)
            guard publicKey.isValidSignature(signatureData, for: payload) else {
                return .failure(.signatureInvalid)
            }
        } catch {
            return .failure(.signatureInvalid)
        }
        guard let value = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            return .failure(.malformedEnvelope)
        }
        guard !containsProhibitedContent(value) else {
            return .failure(.prohibitedContent)
        }
        return decodeSignedPayload(value, expectation: expectation, signerKeyID: keyID)
    }

    private func decodeSignedPayload(
        _ value: [String: Any],
        expectation: OuroborosRoutingDecodeExpectation,
        signerKeyID: String
    ) -> Result<OuroborosRoutingBatch, OuroborosRoutingContractFailure> {
        guard value["schema_version"] as? Int == capability.schemaVersion,
              value["event_type"] as? String == "routing.snapshot",
              let generation = uint64(value["generation"]),
              let cursor = identifier(value["cursor"]),
              let sequenceStart = uint64(value["sequence_start"]),
              let sequenceEnd = uint64(value["sequence_end"]),
              sequenceEnd >= sequenceStart,
              let issuedAt = date(value["issued_at"]),
              let expiresAt = date(value["expires_at"]),
              let provenanceValue = value["provenance"] as? [String: Any],
              let provenance = parseProvenance(provenanceValue, signerKeyID: signerKeyID),
              let rawEvents = value["events"] as? [[String: Any]] else {
            return .failure(.malformedEnvelope)
        }
        guard rawEvents.count <= capability.maximumRecords else {
            return .failure(.recordLimitExceeded)
        }
        guard expiresAt > issuedAt,
              expiresAt.timeIntervalSince(issuedAt) <= 300 else {
            return .failure(.invalidLifetime)
        }
        guard expiresAt > now() else { return .failure(.expired) }
        if let minimum = expectation.minimumGeneration, generation < minimum {
            return .failure(.staleGeneration)
        }
        if let requestedCursor = expectation.requestedCursor, cursor != requestedCursor {
            return .failure(.cursorMismatch)
        }
        var events: [OuroborosRoutingEvent] = []
        events.reserveCapacity(rawEvents.count)
        var expectedSequence = sequenceStart
        for (index, rawEvent) in rawEvents.enumerated() {
            guard let sequence = uint64(rawEvent["sequence"]), sequence == expectedSequence else {
                return .failure(.sequenceGap)
            }
            guard let event = parseEvent(rawEvent, sequence: sequence, generation: generation) else {
                return .failure(.malformedEnvelope)
            }
            events.append(event)
            if index + 1 < rawEvents.count {
                let (next, overflow) = expectedSequence.addingReportingOverflow(1)
                guard !overflow else { return .failure(.sequenceGap) }
                expectedSequence = next
            }
        }
        let observedEnd = events.last?.sequence ?? sequenceStart
        guard (events.isEmpty && sequenceStart == sequenceEnd) || observedEnd == sequenceEnd else {
            return .failure(.sequenceGap)
        }
        let nextCursor: String?
        if value["next_cursor"] is NSNull || value["next_cursor"] == nil {
            nextCursor = nil
        } else {
            guard let parsed = identifier(value["next_cursor"]) else {
                return .failure(.malformedEnvelope)
            }
            nextCursor = parsed
        }
        return .success(
            OuroborosRoutingBatch(
                generation: generation,
                cursor: cursor,
                nextCursor: nextCursor,
                sequenceStart: sequenceStart,
                sequenceEnd: sequenceEnd,
                issuedAt: issuedAt,
                expiresAt: expiresAt,
                provenance: provenance,
                events: events
            )
        )
    }

    private func parseEvent(
        _ value: [String: Any],
        sequence: UInt64,
        generation: UInt64
    ) -> OuroborosRoutingEvent? {
        guard let kind = value["kind"] as? String else { return nil }
        switch kind {
        case "routing.decided":
            guard let rawDecision = value["decision"] as? [String: Any],
                  let decision = parseDecision(rawDecision, generation: generation) else { return nil }
            return .decided(sequence: sequence, decision)
        case "routing.override_accepted", "routing.override_rejected":
            guard let rawOverride = value["override"] as? [String: Any],
                  let receipt = parseOverride(
                    rawOverride,
                    generation: generation,
                    accepted: kind == "routing.override_accepted"
                  ) else { return nil }
            return .override(sequence: sequence, receipt)
        default:
            return nil
        }
    }

    private func parseDecision(_ value: [String: Any], generation: UInt64) -> OuroborosRoutingDecision? {
        guard value["schema_version"] as? Int == 1,
              let decisionID = identifier(value["decision_id"]),
              uint64(value["generation"]) == generation,
              let assessmentValue = value["assessment"] as? [String: Any],
              let assessment = parseAssessment(assessmentValue, generation: generation),
              let requestedValue = value["requested"] as? [String: Any],
              let requested = parsePolicy(requestedValue),
              let actualValue = value["actual"] as? [String: Any],
              let actual = parseActual(actualValue),
              let reasons = boundedIdentifiers(value["reason_codes"], maximum: 4),
              let createdAt = date(value["created_at"]) else { return nil }
        let supersedes: String?
        if value["supersedes_decision_id"] is NSNull || value["supersedes_decision_id"] == nil {
            supersedes = nil
        } else {
            guard let parsed = identifier(value["supersedes_decision_id"]) else { return nil }
            supersedes = parsed
        }
        return OuroborosRoutingDecision(
            decisionID: decisionID,
            assessment: assessment,
            generation: generation,
            requested: requested,
            actual: actual,
            reasonCodes: reasons,
            supersedesDecisionID: supersedes,
            createdAt: createdAt
        )
    }

    private func parseAssessment(_ value: [String: Any], generation: UInt64) -> OuroborosComplexityAssessment? {
        guard value["schema_version"] as? Int == 1,
              let assessmentID = identifier(value["assessment_id"]),
              let executionID = identifier(value["execution_id"]),
              let sessionScopeID = identifier(value["session_scope_id"]),
              let attemptID = identifier(value["attempt_id"]),
              uint64(value["generation"]) == generation,
              let score = boundedScore(value["score"]),
              let confidence = boundedScore(value["confidence"]),
              let reasons = boundedIdentifiers(value["reason_codes"], maximum: 8),
              let required = boundedIdentifiers(value["required_capabilities"], maximum: 8),
              let featureSchemaVersion = identifier(value["feature_schema_version"]),
              let createdAt = date(value["created_at"]) else { return nil }
        let historyWindowID: String?
        if value["history_window_id"] is NSNull || value["history_window_id"] == nil {
            historyWindowID = nil
        } else {
            guard let parsed = identifier(value["history_window_id"]) else { return nil }
            historyWindowID = parsed
        }
        return OuroborosComplexityAssessment(
            assessmentID: assessmentID,
            executionID: executionID,
            sessionScopeID: sessionScopeID,
            attemptID: attemptID,
            generation: generation,
            score: score,
            confidence: confidence,
            reasonCodes: reasons,
            requiredCapabilities: required,
            featureSchemaVersion: featureSchemaVersion,
            historyWindowID: historyWindowID,
            createdAt: createdAt
        )
    }

    private func parsePolicy(_ value: [String: Any]) -> OuroborosRequestedRoutingPolicy? {
        guard let effort = identifier(value["effort"]),
              let providers = boundedIdentifiers(value["allowed_providers"], maximum: 4) else { return nil }
        let maximumCost: Double?
        if value["maximum_cost_usd"] is NSNull || value["maximum_cost_usd"] == nil {
            maximumCost = nil
        } else {
            guard let parsed = nonnegativeDouble(value["maximum_cost_usd"]) else { return nil }
            maximumCost = parsed
        }
        let latency: UInt64?
        if value["latency_slo_ms"] is NSNull || value["latency_slo_ms"] == nil {
            latency = nil
        } else {
            guard let parsed = uint64(value["latency_slo_ms"]), parsed <= 86_400_000 else { return nil }
            latency = parsed
        }
        let privacy: String?
        if value["privacy_class"] is NSNull || value["privacy_class"] == nil {
            privacy = nil
        } else {
            guard let parsed = identifier(value["privacy_class"]) else { return nil }
            privacy = parsed
        }
        return OuroborosRequestedRoutingPolicy(
            effort: effort,
            maximumCostUSD: maximumCost,
            latencySLOMilliseconds: latency,
            allowedProviders: providers,
            privacyClass: privacy
        )
    }

    private func parseActual(_ value: [String: Any]) -> OuroborosActualRoute? {
        guard let provider = identifier(value["provider"]),
              let model = identifier(value["model"]),
              let effort = identifier(value["effort"]),
              let tier = identifier(value["service_tier"]),
              let runtime = identifier(value["runtime"]),
              let capabilities = boundedIdentifiers(value["capabilities"], maximum: 16) else { return nil }
        return OuroborosActualRoute(
            provider: provider,
            model: model,
            effort: effort,
            serviceTier: tier,
            runtime: runtime,
            capabilities: capabilities
        )
    }

    private func parseOverride(
        _ value: [String: Any],
        generation: UInt64,
        accepted: Bool
    ) -> OuroborosRoutingOverrideReceipt? {
        guard value["schema_version"] as? Int == 1,
              let overrideID = identifier(value["override_id"]),
              let decisionID = identifier(value["decision_id"]),
              let executionID = identifier(value["execution_id"]),
              let scopeID = identifier(value["session_scope_id"]),
              let attemptID = identifier(value["attempt_id"]),
              uint64(value["generation"]) == generation,
              let requestedValue = value["requested"] as? [String: Any],
              let requested = parsePolicy(requestedValue),
              let source = identifier(value["source"]),
              let reasons = boundedIdentifiers(value["reason_codes"], maximum: 4),
              let createdAt = date(value["created_at"]) else { return nil }
        let actual: OuroborosActualRoute?
        if accepted {
            guard let rawActual = value["actual"] as? [String: Any],
                  let parsed = parseActual(rawActual) else { return nil }
            actual = parsed
        } else {
            guard value["actual"] == nil || value["actual"] is NSNull else { return nil }
            actual = nil
        }
        return OuroborosRoutingOverrideReceipt(
            overrideID: overrideID,
            decisionID: decisionID,
            executionID: executionID,
            sessionScopeID: scopeID,
            attemptID: attemptID,
            generation: generation,
            status: accepted ? .accepted : .rejected,
            requested: requested,
            actual: actual,
            source: source,
            reasonCodes: reasons,
            createdAt: createdAt
        )
    }

    private func parseProvenance(
        _ value: [String: Any],
        signerKeyID: String
    ) -> OuroborosRoutingProvenance? {
        guard let source = identifier(value["source"]),
              source == "ouroboros",
              let authorityID = identifier(value["authority_id"]),
              let policyVersion = identifier(value["policy_version"]),
              let keyID = identifier(value["signing_key_id"]),
              keyID == signerKeyID else { return nil }
        return OuroborosRoutingProvenance(
            source: source,
            authorityID: authorityID,
            policyVersion: policyVersion,
            signingKeyID: keyID
        )
    }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= 256,
              !value.contains(where: \Character.isNewline) else { return nil }
        return value
    }

    private func boundedIdentifiers(_ value: Any?, maximum: Int) -> [String]? {
        guard let values = value as? [Any], values.count <= maximum else { return nil }
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let parsed = identifier(value) else { return nil }
            result.append(parsed)
        }
        return result
    }

    private func uint64(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c",
              number.doubleValue.isFinite,
              number.doubleValue >= 0,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return UInt64(exactly: number)
    }

    private func boundedScore(_ value: Any?) -> Double? {
        guard let parsed = nonnegativeDouble(value), parsed <= 1 else { return nil }
        return parsed
    }

    private func nonnegativeDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              String(cString: number.objCType) != "c" else { return nil }
        let parsed = number.doubleValue
        return parsed.isFinite && parsed >= 0 ? parsed : nil
    }

    private func date(_ value: Any?) -> Date? {
        guard let value = value as? String, value.utf8.count <= 64 else { return nil }
        return ISO8601DateFormatter().date(from: value)
    }

    private func containsProhibitedContent(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                let normalized = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if ["prompt", "raw_prompt", "transcript", "chain_of_thought", "cot"].contains(normalized) {
                    return true
                }
                if containsProhibitedContent(child) { return true }
            }
        } else if let array = value as? [Any] {
            return array.contains(where: containsProhibitedContent)
        }
        return false
    }
}
