import Foundation

/// Strict, bounded decoder for the structured `_meta` emitted by
/// Ouroboros 0.51.6 `ouroboros_query_projection`.
///
/// This is a read model only. It does not infer identity from text content,
/// tolerate partial projections, or grant terminal/steering authority.
enum OuroborosRunProjectionV0516 {
    static let serverName = "ouroboros-mcp"
    static let serverVersion = "0.51.6"
    static let toolName = "ouroboros_query_projection"

    static let maximumEventCount = 2_048
    static let maximumStageCount = 64
    static let maximumStepCount = 512
    static let maximumArtifactCount = 512
    static let maximumVerdictCount = 128
    static let maximumSummaryBytes = 16 * 1_024

    enum StepKind: String, Equatable {
        case modelCall = "model_call"
        case toolCall = "tool_call"
        case shellCommand = "shell_command"
        case subagentDispatch = "subagent_dispatch"
        case pluginCommand = "plugin_command"
        case evaluationCheck = "evaluation_check"
        case evidenceSubmission = "evidence_submission"
        case harnessInternal = "harness_internal"
    }

    struct Run: Equatable {
        let runID: String
        let seedID: String
        let goal: String
    }

    struct Step: Equatable {
        let id: String
        let kind: StepKind
        let name: String
        let acceptanceCriterionID: String?
        let ok: Bool?
    }

    struct Counts: Equatable {
        let events: Int
        let stages: Int
        let steps: Int
        let artifacts: Int
        let verdicts: Int
    }

    struct Snapshot: Equatable {
        let sessionID: String
        let executionID: String
        let run: Run
        let steps: [Step]
        let counts: Counts
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case incompatibleServer
        case invalidIdentity
        case malformedToolResult
        case mismatchedIdentity
        case capacityExceeded
        case malformedProjection
        case conflictingProjection

        var description: String {
            switch self {
            case .incompatibleServer: "Run projection is unavailable for this Ouroboros version"
            case .invalidIdentity: "Run projection requires exact session and execution identities"
            case .malformedToolResult: "Run projection returned an invalid MCP tool result"
            case .mismatchedIdentity: "Run projection metadata did not match the requested session and execution"
            case .capacityExceeded: "Run projection exceeded a bounded collection limit"
            case .malformedProjection: "Run projection structured metadata was malformed"
            case .conflictingProjection: "Run projection contained conflicting record links"
            }
        }
    }

    private struct Stage {
        let id: String
        let stepIDs: [String]
    }

    private struct Artifact {
        let id: String
        let stepID: String
    }

    private struct Verdict {
        let id: String
        let runID: String
        let scope: String
        let acceptanceCriterionID: String?
        let evidenceArtifactIDs: [String]
    }

    private static let metaKeys: Set<String> = [
        "session_id", "execution_id", "seed_id", "seed_id_source",
        "event_count", "limit", "run", "stages", "steps", "artifacts", "verdicts",
    ]
    private static let runKeys: Set<String> = [
        "schema_version", "run_id", "seed_id", "goal", "started_at", "ended_at",
        "stage_ids", "verdict_id", "metadata",
    ]
    private static let stageKeys: Set<String> = [
        "schema_version", "stage_id", "run_id", "kind", "started_at", "ended_at",
        "step_ids", "metadata",
    ]
    private static let stepKeys: Set<String> = [
        "schema_version", "step_id", "run_id", "stage_id", "kind", "name", "ac_id",
        "started_at", "ended_at", "ok", "source_event_ids", "legacy_inferred",
        "artifact_ids", "metadata",
    ]
    private static let artifactKeys: Set<String> = [
        "schema_version", "artifact_id", "step_id", "kind", "path", "media_type",
        "size_bytes", "digest", "summary", "metadata",
    ]
    private static let verdictKeys: Set<String> = [
        "schema_version", "verdict_id", "run_id", "scope", "ac_id", "outcome",
        "rationale", "evidence_event_ids", "evidence_artifact_ids", "recorded_at", "metadata",
    ]

    static func supports(serverName: String, serverVersion: String) -> Bool {
        serverName == self.serverName && serverVersion == self.serverVersion
    }

    /// The decoder expects the exact identities and limit encoded here.
    static func toolArguments(sessionID: String, executionID: String) -> [String: Any]? {
        guard validIdentifier(sessionID, maximumBytes: 1_024),
              validIdentifier(executionID, maximumBytes: 1_024) else { return nil }
        return [
            "session_id": sessionID,
            "execution_id": executionID,
            "limit": maximumEventCount,
        ]
    }

    static func decode(
        response: [String: Any],
        sessionID: String,
        executionID: String
    ) -> Result<Snapshot, Failure> {
        guard toolArguments(sessionID: sessionID, executionID: executionID) != nil else {
            return .failure(.invalidIdentity)
        }
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              exactBoolean(result["isError"]) == false,
              let content = result["content"] as? [[String: Any]],
              content.count == 1,
              content[0]["type"] as? String == "text",
              let summary = content[0]["text"] as? String,
              summary.utf8.count <= maximumSummaryBytes,
              let meta = result["_meta"] as? [String: Any] else {
            return .failure(.malformedToolResult)
        }
        guard Set(meta.keys) == metaKeys else { return .failure(.malformedProjection) }
        guard meta["session_id"] as? String == sessionID,
              meta["execution_id"] as? String == executionID else {
            return .failure(.mismatchedIdentity)
        }
        guard exactInteger(meta["limit"]) == maximumEventCount,
              let eventCount = exactInteger(meta["event_count"]),
              eventCount >= 0,
              let seedID = meta["seed_id"] as? String,
              validIdentifier(seedID, maximumBytes: 1_024),
              let seedSource = meta["seed_id_source"] as? String,
              ["argument", "event", "fallback"].contains(seedSource),
              let runObject = meta["run"] as? [String: Any],
              let stageObjects = meta["stages"] as? [[String: Any]],
              let stepObjects = meta["steps"] as? [[String: Any]],
              let artifactObjects = meta["artifacts"] as? [[String: Any]],
              let verdictObjects = meta["verdicts"] as? [[String: Any]] else {
            return .failure(.malformedProjection)
        }
        guard eventCount <= maximumEventCount,
              stageObjects.count <= maximumStageCount,
              stepObjects.count <= maximumStepCount,
              artifactObjects.count <= maximumArtifactCount,
              verdictObjects.count <= maximumVerdictCount else {
            return .failure(.capacityExceeded)
        }
        guard let run = decodeRun(runObject, expectedSeedID: seedID),
              let stages = decodeStages(stageObjects, runID: run.runID),
              let decodedSteps = decodeSteps(stepObjects, runID: run.runID),
              let artifacts = decodeArtifacts(artifactObjects),
              let verdicts = decodeVerdicts(verdictObjects) else {
            return .failure(.malformedProjection)
        }
        guard projectionLinksAgree(
            runObject: runObject,
            run: run,
            stages: stages,
            decodedSteps: decodedSteps,
            artifacts: artifacts,
            verdicts: verdicts
        ) else {
            return .failure(.conflictingProjection)
        }
        return .success(Snapshot(
            sessionID: sessionID,
            executionID: executionID,
            run: run,
            steps: decodedSteps.map(\.step),
            counts: Counts(
                events: eventCount,
                stages: stages.count,
                steps: decodedSteps.count,
                artifacts: artifacts.count,
                verdicts: verdicts.count
            )
        ))
    }

    private static func decodeRun(_ object: [String: Any], expectedSeedID: String) -> Run? {
        guard Set(object.keys) == runKeys,
              exactInteger(object["schema_version"]) == 1,
              let runID = object["run_id"] as? String,
              validIdentifier(runID, maximumBytes: 1_024),
              object["seed_id"] as? String == expectedSeedID,
              let goal = object["goal"] as? String,
              validText(goal, maximumBytes: 8_192),
              validTimestamp(object["started_at"]),
              validNullableTimestamp(object["ended_at"]),
              identifierArray(object["stage_ids"], maximumCount: maximumStageCount) != nil,
              validNullableIdentifier(object["verdict_id"], maximumBytes: 1_024),
              validMetadata(object["metadata"]) else { return nil }
        return Run(runID: runID, seedID: expectedSeedID, goal: goal)
    }

    private static func decodeStages(_ objects: [[String: Any]], runID: String) -> [Stage]? {
        var ids = Set<String>()
        var result: [Stage] = []
        result.reserveCapacity(objects.count)
        for object in objects {
            guard Set(object.keys) == stageKeys,
                  exactInteger(object["schema_version"]) == 1,
                  let id = object["stage_id"] as? String,
                  validIdentifier(id, maximumBytes: 1_024),
                  ids.insert(id).inserted,
                  object["run_id"] as? String == runID,
                  let kind = object["kind"] as? String,
                  ["interview", "seed", "execute", "evaluate", "evolve", "plugin", "hitl"].contains(kind),
                  validTimestamp(object["started_at"]),
                  validNullableTimestamp(object["ended_at"]),
                  let stepIDs = identifierArray(object["step_ids"], maximumCount: maximumStepCount),
                  validMetadata(object["metadata"]) else { return nil }
            result.append(Stage(id: id, stepIDs: stepIDs))
        }
        return result
    }

    private static func decodeSteps(
        _ objects: [[String: Any]],
        runID: String
    ) -> [(step: Step, stageID: String, sourceEventIDs: [String], artifactIDs: [String])]? {
        var ids = Set<String>()
        var result: [(Step, String, [String], [String])] = []
        result.reserveCapacity(objects.count)
        for object in objects {
            guard Set(object.keys) == stepKeys,
                  exactInteger(object["schema_version"]) == 1,
                  let id = object["step_id"] as? String,
                  validIdentifier(id, maximumBytes: 1_024),
                  ids.insert(id).inserted,
                  object["run_id"] as? String == runID,
                  let stageID = object["stage_id"] as? String,
                  validIdentifier(stageID, maximumBytes: 1_024),
                  let rawKind = object["kind"] as? String,
                  let kind = StepKind(rawValue: rawKind),
                  let name = object["name"] as? String,
                  validText(name, maximumBytes: 512),
                  validNullableIdentifier(object["ac_id"], maximumBytes: 1_024),
                  validTimestamp(object["started_at"]),
                  validNullableTimestamp(object["ended_at"]),
                  validNullableBoolean(object["ok"]),
                  let sourceEventIDs = identifierArray(object["source_event_ids"], maximumCount: 32),
                  let legacyInferred = exactBoolean(object["legacy_inferred"]),
                  let artifactIDs = identifierArray(object["artifact_ids"], maximumCount: maximumArtifactCount),
                  validMetadata(object["metadata"]),
                  legacyInferred || !sourceEventIDs.isEmpty else { return nil }
            let acID = object["ac_id"] is NSNull ? nil : object["ac_id"] as? String
            let ok = object["ok"] is NSNull ? nil : exactBoolean(object["ok"])
            result.append((
                Step(id: id, kind: kind, name: name, acceptanceCriterionID: acID, ok: ok),
                stageID,
                sourceEventIDs,
                artifactIDs
            ))
        }
        return result
    }

    private static func decodeArtifacts(_ objects: [[String: Any]]) -> [Artifact]? {
        var ids = Set<String>()
        var result: [Artifact] = []
        result.reserveCapacity(objects.count)
        for object in objects {
            guard Set(object.keys) == artifactKeys,
                  exactInteger(object["schema_version"]) == 1,
                  let id = object["artifact_id"] as? String,
                  validIdentifier(id, maximumBytes: 1_024),
                  ids.insert(id).inserted,
                  let stepID = object["step_id"] as? String,
                  validIdentifier(stepID, maximumBytes: 1_024),
                  let kind = object["kind"] as? String,
                  validText(kind, maximumBytes: 256),
                  !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  validNullableText(object["path"], maximumBytes: 4_096),
                  validNullableText(object["media_type"], maximumBytes: 256),
                  validNullableNonnegativeInteger(object["size_bytes"]),
                  validNullableText(object["digest"], maximumBytes: 512),
                  let summary = object["summary"] as? String,
                  validText(summary, maximumBytes: 2_048),
                  validMetadata(object["metadata"]) else { return nil }
            result.append(Artifact(id: id, stepID: stepID))
        }
        return result
    }

    private static func decodeVerdicts(_ objects: [[String: Any]]) -> [Verdict]? {
        var ids = Set<String>()
        var result: [Verdict] = []
        result.reserveCapacity(objects.count)
        for object in objects {
            guard Set(object.keys) == verdictKeys,
                  exactInteger(object["schema_version"]) == 1,
                  let id = object["verdict_id"] as? String,
                  validIdentifier(id, maximumBytes: 1_024),
                  ids.insert(id).inserted,
                  let runID = object["run_id"] as? String,
                  validIdentifier(runID, maximumBytes: 1_024),
                  let scope = object["scope"] as? String,
                  ["run", "ac"].contains(scope),
                  validNullableIdentifier(object["ac_id"], maximumBytes: 1_024),
                  let outcome = object["outcome"] as? String,
                  ["pass", "fail", "escalate_human", "cancelled", "unknown"].contains(outcome),
                  let rationale = object["rationale"] as? String,
                  validText(rationale, maximumBytes: 4_096),
                  identifierArray(object["evidence_event_ids"], maximumCount: maximumEventCount) != nil,
                  let evidenceArtifactIDs = identifierArray(
                    object["evidence_artifact_ids"],
                    maximumCount: maximumArtifactCount
                  ),
                  validTimestamp(object["recorded_at"]),
                  validMetadata(object["metadata"]) else { return nil }
            let acID = object["ac_id"] is NSNull ? nil : object["ac_id"] as? String
            guard (scope == "ac" && acID != nil) || (scope == "run" && acID == nil) else { return nil }
            result.append(Verdict(
                id: id,
                runID: runID,
                scope: scope,
                acceptanceCriterionID: acID,
                evidenceArtifactIDs: evidenceArtifactIDs
            ))
        }
        return result
    }

    private static func projectionLinksAgree(
        runObject: [String: Any],
        run: Run,
        stages: [Stage],
        decodedSteps: [(step: Step, stageID: String, sourceEventIDs: [String], artifactIDs: [String])],
        artifacts: [Artifact],
        verdicts: [Verdict]
    ) -> Bool {
        guard let runStageIDs = identifierArray(runObject["stage_ids"], maximumCount: maximumStageCount),
              runStageIDs == stages.map(\.id) else { return false }
        let stepIDs = decodedSteps.map(\.step.id)
        guard stages.flatMap(\.stepIDs) == stepIDs else { return false }
        let stageIDs = Set(stages.map(\.id))
        guard decodedSteps.allSatisfy({ stageIDs.contains($0.stageID) }) else { return false }

        let artifactIDs = Set(artifacts.map(\.id))
        let stepIDSet = Set(stepIDs)
        guard artifacts.allSatisfy({ stepIDSet.contains($0.stepID) }),
              decodedSteps.allSatisfy({ Set($0.artifactIDs).isSubset(of: artifactIDs) }) else { return false }

        guard verdicts.allSatisfy({
            $0.runID == run.runID && Set($0.evidenceArtifactIDs).isSubset(of: artifactIDs)
        }) else { return false }
        let runVerdictID = runObject["verdict_id"] is NSNull ? nil : runObject["verdict_id"] as? String
        if let runVerdictID {
            guard verdicts.contains(where: { $0.id == runVerdictID && $0.scope == "run" }) else { return false }
        }
        return true
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let integer = number.intValue
        return NSNumber(value: integer) == number ? integer : nil
    }

    private static func exactBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func validNullableBoolean(_ value: Any?) -> Bool {
        value is NSNull || exactBoolean(value) != nil
    }

    private static func validNullableNonnegativeInteger(_ value: Any?) -> Bool {
        if value is NSNull { return true }
        guard let integer = exactInteger(value) else { return false }
        return integer >= 0
    }

    private static func identifierArray(
        _ value: Any?,
        maximumCount: Int
    ) -> [String]? {
        guard let values = value as? [Any], values.count <= maximumCount else { return nil }
        var seen = Set<String>()
        var result: [String] = []
        result.reserveCapacity(values.count)
        for value in values {
            guard let identifier = value as? String,
                  validIdentifier(identifier, maximumBytes: 1_024),
                  seen.insert(identifier).inserted else { return nil }
            result.append(identifier)
        }
        return result
    }

    private static func validIdentifier(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func validNullableIdentifier(_ value: Any?, maximumBytes: Int) -> Bool {
        if value is NSNull { return true }
        guard let value = value as? String else { return false }
        return validIdentifier(value, maximumBytes: maximumBytes)
    }

    private static func validText(_ value: String, maximumBytes: Int) -> Bool {
        value.utf8.count <= maximumBytes && !value.unicodeScalars.contains(where: { $0.value == 0 })
    }

    private static func validNullableText(_ value: Any?, maximumBytes: Int) -> Bool {
        if value is NSNull { return true }
        guard let value = value as? String else { return false }
        return validText(value, maximumBytes: maximumBytes)
    }

    private static func validTimestamp(_ value: Any?) -> Bool {
        guard let value = value as? String,
              value.utf8.count >= 19,
              value.utf8.count <= 64,
              value.contains("T") else { return false }
        return !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private static func validNullableTimestamp(_ value: Any?) -> Bool {
        value is NSNull || validTimestamp(value)
    }

    private static func validMetadata(_ value: Any?) -> Bool {
        guard let metadata = value as? [String: Any], metadata.count <= 64 else { return false }
        return metadata.keys.allSatisfy {
            !$0.isEmpty && $0.utf8.count <= 256 && !$0.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        }
    }
}
