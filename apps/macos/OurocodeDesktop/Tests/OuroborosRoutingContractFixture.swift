import CryptoKit
import Darwin
import Foundation

// Standalone contract fixture. Run from apps/macos/OurocodeDesktop:
// swiftc Sources/OurocodeDesktop/OuroborosRoutingContract.swift \
//   Tests/OuroborosRoutingContractFixture.swift \
//   -o /tmp/ourocode-routing-contract-fixture && \
//   /tmp/ourocode-routing-contract-fixture

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum RoutingContractFixture {
    static func main() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
        let advertised: [String: Any] = [
            "experimental": [
                OuroborosRoutingCapability.capabilityName: [
                    "schema_version": 1,
                    "snapshot_tool": "ouroboros_routing_snapshot",
                    "events": [
                        "routing.snapshot",
                        "routing.decided",
                        "routing.override_accepted",
                        "routing.override_rejected"
                    ],
                    "signing": [
                        "algorithm": "ed25519",
                        "key_id": "fixture-key-1",
                        "public_key": publicKey
                    ],
                    "maximum_response_bytes": 16_384,
                    "maximum_records": 8
                ]
            ]
        ]
        guard case .available(let capability) = OuroborosRoutingCapability.negotiate(capabilities: advertised) else {
            require(false, "valid routing capability was not negotiated")
            return
        }

        // Ouroboros 0.51.0 owns model routing and frugality telemetry but does
        // not yet advertise the independent signed-receipt contract. Absence
        // remains intentionally quiet for current and older servers.
        let currentCapabilities: [String: Any] = [
            "experimental": [:],
            "tools": ["listChanged": false],
            "resources": ["subscribe": false, "listChanged": false]
        ]
        require(
            OuroborosRoutingCapability.negotiate(capabilities: currentCapabilities) == .unavailable,
            "0.51.0 capability absence must remain unavailable"
        )

        let fixedNow = ISO8601DateFormatter().date(from: "2026-08-09T12:02:00Z")!
        let decoder = OuroborosRoutingReceiptDecoder(capability: capability, now: { fixedNow })
        let payload = validPayload(generation: 7)
        let validEnvelope = try envelope(payload: payload, privateKey: privateKey)
        let validResult = decoder.decode(validEnvelope)
        guard case .success(let batch) = validResult else {
            require(false, "valid signed fixture was rejected: \(validResult)")
            return
        }
        require(batch.generation == 7, "generation changed")
        require(batch.events.count == 2, "event cardinality changed")
        guard case .decided(_, let decision) = batch.events[0] else {
            require(false, "first event is not routing.decided")
            return
        }
        require(decision.assessment.assessmentID == "assessment-1", "assessment id changed")
        require(decision.assessment.executionID == "execution-1", "execution id changed")
        require(decision.assessment.sessionScopeID == "scope-1", "scope id changed")
        require(decision.assessment.attemptID == "attempt-1", "attempt id changed")
        require(decision.assessment.score == 0.31, "score changed")
        require(decision.assessment.confidence == 0.93, "confidence changed")
        require(decision.requested.effort == "auto", "requested effort changed")
        require(decision.actual.provider == "provider-fixture", "actual provider changed")
        require(decision.actual.model == "model-fixture", "actual model changed")
        require(decision.actual.effort == "low", "actual effort changed")
        require(decision.actual.serviceTier == "standard", "actual tier changed")
        require(decision.actual.runtime == "runtime-fixture", "actual runtime changed")

        var malformedPayload = payload
        var malformedEvents = malformedPayload["events"] as! [[String: Any]]
        var malformedDecision = malformedEvents[0]["decision"] as! [String: Any]
        var malformedActual = malformedDecision["actual"] as! [String: Any]
        malformedActual.removeValue(forKey: "model")
        malformedDecision["actual"] = malformedActual
        malformedEvents[0]["decision"] = malformedDecision
        malformedPayload["events"] = malformedEvents
        requireFailure(
            decoder.decode(try envelope(payload: malformedPayload, privateKey: privateKey)),
            .malformedEnvelope,
            "malformed actual route"
        )

        requireFailure(
            decoder.decode(Data(repeating: 0x20, count: capability.maximumResponseBytes + 1)),
            .responseTooLarge,
            "oversize envelope"
        )

        requireFailure(
            decoder.decode(
                validEnvelope,
                expectation: OuroborosRoutingDecodeExpectation(minimumGeneration: 8, requestedCursor: nil)
            ),
            .staleGeneration,
            "stale generation"
        )

        var unsigned = try JSONSerialization.jsonObject(with: validEnvelope) as! [String: Any]
        unsigned.removeValue(forKey: "signature")
        requireFailure(
            decoder.decode(try JSONSerialization.data(withJSONObject: unsigned, options: [.sortedKeys])),
            .signatureMissing,
            "missing signature"
        )

        var invalidSignatureEnvelope = try JSONSerialization.jsonObject(with: validEnvelope) as! [String: Any]
        var invalidSignature = invalidSignatureEnvelope["signature"] as! [String: Any]
        invalidSignature["value"] = Data(repeating: 0, count: 64).base64EncodedString()
        invalidSignatureEnvelope["signature"] = invalidSignature
        requireFailure(
            decoder.decode(try JSONSerialization.data(withJSONObject: invalidSignatureEnvelope, options: [.sortedKeys])),
            .signatureInvalid,
            "invalid signature"
        )

        var expiredPayload = payload
        expiredPayload["expires_at"] = "2026-08-09T12:01:00Z"
        requireFailure(
            decoder.decode(try envelope(payload: expiredPayload, privateKey: privateKey)),
            .expired,
            "expired receipt"
        )

        var falseProvenancePayload = payload
        var falseProvenance = falseProvenancePayload["provenance"] as! [String: Any]
        falseProvenance["source"] = "desktop-client"
        falseProvenancePayload["provenance"] = falseProvenance
        requireFailure(
            decoder.decode(try envelope(payload: falseProvenancePayload, privateKey: privateKey)),
            .malformedEnvelope,
            "non-Ouroboros provenance"
        )

        requireFailure(
            decoder.decode(
                validEnvelope,
                expectation: OuroborosRoutingDecodeExpectation(
                    minimumGeneration: 7,
                    requestedCursor: "different-cursor"
                )
            ),
            .cursorMismatch,
            "cursor mismatch"
        )

        var prohibitedPayload = payload
        prohibitedPayload["transcript"] = "must never cross the contract"
        requireFailure(
            decoder.decode(try envelope(payload: prohibitedPayload, privateKey: privateKey)),
            .prohibitedContent,
            "prohibited transcript"
        )

        print("PASS: signed provider-neutral routing snapshot, graceful 0.51.0 absence, and fail-closed bounds")
    }

    private static func requireFailure(
        _ result: Result<OuroborosRoutingBatch, OuroborosRoutingContractFailure>,
        _ expected: OuroborosRoutingContractFailure,
        _ context: String
    ) {
        guard case .failure(let actual) = result else {
            require(false, "\(context) did not fail")
            return
        }
        require(actual == expected, "\(context) failed as \(actual), expected \(expected)")
    }

    private static func envelope(
        payload: [String: Any],
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let payloadData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let signature = try privateKey.signature(for: payloadData)
        let value: [String: Any] = [
            "schema_version": 1,
            "signed_payload": payloadData.base64EncodedString(),
            "signature": [
                "algorithm": "ed25519",
                "key_id": "fixture-key-1",
                "value": signature.base64EncodedString()
            ]
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private static func validPayload(generation: Int) -> [String: Any] {
        let requested: [String: Any] = [
            "effort": "auto",
            "maximum_cost_usd": 0.50,
            "latency_slo_ms": 30_000,
            "allowed_providers": ["provider-fixture", "provider-alternate"],
            "privacy_class": "local-metadata-only"
        ]
        let actual: [String: Any] = [
            "provider": "provider-fixture",
            "model": "model-fixture",
            "effort": "low",
            "service_tier": "standard",
            "runtime": "runtime-fixture",
            "capabilities": ["repository.write", "git.push"]
        ]
        let assessment: [String: Any] = [
            "schema_version": 1,
            "assessment_id": "assessment-1",
            "execution_id": "execution-1",
            "session_scope_id": "scope-1",
            "attempt_id": "attempt-1",
            "generation": generation,
            "score": 0.31,
            "confidence": 0.93,
            "reason_codes": ["bounded_repository_operation", "historical_verifier_pass"],
            "required_capabilities": ["repository.write", "git.push"],
            "feature_schema_version": "features-v1",
            "history_window_id": "window-7d-1",
            "created_at": "2026-08-09T12:00:00Z"
        ]
        let decision: [String: Any] = [
            "schema_version": 1,
            "decision_id": "decision-1",
            "generation": generation,
            "assessment": assessment,
            "requested": requested,
            "actual": actual,
            "reason_codes": ["capability_preflight_passed", "policy_selected"],
            "supersedes_decision_id": NSNull(),
            "created_at": "2026-08-09T12:00:01Z"
        ]
        let overrideReceipt: [String: Any] = [
            "schema_version": 1,
            "override_id": "override-1",
            "decision_id": "decision-1",
            "execution_id": "execution-1",
            "session_scope_id": "scope-1",
            "attempt_id": "attempt-1",
            "generation": generation,
            "requested": requested,
            "actual": actual,
            "source": "explicit_user_override",
            "reason_codes": ["override_authorized"],
            "created_at": "2026-08-09T12:00:02Z"
        ]
        return [
            "schema_version": 1,
            "event_type": "routing.snapshot",
            "generation": generation,
            "cursor": "cursor-0",
            "next_cursor": NSNull(),
            "sequence_start": 40,
            "sequence_end": 41,
            "issued_at": "2026-08-09T12:00:00Z",
            "expires_at": "2026-08-09T12:05:00Z",
            "provenance": [
                "source": "ouroboros",
                "authority_id": "ouroboros-local-authority",
                "policy_version": "routing-policy-v1",
                "signing_key_id": "fixture-key-1"
            ],
            "events": [
                ["kind": "routing.decided", "sequence": 40, "decision": decision],
                ["kind": "routing.override_accepted", "sequence": 41, "override": overrideReceipt]
            ]
        ]
    }
}
