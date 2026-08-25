import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func requireThrows(_ expected: SessionMessageContractError, _ message: String, _ operation: () throws -> Void) {
    do {
        try operation()
        require(false, "\(message) did not fail")
    } catch let error as SessionMessageContractError {
        require(error == expected, "\(message) failed as \(error), expected \(expected)")
    } catch {
        require(false, "\(message) failed as unexpected \(error)")
    }
}

@main
private enum SessionMessageContractFixture {
    static func main() throws {
        let fixturePath = CommandLine.arguments.dropFirst().first
            ?? "../../../docs/rfcs/fixtures/session-message-v1-known-vector.json"
        let fixtureData = try Data(contentsOf: URL(fileURLWithPath: fixturePath))
        let fixture = try JSONSerialization.jsonObject(with: fixtureData) as! [String: Any]
        let requestObject = fixture["request"] as! [String: Any]
        let requestData = try JSONSerialization.data(withJSONObject: requestObject, options: [.sortedKeys])
        let request = try SessionMessageWireCodecV1.decodeRequest(requestData)
        require(request.id == 42, "known request id changed")
        require(request.targetSessionID == "session-b", "known target changed")
        require(request.mode == .afterTurn, "known mode changed")
        let roundTrippedRequest = try JSONSerialization.jsonObject(with: request.wireData()) as! NSDictionary
        require(roundTrippedRequest == requestObject as NSDictionary, "known request does not round-trip")

        let principalObject = fixture["principal"] as! [String: Any]
        let principal = SessionMessageDigestPrincipalV1(
            uid: UInt32((principalObject["uid"] as! NSNumber).uintValue),
            bindingID: principalObject["binding_id"] as! String,
            sessionID: principalObject["session_id"] as! String,
            executionID: principalObject["execution_id"] as! String,
            scopeID: principalObject["scope_id"] as! String,
            attemptID: principalObject["attempt_id"] as! String,
            authorityEpoch: (principalObject["authority_epoch"] as! NSNumber).uint64Value,
            causeSignalID: nil,
            causeHopCount: nil
        )
        let derived = fixture["derived"] as! [String: Any]
        let requestDigest = try SessionMessageRequestDigestV1.digest(principal: principal, request: request)
        require(requestDigest == derived["request_digest"] as! String, "Swift digest does not match the frozen Rust vector")

        var openRequest = requestObject
        openRequest["source"] = ["kind": "user"]
        requireThrows(.unknownOrMissingField, "caller supplied source") {
            _ = try SessionMessageWireCodecV1.decodeRequest(
                JSONSerialization.data(withJSONObject: openRequest)
            )
        }

        let authority = SessionMessageAuthorityV1(
            brokerGeneration: request.brokerGeneration,
            authorityEpoch: request.authorityEpoch,
            bindingID: "desktop-binding"
        )
        require(
            SessionMessageCapabilityStateV1.negotiate(
                advertisedCapabilities: [],
                reciprocalPeerVerified: true,
                durableBindingAcknowledged: true,
                knownVectorVerified: true,
                authority: authority
            ).authority == nil,
            "missing capability enabled writes"
        )
        require(
            SessionMessageCapabilityStateV1.negotiate(
                advertisedCapabilities: SessionMessageContractV1.requiredCapabilities,
                reciprocalPeerVerified: true,
                durableBindingAcknowledged: false,
                knownVectorVerified: true,
                authority: authority
            ) == .verifying,
            "missing durable ACK did not remain verifying"
        )
        require(
            SessionMessageCapabilityStateV1.negotiate(
                advertisedCapabilities: SessionMessageContractV1.requiredCapabilities,
                reciprocalPeerVerified: true,
                durableBindingAcknowledged: true,
                knownVectorVerified: true,
                authority: authority
            ).authority == authority,
            "fully verified authority did not become ready"
        )

        for state in SessionMessageReceiptStateV1.allFixtureCases {
            let data = try receiptData(state: state, request: request)
            let reply = try SessionMessageWireCodecV1.decodeReply(
                data,
                expectedID: request.id,
                brokerGeneration: request.brokerGeneration
            )
            guard case .receipt(let receipt) = reply else {
                require(false, "\(state) did not decode as a receipt")
                continue
            }
            require(receipt.state == state, "receipt state changed")
            require(receipt.applicationProven == state.applicationProven, "receipt proof changed")
        }

        var openReceipt = try JSONSerialization.jsonObject(with: receiptData(state: .queued, request: request)) as! [String: Any]
        openReceipt["message"] = "must not be echoed"
        requireThrows(.unknownOrMissingField, "receipt message echo") {
            _ = try SessionMessageWireCodecV1.decodeReply(
                JSONSerialization.data(withJSONObject: openReceipt),
                expectedID: request.id,
                brokerGeneration: request.brokerGeneration
            )
        }
        var falseProof = try JSONSerialization.jsonObject(with: receiptData(state: .queued, request: request)) as! [String: Any]
        falseProof["application_proven"] = true
        requireThrows(.applicationProofMismatch, "false application proof") {
            _ = try SessionMessageWireCodecV1.decodeReply(
                JSONSerialization.data(withJSONObject: falseProof),
                expectedID: request.id,
                brokerGeneration: request.brokerGeneration
            )
        }

        let key = SessionMessageDraftKeyV1(
            sourceID: "ouroboros",
            targetSessionID: request.targetSessionID,
            expectedExecutionID: request.expectedExecutionID
        )
        var store = SessionMessageStateStoreV1()
        try store.begin(request, for: key)
        let outcomeUnknown = SessionMessageErrorReplyV1(
            brokerGeneration: request.brokerGeneration,
            id: request.id,
            code: .outcomeUnknown,
            message: "Check durable status with the same nonce."
        )
        try store.receive(.failure(outcomeUnknown), for: key)
        require(!store[key].effect.permitsNewSend, "uncertain outcome enabled a second send")
        let status = try store.statusRequest(id: 43, authority: authority, for: key)
        require(status.requestNonce == request.requestNonce, "status changed the preserved nonce")
        requireThrows(.identityMismatch, "wrong response id") {
            _ = try SessionMessageWireCodecV1.decodeReply(
                receiptData(state: .queued, request: request),
                expectedID: 999,
                brokerGeneration: request.brokerGeneration
            )
        }

        print("PASS: Swift session-message known vector, closed receipts, authority gate, and uncertain nonce recovery")
    }

    private static func receiptData(
        state: SessionMessageReceiptStateV1,
        request: SessionMessageRequestV1
    ) throws -> Data {
        var object: [String: Any] = [
            "version": 1,
            "broker_generation": request.brokerGeneration,
            "id": request.id,
            "result": "session_message_receipt",
            "request_nonce": request.requestNonce,
            "request_digest": "sha256:fdaa6c7acd2c9b69b8aa2e406f50e98a643beeaa3821b7c3d618cdbd4f8c06b9",
            "signal_id": "signal-17",
            "source": [
                "kind": "session",
                "session_id": "session-a",
                "execution_id": "execution-1",
                "scope_id": "scope-a",
                "attempt_id": "attempt-a1",
                "generation": 3,
            ],
            "target": [
                "session_id": "session-b",
                "execution_id": "execution-1",
                "scope_id": "scope-b",
                "attempt_id": "attempt-b1",
                "generation": 7,
            ],
            "mode": "after_turn",
            "state": state.rawValue,
            "durable_cursor": 81,
            "application_proven": state.applicationProven,
            "replayed": false,
            "hop_count": 1,
            "expires_at": request.expiresAt,
            "reply_summary": NSNull(),
        ]
        if state == .completed { object["reply_summary"] = "Reconnect boundary re-checked." }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

private extension SessionMessageReceiptStateV1 {
    static let allFixtureCases: [Self] = [
        .queued, .delivering, .applied, .completed, .rejected, .deliveryUncertain,
    ]
}
