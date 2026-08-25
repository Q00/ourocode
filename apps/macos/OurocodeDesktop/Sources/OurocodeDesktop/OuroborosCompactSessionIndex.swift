import Foundation

/// A deliberately narrow compatibility boundary for Ouroboros MCP 0.51.6.
///
/// That release's `ouroboros://sessions` resource reconstructs every persisted
/// session and can retain hundreds of MiB while doing so. The query-events tool
/// is cheap, but its 0.51.6 result is human-readable text rather than a stable
/// structured projection. Keep that text parser pinned to the exact server
/// identity and fail closed if any part of the response changes.
enum OuroborosCompactSessionIndexV0511 {
    static let serverName = "ouroboros-mcp"
    static let serverVersion = "0.51.6"
    static let toolName = "ouroboros_query_events"
    static let pageSize = 256
    static let maximumEventsPerType = 4_096
    static let maximumSessions = 4_096
    static let maximumPageBytes = 512 * 1_024

    enum EventType: String, CaseIterable {
        case sessionStarted = "orchestrator.session.started"
        case executionTerminal = "execution.terminal"
    }

    struct Event: Equatable {
        let id: String
        let type: EventType
        let timestamp: String
        let aggregateType: String
        let aggregateID: String
        let sessionID: String
        let executionID: String
        let status: String?
        let messagesProcessed: Int?
    }

    struct Page: Equatable {
        let eventType: EventType
        let offset: Int
        let limit: Int
        let events: [Event]
    }

    struct Session: Equatable {
        let sessionID: String
        let executionID: String
        let startedAt: String
        let lastActivityAt: String
        let status: String
        let messagesProcessed: Int?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case incompatibleServer
        case malformedToolResult
        case responseTooLarge
        case malformedText
        case mismatchedPage
        case duplicateEvent
        case conflictingIdentity
        case capacityExceeded

        var description: String {
            switch self {
            case .incompatibleServer: "Compact session index is unavailable for this Ouroboros version"
            case .malformedToolResult: "Compact session query returned an invalid MCP tool result"
            case .responseTooLarge: "Compact session query exceeded its page safety bound"
            case .malformedText: "Ouroboros 0.51.6 session event text changed unexpectedly"
            case .mismatchedPage: "Compact session pagination metadata did not match the request"
            case .duplicateEvent: "Compact session pagination repeated an event"
            case .conflictingIdentity: "Compact session events disagreed about session identity"
            case .capacityExceeded: "Compact session index exceeded the 4096-session safety bound"
            }
        }
    }

    static func supports(serverName: String, serverVersion: String) -> Bool {
        serverName == self.serverName && serverVersion == self.serverVersion
    }

    static func toolArguments(eventType: EventType, offset: Int, limit: Int) -> [String: Any]? {
        guard offset >= 0,
              offset <= maximumEventsPerType,
              limit > 0,
              limit <= pageSize,
              offset + limit <= maximumEventsPerType + 1 else { return nil }
        return [
            "event_type": eventType.rawValue,
            "limit": limit,
            "offset": offset,
        ]
    }

    static func decodePage(
        response: [String: Any],
        eventType: EventType,
        offset: Int,
        limit: Int
    ) -> Result<Page, Failure> {
        guard toolArguments(eventType: eventType, offset: offset, limit: limit) != nil else {
            return .failure(.mismatchedPage)
        }
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              result["isError"] as? Bool == false,
              let meta = result["_meta"] as? [String: Any],
              exactInteger(meta["offset"]) == offset,
              exactInteger(meta["limit"]) == limit,
              let reportedCount = exactInteger(meta["total_events"]),
              reportedCount >= 0,
              reportedCount <= limit,
              let content = result["content"] as? [[String: Any]],
              content.count == 1,
              content[0]["type"] as? String == "text",
              let text = content[0]["text"] as? String else {
            return .failure(.malformedToolResult)
        }
        guard text.utf8.count <= maximumPageBytes else { return .failure(.responseTooLarge) }

        guard let events = parseText(text, eventType: eventType, offset: offset, expectedCount: reportedCount),
              events.count == reportedCount else {
            return .failure(.malformedText)
        }
        return .success(Page(eventType: eventType, offset: offset, limit: limit, events: events))
    }

    static func build(events: [Event]) -> Result<[Session], Failure> {
        guard events.count <= EventType.allCases.count * (maximumEventsPerType + 1) else {
            return .failure(.capacityExceeded)
        }
        var eventIDs = Set<String>()
        for event in events where !eventIDs.insert(event.id).inserted {
            return .failure(.duplicateEvent)
        }

        let starts = events.filter { $0.type == .sessionStarted }
        let terminals = events.filter { $0.type == .executionTerminal }
        guard starts.count <= maximumSessions else { return .failure(.capacityExceeded) }

        var startsBySession: [String: Event] = [:]
        for start in starts {
            if let existing = startsBySession[start.sessionID] {
                guard existing.executionID == start.executionID else {
                    return .failure(.conflictingIdentity)
                }
                if start.timestamp > existing.timestamp { startsBySession[start.sessionID] = start }
            } else {
                startsBySession[start.sessionID] = start
            }
        }
        guard startsBySession.count <= maximumSessions else { return .failure(.capacityExceeded) }

        var terminalsBySession: [String: Event] = [:]
        for terminal in terminals {
            guard let start = startsBySession[terminal.sessionID] else {
                continue
            }
            guard terminal.executionID == start.executionID else {
                return .failure(.conflictingIdentity)
            }
            if let existing = terminalsBySession[terminal.sessionID] {
                guard existing.executionID == terminal.executionID else {
                    return .failure(.conflictingIdentity)
                }
                if terminal.timestamp > existing.timestamp { terminalsBySession[terminal.sessionID] = terminal }
            } else {
                terminalsBySession[terminal.sessionID] = terminal
            }
        }

        let sessions = startsBySession.values.map { start -> Session in
            let terminal = terminalsBySession[start.sessionID]
            return Session(
                sessionID: start.sessionID,
                executionID: start.executionID,
                startedAt: start.timestamp,
                lastActivityAt: terminal?.timestamp ?? start.timestamp,
                status: terminal?.status ?? "running",
                messagesProcessed: terminal?.messagesProcessed
            )
        }.sorted {
            if $0.lastActivityAt != $1.lastActivityAt { return $0.lastActivityAt > $1.lastActivityAt }
            return $0.sessionID < $1.sessionID
        }
        return .success(sessions)
    }

    private static func parseText(
        _ text: String,
        eventType: EventType,
        offset: Int,
        expectedCount: Int
    ) -> [Event]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { return nil }
        var lines = normalized.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard lines.count >= 6,
              lines[0] == "Event Query Results",
              lines[1] == String(repeating: "=", count: 60),
              lines[2] == "Session: all",
              lines[3] == "Type filter: \(eventType.rawValue)",
              lines[4] == "Showing \(offset) to \(offset + expectedCount) (found \(expectedCount) events)",
              lines[5].isEmpty else { return nil }

        if expectedCount == 0 {
            guard lines.count == 7,
                  lines[6] == "No events found matching the criteria." else { return nil }
            return []
        }

        var cursor = 6
        var events: [Event] = []
        events.reserveCapacity(expectedCount)
        while cursor < lines.count {
            guard cursor + 4 < lines.count else { return nil }
            let expectedOrdinal = offset + events.count + 1
            guard lines[cursor] == "\(expectedOrdinal). [\(eventType.rawValue)]",
                  let id = value(after: "   ID: ", in: lines[cursor + 1]),
                  validIdentifier(id, maximumLength: 256),
                  let timestamp = value(after: "   Timestamp: ", in: lines[cursor + 2]),
                  validTimestamp(timestamp),
                  let aggregate = value(after: "   Aggregate: ", in: lines[cursor + 3]),
                  let slash = aggregate.firstIndex(of: "/"),
                  slash != aggregate.startIndex,
                  aggregate.index(after: slash) != aggregate.endIndex,
                  let data = value(after: "   Data: ", in: lines[cursor + 4]) else { return nil }

            let aggregateType = String(aggregate[..<slash])
            let aggregateID = String(aggregate[aggregate.index(after: slash)...])
            guard validIdentifier(aggregateType, maximumLength: 64),
                  validIdentifier(aggregateID, maximumLength: 1_024) else { return nil }

            let decoded: Event
            switch eventType {
            case .sessionStarted:
                guard aggregateType == "session",
                      let executionID = pythonDictionaryString("execution_id", from: data),
                      validIdentifier(executionID, maximumLength: 1_024) else { return nil }
                decoded = Event(
                    id: id,
                    type: eventType,
                    timestamp: timestamp,
                    aggregateType: aggregateType,
                    aggregateID: aggregateID,
                    sessionID: aggregateID,
                    executionID: executionID,
                    status: nil,
                    messagesProcessed: nil
                )
            case .executionTerminal:
                guard aggregateType == "execution",
                      let sessionID = pythonDictionaryString("session_id", from: data),
                      let status = pythonDictionaryString("status", from: data),
                      validIdentifier(sessionID, maximumLength: 1_024),
                      validStatus(status) else { return nil }
                decoded = Event(
                    id: id,
                    type: eventType,
                    timestamp: timestamp,
                    aggregateType: aggregateType,
                    aggregateID: aggregateID,
                    sessionID: sessionID,
                    executionID: aggregateID,
                    status: status,
                    messagesProcessed: pythonDictionaryInteger("messages_processed", from: data)
                )
            }
            events.append(decoded)
            cursor += 5
            if cursor < lines.count {
                guard lines[cursor].isEmpty else { return nil }
                cursor += 1
            }
        }
        return events.count == expectedCount ? events : nil
    }

    private static func value(after prefix: String, in line: String) -> String? {
        guard line.hasPrefix(prefix) else { return nil }
        return String(line.dropFirst(prefix.count))
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.intValue
        guard NSNumber(value: result) == number else { return nil }
        return result
    }

    private static func pythonDictionaryString(_ key: String, from data: String) -> String? {
        let marker = "'\(key)': '"
        guard let markerRange = data.range(of: marker) else { return nil }
        var cursor = markerRange.upperBound
        var escaped = false
        var value = ""
        while cursor < data.endIndex {
            let character = data[cursor]
            if escaped {
                // Identifiers emitted by 0.51.6 never require Python escape
                // decoding. Rejecting escapes prevents ambiguous/truncated
                // identities from becoming steering authority.
                return nil
            }
            if character == "\\" {
                escaped = true
            } else if character == "'" {
                return value
            } else {
                value.append(character)
            }
            cursor = data.index(after: cursor)
        }
        return nil
    }

    private static func pythonDictionaryInteger(_ key: String, from data: String) -> Int? {
        let marker = "'\(key)': "
        guard let markerRange = data.range(of: marker) else { return nil }
        let suffix = data[markerRange.upperBound...]
        let digits = suffix.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func validIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func validStatus(_ value: String) -> Bool {
        ["running", "completed", "failed", "blocked", "cancelled", "paused"].contains(value)
    }

    private static func validTimestamp(_ value: String) -> Bool {
        guard value.count >= 19, value.count <= 40 else { return false }
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
