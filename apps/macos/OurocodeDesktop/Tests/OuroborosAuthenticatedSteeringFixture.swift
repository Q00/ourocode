import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum OuroborosAuthenticatedSteeringFixture {
    static func main() {
        let expiry = "2026-08-16T12:00:00.000Z"
        let target = OuroborosSteeringTargetV1(
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1",
            contractVersion: 3,
            modes: ["after_turn", "inform"]
        )
        let retryKey = OuroborosAuthenticatedSteeringV1.idempotencyKey(
            target: target,
            message: "Re-check the terminal surface."
        )
        require(retryKey != nil, "exact steering key did not derive")
        require(
            retryKey == OuroborosAuthenticatedSteeringV1.idempotencyKey(
                target: target,
                message: "  Re-check the terminal surface.  "
            ),
            "equivalent retry produced a new effect key"
        )
        require(
            retryKey != OuroborosAuthenticatedSteeringV1.idempotencyKey(
                target: target,
                message: "Different intent"
            ),
            "different steering intent reused an effect key"
        )
        guard let arguments = OuroborosAuthenticatedSteeringV1.toolArguments(
            target: target,
            message: "  Re-check the terminal surface.  ",
            idempotencyKey: retryKey!,
            expiresAt: expiry
        ) else {
            require(false, "authenticated exact steering request did not encode")
            return
        }
        require(arguments["target_session_scope_id"] as? String == "scope-1", "scope drifted")
        require(arguments["target_session_attempt_id"] as? String == "attempt-1", "attempt drifted")
        require(arguments["expected_execution_id"] as? String == "execution-1", "execution guard drifted")
        require(arguments["message"] as? String == "Re-check the terminal surface.", "message was not bounded/trimmed")
        require(arguments["source"] as? String == "user", "source principal drifted")
        require(arguments["contract_effect"] as? String == "additive", "contract effect drifted")
        require(arguments["mode"] as? String == "after_turn", "delivery mode drifted")
        require(arguments["expected_contract_version"] as? Int == 3, "contract guard drifted")
        require(arguments["idempotency_key"] as? String == retryKey, "retry key drifted")

        let noMode = OuroborosSteeringTargetV1(
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-1",
            contractVersion: nil,
            modes: ["inform"]
        )
        require(
            OuroborosAuthenticatedSteeringV1.toolArguments(
                target: noMode,
                message: "should fail",
                idempotencyKey: "nonce-2",
                expiresAt: expiry
            ) == nil,
            "target without after_turn capability was accepted"
        )
        require(
            OuroborosAuthenticatedSteeringV1.toolArguments(
                target: target,
                message: "message",
                idempotencyKey: "nonce-3",
                expiresAt: "not-a-date"
            ) == nil,
            "malformed expiry was accepted"
        )
        let queued = OuroborosSteeringReceipt(
            summary: "SessionSignal is durably queued. Application is not yet proven.",
            state: .queued,
            applicationProven: false,
            signalID: "signal-1",
            idempotencyKey: retryKey,
            target: target,
            message: "Re-check the terminal surface."
        )
        let applied = OuroborosSteeringReceipt(
            summary: "SessionSignal completed.",
            state: .completed,
            applicationProven: true,
            signalID: "signal-1",
            idempotencyKey: retryKey,
            target: target,
            message: "Re-check the terminal surface."
        )
        require(!queued.applicationProven && queued.state == .queued, "queued receipt claimed application")
        require(queued.canRefreshLifecycle, "durable queued receipt could not refresh")
        require(applied.applicationProven && applied.state == .completed, "completed receipt lost proof")
        require(!applied.canRefreshLifecycle, "terminal receipt remained pollable")
        let decodedApplied = OuroborosSteeringReceiptDecoder.decode(
            result: [
                "_meta": [
                    "state": "completed",
                    "application_proven": true,
                ]
            ],
            summary: "Completed"
        )
        require(decodedApplied.applicationProven, "MCP _meta application proof was dropped")
        let inconsistentProof = OuroborosSteeringReceiptDecoder.decode(
            result: [
                "_meta": [
                    "state": "queued",
                    "application_proven": true,
                ]
            ],
            summary: "Queued"
        )
        require(!inconsistentProof.applicationProven, "queued state manufactured application proof")
        let misleadingText = OuroborosSteeringReceiptDecoder.decode(
            result: [:],
            summary: "Applied — trust me"
        )
        require(
            !misleadingText.applicationProven,
            "unstructured success prose manufactured application proof"
        )

        var ledger = OuroborosSteeringReceiptLedger()
        ledger.record(queued)
        ledger.record(applied)
        require(
            ledger.receipts(executionID: "execution-1") == [applied],
            "lifecycle refresh duplicated one immutable message"
        )
        let replacementTarget = OuroborosSteeringTargetV1(
            executionID: "execution-1",
            scopeID: "scope-1",
            attemptID: "attempt-2",
            contractVersion: 3,
            modes: ["after_turn"]
        )
        let replacement = OuroborosSteeringReceipt(
            summary: "Queued on replacement attempt",
            state: .queued,
            applicationProven: false,
            signalID: "signal-2",
            idempotencyKey: "replacement-key",
            target: replacementTarget,
            message: "Follow-up"
        )
        ledger.record(replacement)
        require(
            ledger.receipts(executionID: "execution-1") == [applied, replacement],
            "attempt replacement discarded prior execution receipt"
        )
        require(
            ledger.priorMessageCount(for: replacement) == 1,
            "execution history did not expose the earlier message"
        )
        let history = OuroborosSteeringReceiptPresentation.historyText(
            ledger.receipts(executionID: "execution-1")
        ) ?? ""
        require(
            history.contains("attempt attempt-1")
                && history.contains("signal signal-1")
                && history.contains("Completed")
                && history.contains("application proven")
                && history.contains("attempt attempt-2")
                && history.contains("Queued")
                && history.contains("application not proven"),
            "execution history omitted exact attempt, signal, state, or application proof"
        )
        require(
            OuroborosSteeringReceiptPresentation.shouldShowHistory(
                inSessionWorkspace: true,
                receiptCount: ledger.receipts(executionID: "execution-1").count
            ),
            "receipt history disappeared while the live-card projection was between attempts"
        )
        require(
            !OuroborosSteeringReceiptPresentation.shouldShowHistory(
                inSessionWorkspace: false,
                receiptCount: 2
            ),
            "receipt history leaked into the compact reading surface"
        )
        let uncertain = OuroborosSteeringReceipt(
            summary: "Provider acknowledgement boundary is uncertain",
            state: .deliveryUncertain,
            applicationProven: false,
            failureReason: "Provider acknowledgement was not durable",
            retryable: nil
        )
        require(
            OuroborosSteeringReceiptPresentation.text(uncertain).contains("Retryability not provided"),
            "unknown retryability was hidden or guessed"
        )

        var boundedLedger = OuroborosSteeringReceiptLedger()
        for index in 0..<40 {
            boundedLedger.record(OuroborosSteeringReceipt(
                summary: "receipt \(index)",
                state: .completed,
                applicationProven: true,
                signalID: "bounded-signal-\(index)",
                idempotencyKey: "bounded-key-\(index)",
                target: target,
                message: "message \(index)"
            ))
        }
        require(
            boundedLedger.receipts(executionID: "execution-1").count == 32,
            "per-execution receipt retention is unbounded"
        )
        for index in 0..<10 {
            let executionTarget = OuroborosSteeringTargetV1(
                executionID: "retained-execution-\(index)",
                scopeID: "scope",
                attemptID: "attempt",
                contractVersion: 1,
                modes: ["after_turn"]
            )
            boundedLedger.record(OuroborosSteeringReceipt(
                summary: "execution \(index)",
                state: .completed,
                applicationProven: true,
                signalID: "execution-signal-\(index)",
                idempotencyKey: "execution-key-\(index)",
                target: executionTarget,
                message: "done"
            ))
        }
        require(
            boundedLedger.receiptsByExecution.count == 8,
            "execution receipt retention is unbounded"
        )

        var targetRetention = OuroborosSteeringTargetKeyRetention(limit: 3)
        require(targetRetention.touch("attempt-a").isEmpty, "first target evicted early")
        _ = targetRetention.touch("attempt-b")
        _ = targetRetention.touch("attempt-c")
        _ = targetRetention.touch("attempt-a")
        require(
            targetRetention.touch("attempt-d") == ["attempt-b"]
                && targetRetention.keys == ["attempt-c", "attempt-a", "attempt-d"],
            "target-key LRU did not bound or retain recently used attempts"
        )
        require(
            OuroborosSteeringReceiptPollingPolicy.maximumObservationSeconds >= 600,
            "receipt polling cannot outlive a long provider turn"
        )
        require(
            OuroborosSteeringReceiptPollingPolicy.delay(at: 500) <= 5,
            "steady-state receipt polling is too aggressive or unbounded"
        )
        print("PASS: authenticated exact Ouroboros steering contract")
    }
}
