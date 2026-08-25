import Foundation

/// Exact Ouroboros 0.51.6 compatibility decoder for one activated session.
///
/// The server truncates each event payload to a human-readable preview, so
/// this is deliberately called "Recent events", not a transcript. Six small,
/// event-type-indexed requests run in parallel. No request follows an older
/// page and the merged presentation never retains more than 64 events.
enum OuroborosSessionDetailProjectionV0511 {
    static let serverName = "ouroboros-mcp"
    static let serverVersion = "0.51.6"
    static let toolName = "ouroboros_query_events"
    static let requestLimit = 24
    static let visibleEventLimit = 64
    static let maximumResponseTextBytes = 128 * 1_024

    /// Exact semantic subject for this one-shot snapshot request. A future
    /// pagination cursor must be server-issued, monotonic, and paired with a
    /// service epoch; it must not be synthesized from these identifiers.
    struct AttemptFilter: Equatable {
        let executionID: String
        let scopeID: String
        let attemptID: String
    }

    enum EventType: String, CaseIterable {
        case sessionStarted = "orchestrator.session.started"
        case attemptDispatched = "execution.ac.attempt.dispatched"
        case acCompleted = "execution.ac.completed"
        case executionTerminal = "execution.terminal"
        case sessionCompleted = "orchestrator.session.completed"
        case sessionFailed = "orchestrator.session.failed"
    }

    struct Event: Equatable {
        let id: String
        let type: EventType
        let timestamp: String
        let aggregateType: String
        let aggregateID: String
        let summary: String
    }

    struct Page: Equatable {
        let eventType: EventType
        let events: [Event]
        let mayHaveOlderEvents: Bool
    }

    struct Snapshot: Equatable {
        let sessionID: String
        let executionID: String
        let attemptFilter: AttemptFilter?
        let events: [Event]
        let moreAvailable: Bool
        let runProjection: OuroborosRunProjectionV0516.Snapshot?
    }

    enum Failure: Error, Equatable, CustomStringConvertible {
        case incompatibleServer
        case invalidIdentity
        case malformedToolResult
        case responseTooLarge
        case malformedText
        case mismatchedPage
        case duplicateEvent
        case exactAttemptUnavailable

        var description: String {
            switch self {
            case .incompatibleServer: "Recent events are unavailable for this Ouroboros version"
            case .invalidIdentity: "The selected session identity is invalid"
            case .malformedToolResult: "Recent event query returned an invalid MCP tool result"
            case .responseTooLarge: "Recent event query exceeded its 128 KiB page safety bound"
            case .malformedText: "Ouroboros 0.51.6 recent event text changed unexpectedly"
            case .mismatchedPage: "Recent event query metadata did not match the activation"
            case .duplicateEvent: "Recent event queries repeated an event identity"
            case .exactAttemptUnavailable:
                "This Ouroboros server exposes group activity only; Agent activity requires exact-attempt projection"
            }
        }
    }

    static func supports(serverName: String, serverVersion: String) -> Bool {
        serverName == self.serverName && serverVersion == self.serverVersion
    }

    static func attemptFilter(
        executionID: String,
        scopeID: String,
        attemptID: String
    ) -> AttemptFilter? {
        guard validIdentifier(executionID, maximumLength: 1_024),
              validIdentifier(scopeID, maximumLength: 1_024),
              validIdentifier(attemptID, maximumLength: 1_024) else { return nil }
        return AttemptFilter(
            executionID: executionID,
            scopeID: scopeID,
            attemptID: attemptID
        )
    }

    static func toolArguments(
        sessionID: String,
        eventType: EventType,
        attemptFilter: AttemptFilter? = nil
    ) -> [String: Any]? {
        guard validIdentifier(sessionID, maximumLength: 1_024) else { return nil }
        var arguments: [String: Any] = [
            "session_id": sessionID,
            "event_type": eventType.rawValue,
            "limit": requestLimit,
            "offset": 0,
        ]
        if let attemptFilter {
            arguments["execution_id"] = attemptFilter.executionID
            arguments["session_scope_id"] = attemptFilter.scopeID
            arguments["session_attempt_id"] = attemptFilter.attemptID
        }
        return arguments
    }

    static func decodePage(
        response: [String: Any],
        sessionID: String,
        eventType: EventType,
        attemptFilter: AttemptFilter? = nil
    ) -> Result<Page, Failure> {
        guard toolArguments(
            sessionID: sessionID,
            eventType: eventType,
            attemptFilter: attemptFilter
        ) != nil else {
            return .failure(.invalidIdentity)
        }
        if attemptFilter != nil,
           response["error"] != nil
            || ((response["result"] as? [String: Any])?["isError"] as? Bool == true) {
            // Ouroboros 0.51.x accepts the legacy session query but does not
            // implement the exact child filters. Do not let that protocol
            // error degrade into a misleading session-wide Activity view.
            return .failure(.exactAttemptUnavailable)
        }
        guard response["error"] == nil,
              let result = response["result"] as? [String: Any],
              result["isError"] as? Bool == false,
              let meta = result["_meta"] as? [String: Any],
              exactInteger(meta["offset"]) == 0,
              exactInteger(meta["limit"]) == requestLimit,
              let reportedCount = exactInteger(meta["total_events"]),
              reportedCount >= 0,
              reportedCount <= requestLimit,
              let content = result["content"] as? [[String: Any]],
              content.count == 1,
              content[0]["type"] as? String == "text",
              let text = content[0]["text"] as? String else {
            return .failure(.malformedToolResult)
        }
        if let attemptFilter {
            guard let executionID = meta["execution_id"] as? String,
                  let scopeID = meta["session_scope_id"] as? String,
                  let attemptID = meta["session_attempt_id"] as? String else {
                // Stock 0.51.6 ignores unknown exact-attempt arguments and
                // returns a session-wide page. Never accept that broader page
                // for a leaf merely because offset/limit happen to match.
                return .failure(.exactAttemptUnavailable)
            }
            guard executionID == attemptFilter.executionID,
                  scopeID == attemptFilter.scopeID,
                  attemptID == attemptFilter.attemptID else {
                return .failure(.mismatchedPage)
            }
        }
        guard text.utf8.count <= maximumResponseTextBytes else {
            return .failure(.responseTooLarge)
        }
        guard let events = parseText(
            text,
            sessionID: sessionID,
            eventType: eventType,
            expectedCount: reportedCount
        ) else {
            return .failure(.malformedText)
        }
        return .success(Page(
            eventType: eventType,
            events: events,
            mayHaveOlderEvents: events.count == requestLimit
        ))
    }

    static func build(
        pages: [Page],
        sessionID: String,
        executionID: String,
        attemptFilter: AttemptFilter? = nil,
        runProjection: OuroborosRunProjectionV0516.Snapshot? = nil
    ) -> Result<Snapshot, Failure> {
        guard validIdentifier(sessionID, maximumLength: 1_024),
              validIdentifier(executionID, maximumLength: 1_024),
              pages.count == EventType.allCases.count,
              Set(pages.map(\.eventType)) == Set(EventType.allCases) else {
            return .failure(.mismatchedPage)
        }
        var eventIDs = Set<String>()
        let allEvents = pages.flatMap(\.events)
        for event in allEvents where !eventIDs.insert(event.id).inserted {
            return .failure(.duplicateEvent)
        }
        let newest = allEvents.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
            return $0.id > $1.id
        }
        let visible = Array(newest.prefix(visibleEventLimit)).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.id < $1.id
        }
        return .success(Snapshot(
            sessionID: sessionID,
            executionID: executionID,
            attemptFilter: attemptFilter,
            events: visible,
            moreAvailable: newest.count > visibleEventLimit || pages.contains(where: \.mayHaveOlderEvents),
            runProjection: runProjection
        ))
    }

    private static func parseText(
        _ text: String,
        sessionID: String,
        eventType: EventType,
        expectedCount: Int
    ) -> [Event]? {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        guard !normalized.contains("\r") else { return nil }
        var lines = normalized.components(separatedBy: "\n")
        while lines.last == "" { lines.removeLast() }
        guard lines.count >= 6,
              lines[0] == "Event Query Results",
              lines[1] == String(repeating: "=", count: 60),
              lines[2] == "Session: \(sessionID)",
              lines[3] == "Type filter: \(eventType.rawValue)",
              lines[4] == "Showing 0 to \(expectedCount) (found \(expectedCount) events)",
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
            guard cursor + 4 < lines.count,
                  lines[cursor] == "\(events.count + 1). [\(eventType.rawValue)]",
                  let id = value(after: "   ID: ", in: lines[cursor + 1]),
                  validIdentifier(id, maximumLength: 256),
                  let timestamp = value(after: "   Timestamp: ", in: lines[cursor + 2]),
                  validTimestamp(timestamp),
                  let aggregate = value(after: "   Aggregate: ", in: lines[cursor + 3]),
                  let slash = aggregate.firstIndex(of: "/"),
                  slash != aggregate.startIndex,
                  aggregate.index(after: slash) != aggregate.endIndex,
                  let summary = value(after: "   Data: ", in: lines[cursor + 4]) else { return nil }
            let aggregateType = String(aggregate[..<slash])
            let aggregateID = String(aggregate[aggregate.index(after: slash)...])
            guard validIdentifier(aggregateType, maximumLength: 100),
                  validIdentifier(aggregateID, maximumLength: 1_024),
                  summary.utf8.count <= 512 else { return nil }
            events.append(Event(
                id: id,
                type: eventType,
                timestamp: timestamp,
                aggregateType: aggregateType,
                aggregateID: aggregateID,
                summary: boundedSummary(summary)
            ))
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
        return NSNumber(value: result) == number ? result : nil
    }

    private static func boundedSummary(_ value: String) -> String {
        let flattened = value.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 180 else { return flattened }
        return String(flattened.prefix(179)) + "…"
    }

    private static func validIdentifier(_ value: String, maximumLength: Int) -> Bool {
        !value.isEmpty && value.count <= maximumLength && value.unicodeScalars.allSatisfy {
            !CharacterSet.controlCharacters.contains($0) &&
                !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private static func validTimestamp(_ value: String) -> Bool {
        guard value.count >= 19, value.count <= 40 else { return false }
        let pattern = #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})?$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
