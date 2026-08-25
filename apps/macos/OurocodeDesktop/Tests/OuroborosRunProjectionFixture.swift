import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private let sessionID = "session-projection-1"
private let executionID = "execution-projection-1"

private func step(
    id: String,
    kind: String,
    name: Any,
    acID: Any,
    ok: Any,
    artifactIDs: [String] = []
) -> [String: Any] {
    [
        "schema_version": 1,
        "step_id": id,
        "run_id": "run-1",
        "stage_id": "stage-1",
        "kind": kind,
        "name": name,
        "ac_id": acID,
        "started_at": "2026-08-16T00:00:00Z",
        "ended_at": ok is NSNull ? NSNull() : "2026-08-16T00:00:01Z",
        "ok": ok,
        "source_event_ids": ["event-\(id)"],
        "legacy_inferred": false,
        "artifact_ids": artifactIDs,
        "metadata": [:],
    ]
}

private func validMeta() -> [String: Any] {
    let steps = [
        step(
            id: "step-1",
            kind: "shell_command",
            name: "Bash",
            acID: "AC-1",
            ok: true,
            artifactIDs: ["artifact-1"]
        ),
        step(
            id: "step-2",
            kind: "model_call",
            name: "planner",
            acID: NSNull(),
            ok: NSNull()
        ),
    ]
    return [
        "session_id": sessionID,
        "execution_id": executionID,
        "seed_id": "seed-1",
        "seed_id_source": "event",
        "event_count": 8,
        "limit": OuroborosRunProjectionV0516.maximumEventCount,
        "run": [
            "schema_version": 1,
            "run_id": "run-1",
            "seed_id": "seed-1",
            "goal": "Build a strict projection",
            "started_at": "2026-08-16T00:00:00Z",
            "ended_at": NSNull(),
            "stage_ids": ["stage-1"],
            "verdict_id": "verdict-1",
            "metadata": [:],
        ],
        "stages": [[
            "schema_version": 1,
            "stage_id": "stage-1",
            "run_id": "run-1",
            "kind": "execute",
            "started_at": "2026-08-16T00:00:00Z",
            "ended_at": NSNull(),
            "step_ids": steps.map { $0["step_id"] as! String },
            "metadata": [:],
        ]],
        "steps": steps,
        "artifacts": [[
            "schema_version": 1,
            "artifact_id": "artifact-1",
            "step_id": "step-1",
            "kind": "evidence",
            "path": "artifacts/result.json",
            "media_type": "application/json",
            "size_bytes": 42,
            "digest": "sha256:abc",
            "summary": "bounded evidence",
            "metadata": [:],
        ]],
        "verdicts": [[
            "schema_version": 1,
            "verdict_id": "verdict-1",
            "run_id": "run-1",
            "scope": "run",
            "ac_id": NSNull(),
            "outcome": "pass",
            "rationale": "verified",
            "evidence_event_ids": ["event-verdict-1"],
            "evidence_artifact_ids": ["artifact-1"],
            "recorded_at": "2026-08-16T00:00:02Z",
            "metadata": [:],
        ]],
    ]
}

private func response(meta: [String: Any] = validMeta()) -> [String: Any] {
    [
        "jsonrpc": "2.0",
        "id": 1,
        "result": [
            "content": [["type": "text", "text": "Run Projection"]],
            "isError": false,
            "_meta": meta,
        ],
    ]
}

private func decoded(_ value: [String: Any]) -> Result<OuroborosRunProjectionV0516.Snapshot, OuroborosRunProjectionV0516.Failure> {
    OuroborosRunProjectionV0516.decode(
        response: value,
        sessionID: sessionID,
        executionID: executionID
    )
}

private func requireFailure(
    _ expected: OuroborosRunProjectionV0516.Failure,
    _ value: [String: Any],
    _ message: String
) {
    require(decoded(value) == .failure(expected), message)
}

@main
private enum OuroborosRunProjectionFixture {
    static func main() {
        require(
            OuroborosRunProjectionV0516.supports(
                serverName: "ouroboros-mcp",
                serverVersion: "0.51.6"
            ),
            "exact Ouroboros projection version was rejected"
        )
        require(
            !OuroborosRunProjectionV0516.supports(
                serverName: "ouroboros-mcp",
                serverVersion: "0.51.7"
            ),
            "unpinned Ouroboros projection version was accepted"
        )
        let arguments = OuroborosRunProjectionV0516.toolArguments(
            sessionID: sessionID,
            executionID: executionID
        )
        require(arguments?["session_id"] as? String == sessionID, "tool arguments lost session identity")
        require(arguments?["execution_id"] as? String == executionID, "tool arguments lost execution identity")
        require(
            arguments?["limit"] as? Int == OuroborosRunProjectionV0516.maximumEventCount,
            "tool arguments lost the event bound"
        )
        require(
            OuroborosRunProjectionV0516.toolArguments(
                sessionID: "bad session",
                executionID: executionID
            ) == nil,
            "whitespace-bearing session identity was accepted"
        )

        switch decoded(response()) {
        case .failure(let failure):
            require(false, "valid structured projection failed: \(failure)")
        case .success(let snapshot):
            require(snapshot.sessionID == sessionID, "snapshot lost session identity")
            require(snapshot.executionID == executionID, "snapshot lost execution identity")
            require(snapshot.run.runID == "run-1", "snapshot lost run id")
            require(snapshot.run.seedID == "seed-1", "snapshot lost seed id")
            require(snapshot.run.goal == "Build a strict projection", "snapshot lost goal")
            require(snapshot.counts.events == 8, "snapshot lost event count")
            require(snapshot.counts.stages == 1, "snapshot lost stage count")
            require(snapshot.counts.steps == 2, "snapshot lost step count")
            require(snapshot.counts.artifacts == 1, "snapshot lost artifact count")
            require(snapshot.counts.verdicts == 1, "snapshot lost verdict count")
            require(snapshot.steps[0].id == "step-1", "step id was not decoded")
            require(snapshot.steps[0].kind == .shellCommand, "step kind was not decoded")
            require(snapshot.steps[0].name == "Bash", "step name was not decoded")
            require(snapshot.steps[0].acceptanceCriterionID == "AC-1", "step AC id was not decoded")
            require(snapshot.steps[0].ok == true, "step success was not decoded")
            require(snapshot.steps[1].acceptanceCriterionID == nil, "null AC id did not stay nil")
            require(snapshot.steps[1].ok == nil, "null step status did not stay nil")
        }

        var mismatchedSession = validMeta()
        mismatchedSession["session_id"] = "session-other"
        requireFailure(.mismatchedIdentity, response(meta: mismatchedSession), "mismatched session was admitted")

        var mismatchedExecution = validMeta()
        mismatchedExecution["execution_id"] = "execution-other"
        requireFailure(.mismatchedIdentity, response(meta: mismatchedExecution), "mismatched execution was admitted")

        var missingMeta = response()
        var missingMetaResult = missingMeta["result"] as! [String: Any]
        missingMetaResult["_meta"] = nil
        missingMeta["result"] = missingMetaResult
        requireFailure(.malformedToolResult, missingMeta, "missing structured metadata was admitted")

        var extraMeta = validMeta()
        extraMeta["unexpected"] = true
        requireFailure(.malformedProjection, response(meta: extraMeta), "unknown metadata field was admitted")

        var wrongLimit = validMeta()
        wrongLimit["limit"] = OuroborosRunProjectionV0516.maximumEventCount - 1
        requireFailure(.malformedProjection, response(meta: wrongLimit), "wrong request limit was admitted")

        var oversizedEvents = validMeta()
        oversizedEvents["event_count"] = OuroborosRunProjectionV0516.maximumEventCount + 1
        requireFailure(.capacityExceeded, response(meta: oversizedEvents), "oversized event count was admitted")

        var oversizedStages = validMeta()
        oversizedStages["stages"] = Array(
            repeating: (validMeta()["stages"] as! [[String: Any]])[0],
            count: OuroborosRunProjectionV0516.maximumStageCount + 1
        )
        requireFailure(.capacityExceeded, response(meta: oversizedStages), "oversized stage list was admitted")

        var oversizedSteps = validMeta()
        oversizedSteps["steps"] = Array(
            repeating: (validMeta()["steps"] as! [[String: Any]])[0],
            count: OuroborosRunProjectionV0516.maximumStepCount + 1
        )
        requireFailure(.capacityExceeded, response(meta: oversizedSteps), "oversized step list was admitted")

        var oversizedArtifacts = validMeta()
        oversizedArtifacts["artifacts"] = Array(
            repeating: (validMeta()["artifacts"] as! [[String: Any]])[0],
            count: OuroborosRunProjectionV0516.maximumArtifactCount + 1
        )
        requireFailure(.capacityExceeded, response(meta: oversizedArtifacts), "oversized artifact list was admitted")

        var oversizedVerdicts = validMeta()
        oversizedVerdicts["verdicts"] = Array(
            repeating: (validMeta()["verdicts"] as! [[String: Any]])[0],
            count: OuroborosRunProjectionV0516.maximumVerdictCount + 1
        )
        requireFailure(.capacityExceeded, response(meta: oversizedVerdicts), "oversized verdict list was admitted")

        var malformedStep = validMeta()
        var malformedSteps = malformedStep["steps"] as! [[String: Any]]
        malformedSteps[0]["ok"] = 1
        malformedStep["steps"] = malformedSteps
        requireFailure(.malformedProjection, response(meta: malformedStep), "integer step status was admitted as Boolean")

        var unknownKind = validMeta()
        var unknownKindSteps = unknownKind["steps"] as! [[String: Any]]
        unknownKindSteps[0]["kind"] = "future_kind"
        unknownKind["steps"] = unknownKindSteps
        requireFailure(.malformedProjection, response(meta: unknownKind), "unknown step kind was admitted")

        var conflictingSeed = validMeta()
        var conflictingRun = conflictingSeed["run"] as! [String: Any]
        conflictingRun["seed_id"] = "seed-other"
        conflictingSeed["run"] = conflictingRun
        requireFailure(.malformedProjection, response(meta: conflictingSeed), "conflicting seed identity was admitted")

        var conflictingStage = validMeta()
        var conflictingStages = conflictingStage["stages"] as! [[String: Any]]
        conflictingStages[0]["step_ids"] = ["step-2", "step-1"]
        conflictingStage["stages"] = conflictingStages
        requireFailure(.conflictingProjection, response(meta: conflictingStage), "conflicting step order was admitted")

        var conflictingArtifact = validMeta()
        var conflictingArtifacts = conflictingArtifact["artifacts"] as! [[String: Any]]
        conflictingArtifacts[0]["step_id"] = "step-missing"
        conflictingArtifact["artifacts"] = conflictingArtifacts
        requireFailure(.conflictingProjection, response(meta: conflictingArtifact), "orphan artifact was admitted")

        var wrongEnvelope = response()
        var wrongEnvelopeResult = wrongEnvelope["result"] as! [String: Any]
        wrongEnvelopeResult["isError"] = 0
        wrongEnvelope["result"] = wrongEnvelopeResult
        requireFailure(.malformedToolResult, wrongEnvelope, "integer isError was admitted as Boolean")

        print("PASS: Ouroboros 0.51.6 structured run projection is exact, bounded, and fail-closed")
    }
}
