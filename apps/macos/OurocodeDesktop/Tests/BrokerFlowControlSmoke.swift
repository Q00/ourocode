import Foundation

// Run from the package directory with:
// swiftc -O Sources/OurocodeDesktop/BrokerFlowControl.swift \
//   Tests/BrokerFlowControlSmoke.swift -o /tmp/ourocode-flow-smoke

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class ReleaseProbe {
    let onRelease: () -> Void

    init(onRelease: @escaping () -> Void) {
        self.onRelease = onRelease
    }

    deinit { onRelease() }
}

@main
enum BrokerFlowControlSmoke {
    static func main() {
        var writes = BoundedByteQueue(capacity: 8)
        require(writes.enqueue(Data([1, 2, 3, 4])), "first frame rejected")
        require(writes.enqueue(Data([5, 6, 7, 8])), "second frame rejected")
        require(!writes.enqueue(Data([9])), "write ceiling exceeded")
        writes.consume(3)
        require(writes.front?.offset == 3, "partial write offset lost")
        require(writes.enqueue(Data([9, 10, 11])), "released capacity not reused")
        writes.consume(8)
        require(writes.isEmpty, "write queue did not drain")

        let events = BoundedEventQueue<Int>(capacity: 10)
        require(events.enqueue(1, cost: 4), "first event rejected")
        require(events.enqueue(2, cost: 4), "second event rejected")
        require(!events.enqueue(3, cost: 4), "event mailbox exceeded its byte ceiling")
        require(events.take(maximumCount: 1, maximumBytes: 8) == [1], "event batch lost FIFO order")
        require(events.retainedBytes == 4, "event batch did not release retained bytes")
        require(events.enqueue(3, cost: 6), "event mailbox did not reuse released capacity")
        require(
            events.take(maximumCount: 8, maximumBytes: 4) == [2],
            "event batch ignored its byte ceiling"
        )
        require(events.take(maximumCount: 8, maximumBytes: 8) == [3], "event tail was lost")
        require(events.isEmpty && events.retainedBytes == 0, "event mailbox did not drain")

        let accounted = BoundedEventQueue<Int>(capacity: 32)
        require(accounted.enqueue(7, cost: 6), "accounted event rejected")
        require(accounted.enqueue(8, cost: 10), "second accounted event rejected")
        let accountedBatch = accounted.takeBatch(maximumCount: 2, maximumBytes: 32)
        require(accountedBatch.elements == [7, 8], "accounted batch lost FIFO order")
        require(accountedBatch.retainedBytes == 16, "accounted batch lost its retained-byte cost")

        let deliveryToken = BrokerDeliveryToken()
        require(deliveryToken.isValid, "fresh delivery token is invalid")
        deliveryToken.invalidate()
        require(!deliveryToken.isValid, "invalidated delivery token accepted stale work")

        var releasedPayloads = 0
        let releaseQueue = BoundedEventQueue<ReleaseProbe>(capacity: 16)
        do {
            var payload: ReleaseProbe? = ReleaseProbe { releasedPayloads += 1 }
            require(releaseQueue.enqueue(payload!, cost: 8), "release probe rejected")
            payload = nil
            let batch = releaseQueue.takeBatch(maximumCount: 1, maximumBytes: 16)
            require(batch.elements.count == 1, "release probe batch missing")
            require(releasedPayloads == 0, "delivery batch released its payload too early")
        }
        require(releasedPayloads == 1, "drained queue slot retained its payload after delivery")
        require(releaseQueue.retainedBytes == 0, "release probe accounting did not drain")

        var releasedHandoffPayloads = 0
        var handoff: OneShotHandoff<ReleaseProbe>? = OneShotHandoff([
            ReleaseProbe { releasedHandoffPayloads += 1 }
        ])
        handoff?.consume { payloads in
            require(payloads.count == 1, "one-shot handoff lost its payload")
            require(releasedHandoffPayloads == 0, "one-shot payload died during renderer handoff")
        }
        require(releasedHandoffPayloads == 1, "renderer handoff retained its consumed payload")
        var replayedHandoff = false
        handoff?.consume { _ in replayedHandoff = true }
        require(!replayedHandoff, "one-shot renderer handoff replayed consumed payload")
        handoff?.discard()
        handoff = nil

        var gap = TerminalOutputCoalescer(perTerminalCapacity: 8, totalCapacity: 16)
        gap.register(terminalID: "gap", lastCursor: 4)
        require(
            gap.append(terminalID: "gap", cursor: 6, data: Data([1])) == .recoveryRequired,
            "cursor gap was accepted"
        )
        require(gap.takeBatch(maximumBytes: 8).recoveryTerminalIDs == ["gap"], "gap did not request recovery")

        let terminals = (0..<32).map { "terminal-\($0)" }
        var cursors = Dictionary(uniqueKeysWithValues: terminals.map { ($0, UInt64(0)) })
        var output = TerminalOutputCoalescer(
            perTerminalCapacity: 16 * 1024,
            totalCapacity: 512 * 1024
        )
        terminals.forEach { output.register(terminalID: $0, lastCursor: 0) }

        for turn in 0..<100_000 {
            let terminalID = terminals[turn % terminals.count]
            let cursor = cursors[terminalID]! + 1
            cursors[terminalID] = cursor
            require(
                output.append(
                    terminalID: terminalID,
                    cursor: cursor,
                    data: Data(repeating: UInt8(turn & 0xff), count: 32)
                ) == .accepted,
                "ordered stress delta rejected at turn \(turn)"
            )
            require(output.retainedBytes <= output.totalCapacity, "global output ceiling exceeded")
            if turn % 128 == 127 {
                while output.hasReady {
                    let batch = output.takeBatch(maximumBytes: 64 * 1024)
                    require(batch.recoveryTerminalIDs.isEmpty, "stress stream requested recovery")
                }
            }
        }
        while output.hasReady { _ = output.takeBatch(maximumBytes: 64 * 1024) }
        require(output.retainedBytes == 0, "stress output did not drain")
        print("PASS: bounded writes/events, gap recovery, 32-terminal/100000-delta fanout")
    }
}
