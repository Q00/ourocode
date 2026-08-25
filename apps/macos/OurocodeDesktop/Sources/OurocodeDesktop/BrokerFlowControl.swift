import Foundation

/// A FIFO of framed writes with an exact retained-byte ceiling. The socket
/// transport owns the syscall policy; this value only makes memory and partial
/// write behavior deterministic and testable.
struct BoundedByteQueue {
    private struct Entry {
        let data: Data
        var offset: Int
    }

    let capacity: Int
    private var entries: [Entry] = []
    private var head = 0
    private(set) var retainedBytes = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var isEmpty: Bool { retainedBytes == 0 }

    var front: (data: Data, offset: Int)? {
        guard head < entries.count else { return nil }
        let entry = entries[head]
        return (entry.data, entry.offset)
    }

    mutating func enqueue(_ data: Data) -> Bool {
        guard !data.isEmpty else { return true }
        guard data.count <= capacity - retainedBytes else { return false }
        entries.append(Entry(data: data, offset: 0))
        retainedBytes += data.count
        return true
    }

    mutating func consume(_ count: Int) {
        precondition(count >= 0 && count <= retainedBytes)
        var remaining = count
        while remaining > 0, head < entries.count {
            let available = entries[head].data.count - entries[head].offset
            let consumed = min(available, remaining)
            entries[head].offset += consumed
            retainedBytes -= consumed
            remaining -= consumed
            if entries[head].offset == entries[head].data.count { head += 1 }
        }
        compactIfNeeded()
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        retainedBytes = 0
    }

    private mutating func compactIfNeeded() {
        guard head > 64, head * 2 >= entries.count else { return }
        entries.removeFirst(head)
        head = 0
    }
}

/// A bounded FIFO used to cross a hot I/O queue into a slower consumer queue.
/// Costs are explicit so callers can account payload bytes plus fixed event
/// overhead without making this container aware of terminal protocol types.
final class BoundedEventQueue<Element> {
    struct Batch {
        let elements: [Element]
        let retainedBytes: Int
    }

    private struct Entry {
        let element: Element
        let cost: Int
    }

    let capacity: Int
    private var entries: [Entry?] = []
    private var head = 0
    private(set) var retainedBytes = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    var isEmpty: Bool { head >= entries.count }

    func enqueue(_ element: Element, cost: Int) -> Bool {
        guard cost > 0, cost <= capacity - retainedBytes else { return false }
        entries.append(Entry(element: element, cost: cost))
        retainedBytes += cost
        return true
    }

    func take(maximumCount: Int, maximumBytes: Int) -> [Element] {
        takeBatch(maximumCount: maximumCount, maximumBytes: maximumBytes).elements
    }

    func takeBatch(maximumCount: Int, maximumBytes: Int) -> Batch {
        precondition(maximumCount > 0 && maximumBytes > 0)
        var result: [Element] = []
        var selectedBytes = 0
        while head < entries.count, result.count < maximumCount {
            guard let entry = entries[head] else {
                preconditionFailure("Consumed event queue slot was revisited")
            }
            if !result.isEmpty, selectedBytes + entry.cost > maximumBytes { break }
            result.append(entry.element)
            selectedBytes += entry.cost
            retainedBytes -= entry.cost
            // Release payload ownership immediately. Advancing only `head`
            // makes logical accounting lie while large Data buffers remain
            // retained until a later compaction threshold.
            entries[head] = nil
            head += 1
        }
        compactIfNeeded()
        return Batch(elements: result, retainedBytes: selectedBytes)
    }

    func removeAll(keepingCapacity: Bool = true) {
        entries.removeAll(keepingCapacity: keepingCapacity)
        head = 0
        retainedBytes = 0
    }

    private func compactIfNeeded() {
        guard head > 64, head * 2 >= entries.count else { return }
        entries.removeFirst(head)
        head = 0
    }
}

/// A one-shot ownership handoff for data that must remain alive only while a
/// synchronous consumer imports it. Copies of the surrounding authority may
/// share this box safely: the first consumer takes the elements, and a final
/// `discard` after the callback guarantees that an ignored handoff cannot pin
/// payload memory for the lifetime of that authority.
final class OneShotHandoff<Element> {
    private let lock = NSLock()
    private var elements: [Element]?

    init(_ elements: [Element]) {
        self.elements = elements
    }

    var isConsumed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return elements == nil
    }

    @discardableResult
    func consume<Result>(_ body: ([Element]) throws -> Result) rethrows -> Result? {
        let batch: [Element]?
        lock.lock()
        batch = elements
        elements = nil
        lock.unlock()
        guard let batch else { return nil }
        return try body(batch)
    }

    func discard() {
        lock.lock()
        elements = nil
        lock.unlock()
    }
}

/// A delivery generation that can be invalidated by the io queue while a
/// bounded batch is waiting on the main queue. The lock is intentionally tiny:
/// it only protects the stale-batch check and never surrounds rendering.
final class BrokerDeliveryToken {
    private let lock = NSLock()
    private var valid = true

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return valid
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

struct BrokerOutputBatch {
    struct Output {
        let terminalID: String
        let cursor: UInt64
        let data: Data
    }

    var outputs: [Output] = []
    var recoveryTerminalIDs: [String] = []
    var isEmpty: Bool { outputs.isEmpty && recoveryTerminalIDs.isEmpty }
}

/// Coalesces contiguous broker deltas without erasing their final cursor. A
/// cursor discontinuity or memory-pressure drop is converted into an explicit
/// snapshot recovery request instead of rendering a corrupt terminal stream.
struct TerminalOutputCoalescer {
    enum AppendResult: Equatable {
        case accepted
        case duplicate
        case ignored
        case recoveryRequired
    }

    private struct State {
        var lastAcceptedCursor: UInt64
        var data = Data()
        var recoveryRequired = false
    }

    let perTerminalCapacity: Int
    let totalCapacity: Int
    private var states: [String: State] = [:]
    private var ready: [String] = []
    private var readyHead = 0
    private var readySet: Set<String> = []
    private(set) var retainedBytes = 0

    init(perTerminalCapacity: Int, totalCapacity: Int) {
        precondition(perTerminalCapacity > 0 && totalCapacity >= perTerminalCapacity)
        self.perTerminalCapacity = perTerminalCapacity
        self.totalCapacity = totalCapacity
    }

    var hasReady: Bool { !readySet.isEmpty }

    mutating func register(terminalID: String, lastCursor: UInt64) {
        remove(terminalID: terminalID)
        states[terminalID] = State(lastAcceptedCursor: lastCursor)
    }

    mutating func remove(terminalID: String) {
        if let state = states.removeValue(forKey: terminalID) {
            retainedBytes -= state.data.count
        }
        readySet.remove(terminalID)
    }

    mutating func removeAll(keepingCapacity: Bool = true) {
        states.removeAll(keepingCapacity: keepingCapacity)
        ready.removeAll(keepingCapacity: keepingCapacity)
        readyHead = 0
        readySet.removeAll(keepingCapacity: keepingCapacity)
        retainedBytes = 0
    }

    mutating func append(terminalID: String, cursor: UInt64, data: Data) -> AppendResult {
        guard var state = states[terminalID], !state.recoveryRequired else { return .ignored }
        guard cursor > state.lastAcceptedCursor else { return .duplicate }
        guard state.lastAcceptedCursor < UInt64.max,
              cursor == state.lastAcceptedCursor + 1 else {
            markRecovery(terminalID: terminalID, state: &state)
            return .recoveryRequired
        }
        guard data.count <= perTerminalCapacity - state.data.count,
              data.count <= totalCapacity - retainedBytes else {
            markRecovery(terminalID: terminalID, state: &state)
            return .recoveryRequired
        }

        state.lastAcceptedCursor = cursor
        state.data.append(data)
        retainedBytes += data.count
        states[terminalID] = state
        enqueueReady(terminalID)
        return .accepted
    }

    mutating func takeBatch(maximumBytes: Int) -> BrokerOutputBatch {
        precondition(maximumBytes > 0)
        var batch = BrokerOutputBatch()
        var selectedBytes = 0

        while let terminalID = popReady() {
            guard var state = states[terminalID] else { continue }
            if state.recoveryRequired {
                batch.recoveryTerminalIDs.append(terminalID)
                continue
            }
            guard !state.data.isEmpty else { continue }
            if selectedBytes > 0 && selectedBytes + state.data.count > maximumBytes {
                enqueueReady(terminalID)
                break
            }
            let output = BrokerOutputBatch.Output(
                terminalID: terminalID,
                cursor: state.lastAcceptedCursor,
                data: state.data
            )
            selectedBytes += state.data.count
            retainedBytes -= state.data.count
            state.data.removeAll(keepingCapacity: true)
            states[terminalID] = state
            batch.outputs.append(output)
        }
        compactReadyIfNeeded()
        return batch
    }

    private mutating func markRecovery(terminalID: String, state: inout State) {
        retainedBytes -= state.data.count
        state.data.removeAll(keepingCapacity: true)
        state.recoveryRequired = true
        states[terminalID] = state
        enqueueReady(terminalID)
    }

    private mutating func enqueueReady(_ terminalID: String) {
        guard readySet.insert(terminalID).inserted else { return }
        ready.append(terminalID)
    }

    private mutating func popReady() -> String? {
        while readyHead < ready.count {
            let terminalID = ready[readyHead]
            readyHead += 1
            if readySet.remove(terminalID) != nil { return terminalID }
        }
        return nil
    }

    private mutating func compactReadyIfNeeded() {
        guard readyHead > 64, readyHead * 2 >= ready.count else { return }
        ready.removeFirst(readyHead)
        readyHead = 0
    }
}
