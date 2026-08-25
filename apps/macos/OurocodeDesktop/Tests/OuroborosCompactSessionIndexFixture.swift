import Darwin
import Foundation

// Standalone compatibility fixture. Run from apps/macos/OurocodeDesktop:
// ./test-compact-session-index.sh

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum CompactSessionIndexFixture {
    static func main() {
        if CommandLine.arguments.count == 5,
           CommandLine.arguments[1] == "--decode-sse-stdin" {
            decodeLiveSSE(
                eventTypeName: CommandLine.arguments[2],
                offsetText: CommandLine.arguments[3],
                limitText: CommandLine.arguments[4]
            )
            return
        }

        require(
            OuroborosCompactSessionIndexV0511.supports(
                serverName: "ouroboros-mcp",
                serverVersion: "0.51.6"
            ),
            "exact 0.51.6 server identity was rejected"
        )
        require(
            !OuroborosCompactSessionIndexV0511.supports(
                serverName: "ouroboros-mcp",
                serverVersion: "0.51.2"
            ),
            "plain-text parser escaped its exact version gate"
        )
        require(
            OuroborosCompactSessionIndexV0511.toolArguments(
                eventType: .sessionStarted,
                offset: 4_096,
                limit: 1
            ) != nil,
            "4096-row overflow probe is unavailable"
        )
        require(
            OuroborosCompactSessionIndexV0511.toolArguments(
                eventType: .sessionStarted,
                offset: 4_096,
                limit: 2
            ) == nil,
            "overflow probe accepted more than its one-row bound"
        )

        let startPage = decode(
            response(
                type: .sessionStarted,
                offset: 0,
                limit: 256,
                records: [
                    record(
                        id: "start-2",
                        timestamp: "2026-08-10T10:05:00.000002",
                        aggregate: "session/orch_two",
                        data: "{'execution_id': 'exec_two', 'seed_id': 'seed_two'}"
                    ),
                    record(
                        id: "start-1",
                        timestamp: "2026-08-10T10:00:00.000001",
                        aggregate: "session/orch_one",
                        data: "{'execution_id': 'exec_one', 'seed_id': 'seed_one'}"
                    ),
                ]
            ),
            type: .sessionStarted,
            offset: 0,
            limit: 256
        )
        require(startPage.events.count == 2, "start page cardinality changed")
        require(startPage.events[0].sessionID == "orch_two", "session aggregate was not preserved")
        require(startPage.events[0].executionID == "exec_two", "start execution id was not parsed")

        let terminalPage = decode(
            response(
                type: .executionTerminal,
                offset: 0,
                limit: 256,
                records: [
                    record(
                        id: "terminal-1",
                        timestamp: "2026-08-10T10:09:00.000003",
                        aggregate: "execution/exec_one",
                        data: "{'session_id': 'orch_one', 'status': 'completed', 'messages_processed': 42, 'timestamp': '2026..."
                    ),
                ]
            ),
            type: .executionTerminal,
            offset: 0,
            limit: 256
        )
        require(terminalPage.events[0].status == "completed", "terminal status was not parsed")
        require(terminalPage.events[0].messagesProcessed == 42, "message count was not parsed")

        let sessions = build(startPage.events + terminalPage.events)
        require(sessions.count == 2, "compact index silently imposed a legacy prefix")
        require(sessions[0].sessionID == "orch_one", "sessions are not sorted by last activity")
        require(sessions[0].status == "completed", "terminal status was not aggregated")
        require(sessions[0].messagesProcessed == 42, "terminal activity was not aggregated")
        require(sessions[1].sessionID == "orch_two", "running session disappeared")
        require(sessions[1].status == "running", "missing terminal event did not remain running")

        let secondPage = decode(
            response(
                type: .sessionStarted,
                offset: 256,
                limit: 256,
                records: [
                    record(
                        id: "start-257",
                        timestamp: "2026-08-09T10:00:00.000001",
                        aggregate: "session/orch_257",
                        data: "{'execution_id': 'exec_257'}"
                    ),
                ]
            ),
            type: .sessionStarted,
            offset: 256,
            limit: 256
        )
        require(secondPage.events.first?.id == "start-257", "pagination ordinal was not honored")

        var cappedStarts: [OuroborosCompactSessionIndexV0511.Event] = (0..<4_096).map { index in
            event(
                id: "cap-\(index)",
                type: .sessionStarted,
                timestamp: String(format: "2026-08-09T09:%02d:%02d.%06d", (index / 60) % 60, index % 60, index),
                aggregateType: "session",
                aggregateID: "orch_cap_\(index)",
                sessionID: "orch_cap_\(index)",
                executionID: "exec_cap_\(index)"
            )
        }
        require(build(cappedStarts).count == 4_096, "4096-session contract was truncated")
        cappedStarts.append(
            event(
                id: "cap-overflow",
                type: .sessionStarted,
                timestamp: "2026-08-09T08:00:00.000001",
                aggregateType: "session",
                aggregateID: "orch_cap_overflow",
                sessionID: "orch_cap_overflow",
                executionID: "exec_cap_overflow"
            )
        )
        requireBuildFailure(cappedStarts, .capacityExceeded, "4097-session overflow")

        requireDecodeFailure(
            response(
                type: .sessionStarted,
                offset: 0,
                limit: 256,
                records: [
                    record(
                        id: "truncated",
                        timestamp: "2026-08-10T10:00:00.000001",
                        aggregate: "session/orch_truncated",
                        data: "{'execution_id': 'an-identity-without-a-closing-quote..."
                    ),
                ]
            ),
            type: .sessionStarted,
            offset: 0,
            limit: 256,
            expected: .malformedText,
            context: "truncated Python repr identity"
        )

        var wrongMeta = response(type: .sessionStarted, offset: 0, limit: 256, records: [])
        var wrongResult = wrongMeta["result"] as! [String: Any]
        var meta = wrongResult["_meta"] as! [String: Any]
        meta["offset"] = 1
        wrongResult["_meta"] = meta
        wrongMeta["result"] = wrongResult
        requireDecodeFailure(
            wrongMeta,
            type: .sessionStarted,
            offset: 0,
            limit: 256,
            expected: .malformedToolResult,
            context: "mismatched MCP metadata"
        )

        requireBuildFailure(
            [startPage.events[0], startPage.events[0]],
            .duplicateEvent,
            "repeated pagination event"
        )
        let conflictingTerminal = event(
            id: "terminal-conflict",
            type: .executionTerminal,
            timestamp: "2026-08-10T10:10:00.000001",
            aggregateType: "execution",
            aggregateID: "different_execution",
            sessionID: "orch_two",
            executionID: "different_execution",
            status: "failed"
        )
        requireBuildFailure(
            startPage.events + [conflictingTerminal],
            .conflictingIdentity,
            "terminal/start identity disagreement"
        )

        print("PASS: exact 0.51.6 plain-text lifecycle parser, 4096-row pagination, and fail-closed aggregation")
    }

    private static func decodeLiveSSE(eventTypeName: String, offsetText: String, limitText: String) {
        guard let eventType = OuroborosCompactSessionIndexV0511.EventType(rawValue: eventTypeName),
              let offset = Int(offsetText),
              let limit = Int(limitText),
              let raw = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8),
              let dataLine = raw.split(whereSeparator: { $0.isNewline }).first(where: { $0.hasPrefix("data:") }),
              let jsonData = dataLine.dropFirst(5).trimmingCharacters(in: .whitespaces).data(using: .utf8),
              let response = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            require(false, "live SSE envelope was unreadable")
            return
        }
        let page = decode(response, type: eventType, offset: offset, limit: limit)
        print("PASS: live Ouroboros 0.51.6 \(eventType.rawValue) page decoded \(page.events.count) events")
    }

    private static func response(
        type: OuroborosCompactSessionIndexV0511.EventType,
        offset: Int,
        limit: Int,
        records: [(id: String, timestamp: String, aggregate: String, data: String)]
    ) -> [String: Any] {
        var lines = [
            "Event Query Results",
            String(repeating: "=", count: 60),
            "Session: all",
            "Type filter: \(type.rawValue)",
            "Showing \(offset) to \(offset + records.count) (found \(records.count) events)",
            "",
        ]
        if records.isEmpty {
            lines.append("No events found matching the criteria.")
        } else {
            for (index, record) in records.enumerated() {
                lines.append(contentsOf: [
                    "\(offset + index + 1). [\(type.rawValue)]",
                    "   ID: \(record.id)",
                    "   Timestamp: \(record.timestamp)",
                    "   Aggregate: \(record.aggregate)",
                    "   Data: \(record.data)",
                    "",
                ])
            }
        }
        return [
            "jsonrpc": "2.0",
            "id": 1,
            "result": [
                "_meta": ["total_events": records.count, "offset": offset, "limit": limit],
                "content": [["text": lines.joined(separator: "\n"), "type": "text"]],
                "isError": false,
            ],
        ]
    }

    private static func record(
        id: String,
        timestamp: String,
        aggregate: String,
        data: String
    ) -> (id: String, timestamp: String, aggregate: String, data: String) {
        (id, timestamp, aggregate, data)
    }

    private static func event(
        id: String,
        type: OuroborosCompactSessionIndexV0511.EventType,
        timestamp: String,
        aggregateType: String,
        aggregateID: String,
        sessionID: String,
        executionID: String,
        status: String? = nil
    ) -> OuroborosCompactSessionIndexV0511.Event {
        OuroborosCompactSessionIndexV0511.Event(
            id: id,
            type: type,
            timestamp: timestamp,
            aggregateType: aggregateType,
            aggregateID: aggregateID,
            sessionID: sessionID,
            executionID: executionID,
            status: status,
            messagesProcessed: nil
        )
    }

    private static func decode(
        _ response: [String: Any],
        type: OuroborosCompactSessionIndexV0511.EventType,
        offset: Int,
        limit: Int
    ) -> OuroborosCompactSessionIndexV0511.Page {
        switch OuroborosCompactSessionIndexV0511.decodePage(
            response: response,
            eventType: type,
            offset: offset,
            limit: limit
        ) {
        case .success(let page): return page
        case .failure(let failure):
            require(false, "valid page failed as \(failure)")
            fatalError()
        }
    }

    private static func build(
        _ events: [OuroborosCompactSessionIndexV0511.Event]
    ) -> [OuroborosCompactSessionIndexV0511.Session] {
        switch OuroborosCompactSessionIndexV0511.build(events: events) {
        case .success(let sessions): return sessions
        case .failure(let failure):
            require(false, "valid event set failed as \(failure)")
            fatalError()
        }
    }

    private static func requireDecodeFailure(
        _ response: [String: Any],
        type: OuroborosCompactSessionIndexV0511.EventType,
        offset: Int,
        limit: Int,
        expected: OuroborosCompactSessionIndexV0511.Failure,
        context: String
    ) {
        let result = OuroborosCompactSessionIndexV0511.decodePage(
            response: response,
            eventType: type,
            offset: offset,
            limit: limit
        )
        guard case .failure(let actual) = result else {
            require(false, "\(context) did not fail closed")
            return
        }
        require(actual == expected, "\(context) failed as \(actual), expected \(expected)")
    }

    private static func requireBuildFailure(
        _ events: [OuroborosCompactSessionIndexV0511.Event],
        _ expected: OuroborosCompactSessionIndexV0511.Failure,
        _ context: String
    ) {
        guard case .failure(let actual) = OuroborosCompactSessionIndexV0511.build(events: events) else {
            require(false, "\(context) did not fail closed")
            return
        }
        require(actual == expected, "\(context) failed as \(actual), expected \(expected)")
    }
}
