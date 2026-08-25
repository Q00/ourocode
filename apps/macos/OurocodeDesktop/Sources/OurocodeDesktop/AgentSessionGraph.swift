import Foundation

struct AgentSessionGraphNode: Equatable {
    let id: String
    let parentID: String?
    let kind: String
    let title: String
    let status: String
    let summary: String
    let sessionID: String?
    let createdAt: UInt64
    let lastActivity: UInt64
    let capabilities: Set<String>
}

struct AgentSessionGraphSnapshot: Equatable {
    let providerID: String
    let instanceID: UUID
    let nonce: String
    let generation: String
    let revision: UInt64
    let processID: Int32
    let updatedAt: UInt64
    let nodes: [AgentSessionGraphNode]
}

enum AgentSessionGraphSnapshotFailure: Error, Equatable {
    case malformed
    case identityMismatch
    case invalidValue
    case duplicateNode
    case missingParent
    case cycle
    case rootCount
    case capacityExceeded
}

enum AgentSessionGraphSnapshotDecoder {
    static let maximumBytes = 1_048_576
    static let maximumNodes = 256
    private static let maximumIdentifierBytes = 512
    private static let maximumTextBytes = 4_096

    static func decode(
        _ data: Data,
        expectedInstanceID: UUID,
        expectedNonce: String
    ) -> Result<AgentSessionGraphSnapshot, AgentSessionGraphSnapshotFailure> {
        guard !data.isEmpty, data.count <= maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              exactKeys(
                object,
                required: [
                    "version", "provider_id", "instance_id", "nonce", "generation",
                    "revision", "process_id", "updated_at_ms", "nodes",
                ]
              ),
              integer(object["version"]) == 1,
              let providerID = boundedString(object["provider_id"], maximum: maximumIdentifierBytes),
              let instanceValue = boundedString(object["instance_id"], maximum: 64),
              let instanceID = UUID(uuidString: instanceValue),
              let nonce = boundedString(object["nonce"], maximum: 128),
              let generation = boundedString(object["generation"], maximum: 128),
              let revision = unsignedInteger(object["revision"]), revision > 0,
              let process = integer(object["process_id"]), process > 0, process <= Int64(Int32.max),
              let updatedAt = unsignedInteger(object["updated_at_ms"]), updatedAt > 0,
              let rawNodes = object["nodes"] as? [[String: Any]],
              !rawNodes.isEmpty else {
            return .failure(.malformed)
        }
        guard instanceID == expectedInstanceID, nonce == expectedNonce else {
            return .failure(.identityMismatch)
        }
        guard rawNodes.count <= maximumNodes else {
            return .failure(.capacityExceeded)
        }

        var nodes: [AgentSessionGraphNode] = []
        nodes.reserveCapacity(rawNodes.count)
        var ids = Set<String>()
        for raw in rawNodes {
            guard exactKeys(
                raw,
                required: [
                    "id", "parent_id", "kind", "title", "status", "summary",
                    "session_id", "created_at_ms", "last_activity_ms", "capabilities",
                ]
            ),
            let id = boundedString(raw["id"], maximum: maximumIdentifierBytes),
            let kind = boundedString(raw["kind"], maximum: 32),
            ["main", "sub", "advisor"].contains(kind),
            let title = boundedText(raw["title"]),
            let status = boundedString(raw["status"], maximum: 32),
            ["running", "idle", "parked", "aborted"].contains(status),
            let summary = boundedText(raw["summary"]),
            let createdAt = unsignedInteger(raw["created_at_ms"]),
            let lastActivity = unsignedInteger(raw["last_activity_ms"]),
            let rawCapabilities = raw["capabilities"] as? [String],
            rawCapabilities.count <= 16,
            rawCapabilities.allSatisfy({ boundedString($0, maximum: 64) != nil }) else {
                return .failure(.invalidValue)
            }
            guard ids.insert(id).inserted else { return .failure(.duplicateNode) }
            let parentID: String?
            if raw["parent_id"] is NSNull {
                parentID = nil
            } else {
                guard let value = boundedString(raw["parent_id"], maximum: maximumIdentifierBytes) else {
                    return .failure(.invalidValue)
                }
                parentID = value
            }
            let sessionID: String?
            if raw["session_id"] is NSNull {
                sessionID = nil
            } else {
                guard let value = boundedString(raw["session_id"], maximum: maximumIdentifierBytes) else {
                    return .failure(.invalidValue)
                }
                sessionID = value
            }
            nodes.append(AgentSessionGraphNode(
                id: id,
                parentID: parentID,
                kind: kind,
                title: title,
                status: status,
                summary: summary,
                sessionID: sessionID,
                createdAt: createdAt,
                lastActivity: lastActivity,
                capabilities: Set(rawCapabilities)
            ))
        }

        let knownIDs = Set(nodes.map(\.id))
        guard nodes.allSatisfy({ $0.parentID.map(knownIDs.contains) ?? true }) else {
            return .failure(.missingParent)
        }
        guard nodes.filter({ $0.parentID == nil }).count == 1 else {
            return .failure(.rootCount)
        }
        guard isAcyclic(nodes) else { return .failure(.cycle) }

        return .success(AgentSessionGraphSnapshot(
            providerID: providerID,
            instanceID: instanceID,
            nonce: nonce,
            generation: generation,
            revision: revision,
            processID: Int32(process),
            updatedAt: updatedAt,
            nodes: nodes
        ))
    }

    private static func isAcyclic(_ nodes: [AgentSessionGraphNode]) -> Bool {
        let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0.parentID) })
        for node in nodes {
            var seen = Set<String>()
            var cursor: String? = node.id
            while let id = cursor {
                guard seen.insert(id).inserted else { return false }
                cursor = parents[id] ?? nil
            }
        }
        return true
    }

    private static func exactKeys(_ object: [String: Any], required: Set<String>) -> Bool {
        Set(object.keys) == required
    }

    private static func boundedText(_ value: Any?) -> String? {
        boundedString(value, maximum: maximumTextBytes)
    }

    private static func boundedString(_ value: Any?, maximum: Int) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else {
            return nil
        }
        return value
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.int64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func unsignedInteger(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.int64Value >= 0 else { return nil }
        let result = number.uint64Value
        return NSNumber(value: result) == number ? result : nil
    }
}
