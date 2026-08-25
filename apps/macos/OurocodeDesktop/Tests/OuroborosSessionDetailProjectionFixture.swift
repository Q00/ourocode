import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func timestamp(_ index: Int) -> String {
    String(format: "2026-08-10T12:%02d:%02d.000000", (index / 60) % 60, index % 60)
}

private func eventText(
    sessionID: String,
    eventType: OuroborosSessionDetailProjectionV0511.EventType,
    count: Int,
    idPrefix: String? = nil
) -> String {
    var lines = [
        "Event Query Results",
        String(repeating: "=", count: 60),
        "Session: \(sessionID)",
        "Type filter: \(eventType.rawValue)",
        "Showing 0 to \(count) (found \(count) events)",
        "",
    ]
    if count == 0 {
        lines.append("No events found matching the criteria.")
        return lines.joined(separator: "\n")
    }
    for index in 0..<count {
        lines.append(contentsOf: [
            "\(index + 1). [\(eventType.rawValue)]",
            "   ID: \(idPrefix ?? eventType.rawValue)-event-\(index)",
            "   Timestamp: \(timestamp(count - index))",
            "   Aggregate: execution/exec-scope-\(index)",
            "   Data: {'status': 'completed', 'ordinal': \(index)}",
            "",
        ])
    }
    return lines.joined(separator: "\n")
}

private func response(
    sessionID: String,
    eventType: OuroborosSessionDetailProjectionV0511.EventType,
    count: Int,
    idPrefix: String? = nil,
    offset: Int = 0,
    limit: Int = OuroborosSessionDetailProjectionV0511.requestLimit,
    attemptFilter: OuroborosSessionDetailProjectionV0511.AttemptFilter? = nil,
    textOverride: String? = nil
) -> [String: Any] {
    var metadata: [String: Any] = ["offset": offset, "limit": limit, "total_events": count]
    if let attemptFilter {
        metadata["execution_id"] = attemptFilter.executionID
        metadata["session_scope_id"] = attemptFilter.scopeID
        metadata["session_attempt_id"] = attemptFilter.attemptID
    }
    return [
        "result": [
            "isError": false,
            "_meta": metadata,
            "content": [[
                "type": "text",
                "text": textOverride ?? eventText(
                    sessionID: sessionID,
                    eventType: eventType,
                    count: count,
                    idPrefix: idPrefix
                ),
            ]],
        ] as [String: Any],
    ]
}

private func page(
    sessionID: String,
    eventType: OuroborosSessionDetailProjectionV0511.EventType,
    count: Int,
    idPrefix: String? = nil,
    attemptFilter: OuroborosSessionDetailProjectionV0511.AttemptFilter? = nil
) -> OuroborosSessionDetailProjectionV0511.Page {
    let decoded = OuroborosSessionDetailProjectionV0511.decodePage(
        response: response(
            sessionID: sessionID,
            eventType: eventType,
            count: count,
            idPrefix: idPrefix,
            attemptFilter: attemptFilter
        ),
        sessionID: sessionID,
        eventType: eventType,
        attemptFilter: attemptFilter
    )
    guard case .success(let value) = decoded else { fatalError("fixture page did not decode") }
    return value
}

@main
enum OuroborosSessionDetailProjectionFixture {
    static func main() {
        let sessionID = "orch_session_123"
        let executionID = "exec_123"
        let attemptFilter = OuroborosSessionDetailProjectionV0511.attemptFilter(
            executionID: executionID,
            scopeID: "scope_agent_1",
            attemptID: "attempt_agent_1"
        )!
        let eventTypes = OuroborosSessionDetailProjectionV0511.EventType.allCases

        require(
            OuroborosSessionDetailProjectionV0511.toolArguments(
                sessionID: sessionID,
                eventType: .sessionStarted
            )?["limit"] as? Int == 24,
            "typed detail page bound changed"
        )
        require(
            OuroborosSessionDetailProjectionV0511.toolArguments(
                sessionID: "bad session",
                eventType: .sessionStarted
            ) == nil,
            "whitespace session identity was accepted"
        )
        let exactArguments = OuroborosSessionDetailProjectionV0511.toolArguments(
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )!
        require(exactArguments["execution_id"] as? String == executionID, "exact execution filter missing")
        require(exactArguments["session_scope_id"] as? String == "scope_agent_1", "exact scope filter missing")
        require(exactArguments["session_attempt_id"] as? String == "attempt_agent_1", "exact attempt filter missing")

        let exactPage = OuroborosSessionDetailProjectionV0511.decodePage(
            response: response(
                sessionID: sessionID,
                eventType: .attemptDispatched,
                count: 1,
                attemptFilter: attemptFilter
            ),
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )
        require(exactPage.isSuccess, "exact attempt page did not decode")
        var forgedSiblingResponse = response(
            sessionID: sessionID,
            eventType: .attemptDispatched,
            count: 1,
            attemptFilter: attemptFilter
        )
        var forgedResult = forgedSiblingResponse["result"] as! [String: Any]
        var forgedMeta = forgedResult["_meta"] as! [String: Any]
        forgedMeta["session_attempt_id"] = "attempt_agent_2"
        forgedResult["_meta"] = forgedMeta
        forgedSiblingResponse["result"] = forgedResult
        let forgedSiblingPage = OuroborosSessionDetailProjectionV0511.decodePage(
            response: forgedSiblingResponse,
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )
        require(
            forgedSiblingPage == .failure(.mismatchedPage),
            "forged sibling attempt identity was admitted"
        )
        let missingExactMeta = response(
            sessionID: sessionID,
            eventType: .attemptDispatched,
            count: 1
        )
        let missingMetaPage = OuroborosSessionDetailProjectionV0511.decodePage(
            response: missingExactMeta,
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )
        require(missingMetaPage == .failure(.exactAttemptUnavailable), "session-wide fallback leaked into exact attempt")
        var wrongAttemptMeta = response(
            sessionID: sessionID,
            eventType: .attemptDispatched,
            count: 1,
            attemptFilter: attemptFilter
        )
        var wrongAttemptResult = wrongAttemptMeta["result"] as! [String: Any]
        var wrongAttemptMetadata = wrongAttemptResult["_meta"] as! [String: Any]
        wrongAttemptMetadata["session_attempt_id"] = "attempt_agent_2"
        wrongAttemptResult["_meta"] = wrongAttemptMetadata
        wrongAttemptMeta["result"] = wrongAttemptResult
        let wrongAttemptPage = OuroborosSessionDetailProjectionV0511.decodePage(
            response: wrongAttemptMeta,
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )
        require(wrongAttemptPage == .failure(.mismatchedPage), "wrong exact attempt metadata was accepted")
        let unsupportedExactPage = OuroborosSessionDetailProjectionV0511.decodePage(
            response: [
                "error": [
                    "code": -32602,
                    "message": "Unknown exact-attempt arguments",
                ],
            ],
            sessionID: sessionID,
            eventType: .attemptDispatched,
            attemptFilter: attemptFilter
        )
        require(
            unsupportedExactPage == .failure(.exactAttemptUnavailable),
            "unsupported exact-attempt query did not produce an honest capability error"
        )
        let exactPages = eventTypes.map {
            page(
                sessionID: sessionID,
                eventType: $0,
                count: 0,
                attemptFilter: attemptFilter
            )
        }
        let exactSnapshot = OuroborosSessionDetailProjectionV0511.build(
            pages: exactPages,
            sessionID: sessionID,
            executionID: executionID,
            attemptFilter: attemptFilter
        )
        guard case .success(let exactValue) = exactSnapshot else {
            fatalError("exact attempt snapshot did not build")
        }
        require(exactValue.attemptFilter == attemptFilter, "exact snapshot dropped attempt identity")
        require(exactValue.runProjection == nil, "exact attempt snapshot inherited group run projection")

        for count in [0, 1, 24] {
            let decoded = page(
                sessionID: sessionID,
                eventType: .attemptDispatched,
                count: count
            )
            require(decoded.events.count == count, "typed page event count changed")
            require(decoded.mayHaveOlderEvents == (count == 24), "full-page history hint changed")
        }

        let emptyPages = eventTypes.map { page(sessionID: sessionID, eventType: $0, count: 0) }
        let empty = OuroborosSessionDetailProjectionV0511.build(
            pages: emptyPages,
            sessionID: sessionID,
            executionID: executionID
        )
        guard case .success(let emptySnapshot) = empty else { fatalError("empty merge failed") }
        require(emptySnapshot.events.isEmpty && !emptySnapshot.moreAvailable, "empty detail changed")

        let counts = [11, 11, 11, 11, 11, 10]
        let densePages = zip(eventTypes, counts).map { type, count in
            page(sessionID: sessionID, eventType: type, count: count)
        }
        let dense = OuroborosSessionDetailProjectionV0511.build(
            pages: densePages,
            sessionID: sessionID,
            executionID: executionID
        )
        guard case .success(let denseSnapshot) = dense else { fatalError("dense merge failed") }
        require(denseSnapshot.events.count == 64, "merged visible event bound changed")
        require(denseSnapshot.moreAvailable, "65th merged event did not advertise more history")

        var duplicatePages = emptyPages
        duplicatePages[0] = page(
            sessionID: sessionID,
            eventType: eventTypes[0],
            count: 1,
            idPrefix: "duplicate"
        )
        duplicatePages[1] = page(
            sessionID: sessionID,
            eventType: eventTypes[1],
            count: 1,
            idPrefix: "duplicate"
        )
        let duplicate = OuroborosSessionDetailProjectionV0511.build(
            pages: duplicatePages,
            sessionID: sessionID,
            executionID: executionID
        )
        require(duplicate == .failure(.duplicateEvent), "cross-page duplicate identity was accepted")

        let wrongMetadata = OuroborosSessionDetailProjectionV0511.decodePage(
            response: response(
                sessionID: sessionID,
                eventType: .sessionStarted,
                count: 1,
                offset: 1
            ),
            sessionID: sessionID,
            eventType: .sessionStarted
        )
        require(wrongMetadata == .failure(.malformedToolResult), "wrong page metadata was accepted")

        let malformed = OuroborosSessionDetailProjectionV0511.decodePage(
            response: response(
                sessionID: sessionID,
                eventType: .sessionStarted,
                count: 1,
                textOverride: "changed format"
            ),
            sessionID: sessionID,
            eventType: .sessionStarted
        )
        require(malformed == .failure(.malformedText), "format drift was accepted")

        let oversizedText = eventText(
            sessionID: sessionID,
            eventType: .sessionStarted,
            count: 1
        ) + String(repeating: "x", count: OuroborosSessionDetailProjectionV0511.maximumResponseTextBytes)
        let oversized = OuroborosSessionDetailProjectionV0511.decodePage(
            response: response(
                sessionID: sessionID,
                eventType: .sessionStarted,
                count: 1,
                textOverride: oversizedText
            ),
            sessionID: sessionID,
            eventType: .sessionStarted
        )
        require(oversized == .failure(.responseTooLarge), "oversized detail response was accepted")

        print("PASS: exact identity echo, forged sibling rejection, six typed pages, 64-event merge, drift, duplicate, and 128 KiB bounds")
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
