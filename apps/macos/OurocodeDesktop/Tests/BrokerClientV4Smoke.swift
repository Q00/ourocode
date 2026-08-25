import CryptoKit
import Darwin
import Foundation

// Standalone protocol smoke. Run from apps/macos/OurocodeDesktop:
// swiftc -O Sources/OurocodeDesktop/NormalizedTerminalInput.swift \
//   Sources/OurocodeDesktop/BrokerClient.swift \
//   Tests/BrokerClientV4Smoke.swift -o /tmp/ourocode-broker-v4-smoke && \
//   /tmp/ourocode-broker-v4-smoke

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func runMain(until predicate: () -> Bool, timeout: TimeInterval = 2) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return predicate()
}

private let manifest: [String: Any] = [
    "protocol_version": 4,
    "terminal_abi_version": 1,
    "engine_source_commit": "fixture:vt100-0.15.2",
    "snapshot_magic": "OUROCODE-ANSI-REPLAY",
    "snapshot_format_version": 1,
    "unicode_width_policy": "unicode-width:fixture",
    "graphics_policy": "disabled",
    "max_snapshot_bytes": 16_777_216,
    "max_terminal_history_bytes": 8_388_608,
    "max_global_history_bytes": 134_217_728,
    "max_delta_bytes": 524_288,
    "max_recovery_pinned_bytes": 16_777_216,
    "max_chunk_bytes": 65_536,
    "compression": "none"
]

private func checkpointDigest(_ checkpoint: Data) -> String {
    func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
    func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendInteger(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }
    var input = Data("ourocode-broker-v4-checkpoint\0".utf8)
    appendInteger(UInt16(4), to: &input)
    appendInteger(UInt32(1), to: &input)
    appendString("fixture:vt100-0.15.2", to: &input)
    appendString("OUROCODE-ANSI-REPLAY", to: &input)
    appendInteger(UInt32(1), to: &input)
    appendString("unicode-width:fixture", to: &input)
    appendString("disabled", to: &input)
    appendInteger(UInt64(16_777_216), to: &input)
    appendInteger(UInt64(8_388_608), to: &input)
    appendInteger(UInt64(134_217_728), to: &input)
    appendInteger(UInt64(524_288), to: &input)
    appendInteger(UInt64(16_777_216), to: &input)
    appendInteger(UInt32(65_536), to: &input)
    appendString("none", to: &input)
    appendInteger(UInt64(checkpoint.count), to: &input)
    input.append(checkpoint)
    return "sha256:" + SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private let terminal: [String: Any] = [
    "id": "term-1",
    "create_nonce": "smoke",
    "cursor": 0,
    "columns": 80,
    "rows": 24,
    "running": true,
    "foreground_process": false
]

private final class FakeBroker {
    let socketURL: URL
    private let listener: Int32
    private let queue = DispatchQueue(label: "fake-broker-v4")
    private let lock = NSLock()
    private var storedFailure: String?

    var failure: String? {
        lock.lock()
        defer { lock.unlock() }
        return storedFailure
    }

    init(script: @escaping (Int32) throws -> Void) throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ocv4-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketURL = directory.appendingPathComponent("broker-v4.sock")
        listener = try Self.bind(path: socketURL.path)
        queue.async { [weak self] in
            guard let self else { return }
            let client = Darwin.accept(self.listener, nil, nil)
            guard client >= 0 else {
                self.record("accept failed: \(String(cString: strerror(errno)))")
                return
            }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            defer { Darwin.close(client) }
            do {
                try script(client)
            } catch {
                self.record(error.localizedDescription)
            }
        }
    }

    deinit {
        Darwin.close(listener)
        try? FileManager.default.removeItem(at: socketURL.deletingLastPathComponent())
    }

    private func record(_ value: String) {
        lock.lock()
        storedFailure = value
        lock.unlock()
    }

    private static func bind(path: String) throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        var address = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withCString { source in memcpy(destination, source, bytes.count) }
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return fd
    }
}

private enum Wire {
    static func send(_ object: [String: Any], to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0a)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            guard count > 0 else { throw POSIXError(.EPIPE) }
            offset += count
        }
    }

    static func read(from fd: Int32) throws -> [String: Any] {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while true {
            let count = Darwin.read(fd, &byte, 1)
            guard count == 1 else { throw POSIXError(.ECONNRESET) }
            if byte == 0x0a { break }
            bytes.append(byte)
        }
        guard let value = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            throw POSIXError(.EBADMSG)
        }
        return value
    }

    static func hello(
        manifest override: [String: Any] = manifest,
        generation: UInt64 = 7
    ) -> [String: Any] {
        [
            "version": 4,
            "broker_generation": generation,
            "type": "hello",
            "pid": getpid(),
            "build": "smoke",
            "capabilities": [
                "terminal.state.ordered.v4",
                "terminal.recovery.two_phase.v4",
                "terminal.detach.lease.v4"
            ],
            "manifest": override
        ]
    }

    static func recoveryBegin(
        id: UInt64,
        checkpoint: Data,
        digest: String,
        terminal terminalValue: [String: Any] = terminal,
        recoveryID: String = "recovery-1"
    ) -> [String: Any] {
        [
            "version": 4,
            "broker_generation": 7,
            "type": "reply",
            "id": id,
            "result": "recovery_begin",
            "terminal": terminalValue,
            "recovery_id": recoveryID,
            "cutover_state_seq": 0,
            "total_bytes": checkpoint.count,
            "chunk_count": checkpoint.isEmpty ? 0 : 1,
            "digest": digest,
            "manifest": manifest
        ]
    }
}

private func terminalSummary(id: String) -> [String: Any] {
    [
        "id": id,
        "create_nonce": "smoke-\(id)",
        "cursor": 0,
        "columns": 80,
        "rows": 24,
        "running": true,
        "foreground_process": false
    ]
}

private func attachOnServer(
    _ fd: Int32,
    checkpoint: Data = Data(),
    readySequence: UInt64 = 0,
    leaseID: String = "lease-detach"
) throws {
    let digest = checkpointDigest(checkpoint)
    let prepare = try Wire.read(from: fd)
    guard prepare["op"] as? String == "attach_prepare" else { throw POSIXError(.EBADMSG) }
    try Wire.send(
        Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest),
        to: fd
    )
    if !checkpoint.isEmpty {
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0,
            "data": checkpoint.base64EncodedString()
        ], to: fd)
    }
    try Wire.send([
        "version": 4, "broker_generation": 7, "type": "recovery_end",
        "recovery_id": "recovery-1", "digest": digest
    ], to: fd)
    let commit = try Wire.read(from: fd)
    guard commit["op"] as? String == "recovery_commit" else { throw POSIXError(.EBADMSG) }
    try Wire.send([
        "version": 4, "broker_generation": 7, "type": "reply",
        "id": requestID(commit), "result": "attached_ready", "terminal": terminal,
        "state_seq": readySequence, "input_epoch": 11, "lease_id": leaseID
    ], to: fd)
}

private func fullWidthUnsignedGenerationIsAccepted() throws {
    let generation = UInt64.max - 17
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(generation: generation), to: fd)
        usleep(100_000)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var hello: BrokerHello?
    client.start { hello = try? $0.get() }
    require(runMain(until: { hello != nil }), "full-width u64 generation was rejected")
    require(hello?.generation == generation, "full-width u64 generation changed during JSON decoding")
    require(server.failure == nil, server.failure ?? "u64 generation fake broker failed")
    client.stop()
}

private func requestID(_ object: [String: Any]) -> UInt64 {
    (object["id"] as! NSNumber).uint64Value
}

private func happyPath() throws {
    let checkpoint = Data("checkpoint ".utf8)
    let digest = checkpointDigest(checkpoint)
    let allowLiveOutput = DispatchSemaphore(value: 0)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        guard prepare["op"] as? String == "attach_prepare" else { throw POSIXError(.EBADMSG) }
        let prepareID = requestID(prepare)
        // Simulate output already queued before the broker's recovery_begin
        // reply. Pending state starts when the request is sent, so this must
        // not become a connection-wide protocol failure.
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "state_event", "terminal_id": "term-1",
            "event": ["event": "pty_bytes", "state_seq": 99, "data": Data("late-old".utf8).base64EncodedString()]
        ], to: fd)
        try Wire.send(Wire.recoveryBegin(id: prepareID, checkpoint: checkpoint, digest: digest), to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0,
            "data": checkpoint.base64EncodedString()
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_end",
            "recovery_id": "recovery-1", "digest": digest
        ], to: fd)

        let commit = try Wire.read(from: fd)
        guard commit["op"] as? String == "recovery_commit" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_delta",
            "recovery_id": "recovery-1",
            "event": ["event": "pty_bytes", "state_seq": 1, "data": Data("catchup".utf8).base64EncodedString()]
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_delta",
            "recovery_id": "recovery-1",
            "event": [
                "event": "resize", "state_seq": 2, "columns": 100, "rows": 30,
                "cell_width_px": 9, "cell_height_px": 18, "layout_epoch": 4
            ]
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(commit), "result": "attached_ready", "terminal": terminal,
            "state_seq": 2, "input_epoch": 9, "lease_id": "lease-9"
        ], to: fd)
        guard allowLiveOutput.wait(timeout: .now() + 5) == .success else {
            throw POSIXError(.ETIMEDOUT)
        }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "state_event", "terminal_id": "term-1",
            "event": ["event": "pty_bytes", "state_seq": 3, "data": Data("live".utf8).base64EncodedString()]
        ], to: fd)

        let input = try Wire.read(from: fd)
        guard input["op"] as? String == "input",
              (input["input_epoch"] as? NSNumber)?.uint64Value == 9,
              input["lease_id"] as? String == "lease-9" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(input), "result": "accepted"
        ], to: fd)

        let resize = try Wire.read(from: fd)
        guard resize["op"] as? String == "resize",
              (resize["layout_epoch"] as? NSNumber)?.uint64Value == 5 else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(resize), "result": "accepted"
        ], to: fd)

        // A gap must invalidate the attachment without applying the payload.
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "state_event", "terminal_id": "term-1",
            "event": ["event": "pty_bytes", "state_seq": 5, "data": Data("gap".utf8).base64EncodedString()]
        ], to: fd)
        usleep(100_000)
    }

    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared: BrokerPreparedRecovery?
    var attachment: BrokerAttachment?
    var catchUpSequences: [UInt64] = []
    var streamed: [BrokerStateEvent] = []
    var resync = false
    var inputAccepted = false
    var resizeAccepted = false
    client.onResyncRequired = { terminalID, _ in
        require(terminalID == "term-1", "resync targeted wrong terminal")
        resync = true
    }
    client.start { result in
        if case .success = result { connected = true }
    }
    require(runMain(until: { connected }), "v4 hello did not connect")
    client.prepareAttachment(terminalID: "term-1") { result in
        prepared = try? result.get()
    }
    require(runMain(until: { prepared != nil }), "verified recovery was not prepared")
    require(prepared?.checkpoint == checkpoint, "checkpoint bytes changed")
    client.commitAttachment(prepared!, onEvent: { streamed.append($0) }) { result in
        attachment = try? result.get()
        attachment?.consumeCatchUpEvents { events in
            catchUpSequences = events.map(\.sequence)
        }
    }
    require(runMain(until: { attachment != nil }), "attached_ready was not delivered")
    require(catchUpSequences == [1, 2], "catch-up output/resize ordering changed")
    var replayedCatchUp = false
    attachment?.consumeCatchUpEvents { _ in replayedCatchUp = true }
    require(!replayedCatchUp, "catch-up payload remained available after its one-shot handoff")
    var handoffSnapshot: BrokerFlowControlSnapshot?
    client.flowControlSnapshot { handoffSnapshot = $0 }
    require(runMain(until: { handoffSnapshot != nil }), "flow-control ledger snapshot was not delivered")
    require(
        handoffSnapshot?.retainedEventBytes == 0,
        "catch-up bytes remained charged after the renderer handoff"
    )
    allowLiveOutput.signal()
    require(runMain(until: { streamed.map(\.sequence) == [3] }), "ordered live output missing")
    client.input(Data("x".utf8), using: attachment!) { result in inputAccepted = (try? result.get()) != nil }
    client.resize(
        columns: 101, rows: 31, cellWidthPixels: 9, cellHeightPixels: 18,
        layoutEpoch: 5, using: attachment!
    ) { result in resizeAccepted = (try? result.get()) != nil }
    require(runMain(until: { inputAccepted && resizeAccepted }), "lease-bound mutation was not accepted")
    require(runMain(until: { resync }), "live sequence gap did not request resync")
    require(streamed.map(\.sequence) == [3], "gap payload reached renderer")
    require(server.failure == nil, server.failure ?? "fake broker failed")
    client.stop()
}

private func globalMailboxOverflowIsIsolatedAndRequestsOneResync() throws {
    let terminalIDs = (0..<11).map { "global-terminal-\($0)" }
    let burstSent = DispatchSemaphore(value: 0)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        for (index, terminalID) in terminalIDs.enumerated() {
            let summary = terminalSummary(id: terminalID)
            let recoveryID = "global-recovery-\(index)"
            let checkpoint = Data()
            let digest = checkpointDigest(checkpoint)
            let prepare = try Wire.read(from: fd)
            guard prepare["op"] as? String == "attach_prepare",
                  prepare["terminal_id"] as? String == terminalID else {
                throw POSIXError(.EBADMSG)
            }
            try Wire.send(
                Wire.recoveryBegin(
                    id: requestID(prepare),
                    checkpoint: checkpoint,
                    digest: digest,
                    terminal: summary,
                    recoveryID: recoveryID
                ),
                to: fd
            )
            try Wire.send([
                "version": 4, "broker_generation": 7, "type": "recovery_end",
                "recovery_id": recoveryID, "digest": digest
            ], to: fd)
            let commit = try Wire.read(from: fd)
            guard commit["op"] as? String == "recovery_commit" else {
                throw POSIXError(.EBADMSG)
            }
            try Wire.send([
                "version": 4, "broker_generation": 7, "type": "reply",
                "id": requestID(commit), "result": "attached_ready", "terminal": summary,
                "state_seq": 0, "input_epoch": UInt64(index + 1),
                "lease_id": "global-lease-\(index)"
            ], to: fd)
        }

        let payload = Data(repeating: 0x78, count: 64 * 1_024).base64EncodedString()
        for terminalID in terminalIDs {
            for sequence in 1...3 {
                try Wire.send([
                    "version": 4, "broker_generation": 7, "type": "state_event",
                    "terminal_id": terminalID,
                    "event": [
                        "event": "pty_bytes", "state_seq": sequence, "data": payload
                    ]
                ], to: fd)
            }
        }
        burstSent.signal()
        usleep(500_000)
    }

    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var attachments: [String: BrokerAttachment] = [:]
    var delivered: [String: [UInt64]] = [:]
    var resyncTerminalIDs: [String] = []
    client.onResyncRequired = { terminalID, _ in
        resyncTerminalIDs.append(terminalID)
    }
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "global-mailbox scenario did not connect")

    for terminalID in terminalIDs {
        var prepared: BrokerPreparedRecovery?
        client.prepareAttachment(terminalID: terminalID) { prepared = try? $0.get() }
        require(runMain(until: { prepared != nil }), "global-mailbox recovery was not prepared")
        client.commitAttachment(
            prepared!,
            onEvent: { delivered[terminalID, default: []].append($0.sequence) }
        ) { result in
            attachments[terminalID] = try? result.get()
        }
        require(
            runMain(until: { attachments[terminalID] != nil }),
            "global-mailbox attachment was not committed"
        )
    }

    require(
        burstSent.wait(timeout: .now() + 5) == .success,
        "global-mailbox burst was not sent"
    )
    // Keep the main consumer stalled while the broker I/O queue accounts the
    // entire fanout burst. No terminal exceeds 3 * (64KiB + overhead), so the
    // only applicable rejection is the 2MiB global ceiling.
    usleep(250_000)
    var pressureSnapshot: BrokerFlowControlSnapshot?
    client.flowControlSnapshot { pressureSnapshot = $0 }
    require(runMain(until: { resyncTerminalIDs.count == 1 && pressureSnapshot != nil }), "global overflow did not request resync")
    require(resyncTerminalIDs == [terminalIDs.last!], "global overflow was not isolated to one attachment")
    require(
        pressureSnapshot!.retainedEventBytes <= 2 * 1_024 * 1_024,
        "global event ledger exceeded 2MiB"
    )
    require(
        delivered[terminalIDs.last!] == nil,
        "invalidated overflow delivery token reached the renderer"
    )
    _ = runMain(until: { false }, timeout: 0.1)
    require(resyncTerminalIDs.count == 1, "overflow emitted duplicate resync callbacks")
    require(server.failure == nil, server.failure ?? "global-mailbox fake broker failed")
    client.stop()
}

private func wrongManifestIsRejected() throws {
    var wrong = manifest
    wrong["max_chunk_bytes"] = 1
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(manifest: wrong), to: fd)
        usleep(100_000)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var failure: Error?
    client.start { result in
        if case let .failure(error) = result { failure = error }
    }
    require(runMain(until: { failure != nil }), "wrong manifest was accepted")
    client.stop()
}

private func reorderedChunkIsRejected() throws {
    let checkpoint = Data("checkpoint".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        try Wire.send(Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest), to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 1,
            "data": checkpoint.base64EncodedString()
        ], to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort",
              abort["recovery_id"] as? String == "recovery-1",
              abort["terminal_id"] as? String == "term-1" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var failed = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "reorder scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { if case .failure = $0 { failed = true } }
    require(runMain(until: { failed }), "reordered recovery chunk was accepted")
    client.stop()
}

private func digestMismatchSendsAbort() throws {
    let checkpoint = Data("digest-mismatch".utf8)
    let declaredDigest = checkpointDigest(Data("different".utf8))
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        try Wire.send(
            Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: declaredDigest),
            to: fd
        )
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0, "data": checkpoint.base64EncodedString()
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_end",
            "recovery_id": "recovery-1", "digest": declaredDigest
        ], to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var failed = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "digest-mismatch scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { if case .failure = $0 { failed = true } }
    require(runMain(until: { failed }), "digest mismatch was accepted")
    usleep(30_000)
    require(server.failure == nil, server.failure ?? "digest abort fake broker failed")
    client.stop()
}

private func recoveryManifestMismatchSendsAbort() throws {
    let checkpoint = Data("manifest-mismatch".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        var begin = Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest)
        var wrong = manifest
        wrong["engine_source_commit"] = "unexpected-engine"
        begin["manifest"] = wrong
        try Wire.send(begin, to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var failed = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "recovery-manifest scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { if case .failure = $0 { failed = true } }
    require(runMain(until: { failed }), "mismatched recovery manifest was accepted")
    usleep(30_000)
    require(server.failure == nil, server.failure ?? "manifest abort fake broker failed")
    client.stop()
}

private func recoveryBeginSizeMismatchSendsAbort() throws {
    let checkpoint = Data("size-mismatch".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        var begin = Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest)
        begin["chunk_count"] = 2
        try Wire.send(begin, to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort",
              abort["recovery_id"] as? String == "recovery-1" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var failed = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "size-mismatch scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { if case .failure = $0 { failed = true } }
    require(runMain(until: { failed }), "inconsistent recovery total/chunk_count was accepted")
    usleep(30_000)
    require(server.failure == nil, server.failure ?? "size mismatch abort fake broker failed")
    client.stop()
}

private func commitBeforeEndIsImpossible() throws {
    let checkpoint = Data("checkpoint".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        try Wire.send(Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest), to: fd)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let activity = Darwin.poll(&pollFD, 1, 200)
        guard activity == 0 else { throw POSIXError(.EPROTO) }
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "commit-before-end scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { if case .success = $0 { prepared = true } }
    _ = runMain(until: { prepared }, timeout: 0.15)
    require(!prepared, "prepared authority escaped before recovery_end")
    require(runMain(until: { server.failure != nil || !prepared }, timeout: 0.1), "scenario stalled")
    client.stop()
}

private func rendererRefusalSendsAbort() throws {
    let checkpoint = Data("renderer-refusal".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        try Wire.send(Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest), to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0, "data": checkpoint.base64EncodedString()
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_end",
            "recovery_id": "recovery-1", "digest": digest
        ], to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort",
              abort["recovery_id"] as? String == "recovery-1" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared: BrokerPreparedRecovery?
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "renderer-refusal scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { prepared = try? $0.get() }
    require(runMain(until: { prepared != nil }), "renderer-refusal recovery was not prepared")
    client.abortRecovery(prepared!, reason: "smoke renderer refusal")
    require(runMain(until: { server.failure != nil || prepared != nil }, timeout: 0.15), "renderer abort stalled")
    usleep(30_000)
    require(server.failure == nil, server.failure ?? "renderer abort fake broker failed")
    client.stop()
}

private func commitFailureSendsAbort() throws {
    let checkpoint = Data("commit-failure".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        try Wire.send(Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest), to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0, "data": checkpoint.base64EncodedString()
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_end",
            "recovery_id": "recovery-1", "digest": digest
        ], to: fd)
        let commit = try Wire.read(from: fd)
        guard commit["op"] as? String == "recovery_commit" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "error", "id": requestID(commit),
            "code": "resync_required", "message": "cutover evicted"
        ], to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort",
              abort["recovery_id"] as? String == "recovery-1" else { throw POSIXError(.EBADMSG) }
        // The real server may report resync_required because commit already
        // released the pin. The best-effort abort reply must not mask failure.
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "error", "id": requestID(abort),
            "code": "resync_required", "message": "already released"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared: BrokerPreparedRecovery?
    var failed = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "commit-failure scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { prepared = try? $0.get() }
    require(runMain(until: { prepared != nil }), "commit-failure recovery was not prepared")
    client.commitAttachment(prepared!, onEvent: { _ in }) { if case .failure = $0 { failed = true } }
    require(runMain(until: { failed }), "commit failure was not surfaced")
    usleep(30_000)
    require(server.failure == nil, server.failure ?? "commit abort fake broker failed")
    client.stop()
}

private func cancelledPrepareAbortsLateRecoveryBegin() throws {
    let checkpoint = Data("cancelled-prepare".utf8)
    let digest = checkpointDigest(checkpoint)
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        let prepare = try Wire.read(from: fd)
        guard prepare["op"] as? String == "attach_prepare" else { throw POSIXError(.EBADMSG) }
        usleep(75_000)
        try Wire.send(
            Wire.recoveryBegin(id: requestID(prepare), checkpoint: checkpoint, digest: digest),
            to: fd
        )
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_chunk",
            "recovery_id": "recovery-1", "index": 0,
            "data": checkpoint.base64EncodedString()
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "recovery_end",
            "recovery_id": "recovery-1", "digest": digest
        ], to: fd)
        let abort = try Wire.read(from: fd)
        guard abort["op"] as? String == "recovery_abort",
              abort["recovery_id"] as? String == "recovery-1",
              abort["terminal_id"] as? String == "term-1" else {
            throw POSIXError(.EBADMSG)
        }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(abort), "result": "accepted"
        ], to: fd)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var cancelled = false
    var prepared = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "prepare-cancel scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") {
        if case .success = $0 { prepared = true }
        if case .failure = $0 { cancelled = true }
    }
    client.cancelAttachmentPreparation(terminalID: "term-1", reason: "rapid tab switch")
    require(runMain(until: { cancelled }), "prepare cancellation did not complete immediately")
    usleep(150_000)
    require(!prepared, "cancelled prepare leaked a prepared renderer candidate")
    require(server.failure == nil, server.failure ?? "late recovery_begin was not aborted")
    client.stop()
}

private func detachIsAnOrderedMutationFence() throws {
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        try attachOnServer(fd, readySequence: 0)
        let detach = try Wire.read(from: fd)
        guard detach["op"] as? String == "detach",
              (detach["input_epoch"] as? NSNumber)?.uint64Value == 11,
              detach["lease_id"] as? String == "lease-detach" else {
            throw POSIXError(.EBADMSG)
        }
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "state_event",
            "terminal_id": "term-1",
            "event": [
                "event": "pty_bytes", "state_seq": 1,
                "data": Data("before-detached-reply".utf8).base64EncodedString()
            ]
        ], to: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(detach), "result": "detached",
            "terminal_id": "term-1", "state_seq": 1
        ], to: fd)
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pollFD, 1, 150) == 0 else {
            throw POSIXError(.EPROTO)
        }
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared: BrokerPreparedRecovery?
    var attachment: BrokerAttachment?
    var events: [UInt64] = []
    var detachReceipt: BrokerDetachReceipt?
    var mutationRejected = false
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "detach-order scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { prepared = try? $0.get() }
    require(runMain(until: { prepared != nil }), "detach-order recovery was not prepared")
    client.commitAttachment(prepared!, onEvent: { events.append($0.sequence) }) {
        attachment = try? $0.get()
    }
    require(runMain(until: { attachment != nil }), "detach-order attachment was not ready")
    client.detach(attachment!) { detachReceipt = try? $0.get() }
    client.input(Data("must-not-cross-detach".utf8), using: attachment!) {
        if case .failure = $0 { mutationRejected = true }
    }
    require(runMain(until: { detachReceipt != nil && mutationRejected }), "detach did not fence mutation")
    require(events == [1], "pre-reply state event was not delivered before detach completion")
    require(detachReceipt == BrokerDetachReceipt(terminalID: "term-1", stateSequence: 1), "detach receipt changed")
    usleep(175_000)
    require(server.failure == nil, server.failure ?? "mutation crossed the detach barrier")
    client.stop()
}

private func liveEventAfterDetachReplyFailsClosed() throws {
    let server = try FakeBroker { fd in
        try Wire.send(Wire.hello(), to: fd)
        try attachOnServer(fd, readySequence: 0, leaseID: "lease-late")
        let detach = try Wire.read(from: fd)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "reply",
            "id": requestID(detach), "result": "detached",
            "terminal_id": "term-1", "state_seq": 0
        ], to: fd)
        usleep(25_000)
        try Wire.send([
            "version": 4, "broker_generation": 7, "type": "state_event",
            "terminal_id": "term-1",
            "event": [
                "event": "pty_bytes", "state_seq": 1,
                "data": Data("illegal-late-event".utf8).base64EncodedString()
            ]
        ], to: fd)
        usleep(100_000)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var connected = false
    var prepared: BrokerPreparedRecovery?
    var attachment: BrokerAttachment?
    var detached = false
    var disconnectMessage: String?
    client.onDisconnect = { disconnectMessage = $0.localizedDescription }
    client.start { if case .success = $0 { connected = true } }
    require(runMain(until: { connected }), "late-event scenario did not connect")
    client.prepareAttachment(terminalID: "term-1") { prepared = try? $0.get() }
    require(runMain(until: { prepared != nil }), "late-event recovery was not prepared")
    client.commitAttachment(prepared!, onEvent: { _ in }) { attachment = try? $0.get() }
    require(runMain(until: { attachment != nil }), "late-event attachment was not ready")
    client.detach(attachment!) { if case .success = $0 { detached = true } }
    require(runMain(until: { detached }), "valid detached reply was rejected")
    require(runMain(until: { disconnectMessage != nil }), "post-reply live event did not fail closed")
    require(
        disconnectMessage?.contains("after detached barrier") == true,
        "disconnect was not caused by the illegal post-reply live event"
    )
    client.stop()
}

private func explicitLegacyCompatibility() throws {
    let legacyCheckpoint = Data("legacy-state".utf8)
    let server = try FakeBroker { fd in
        try Wire.send([
            "version": 3, "broker_generation": 8, "type": "hello", "pid": getpid(),
            "build": "legacy-smoke",
            "capabilities": ["terminal.recovery.ansi_replay.viewport.v1"]
        ], to: fd)
        let attach = try Wire.read(from: fd)
        guard attach["version"] as? Int == 3,
              attach["op"] as? String == "attach",
              attach["after_cursor"] == nil else { throw POSIXError(.EBADMSG) }
        var legacyTerminal = terminal
        legacyTerminal["cursor"] = 5
        try Wire.send([
            "version": 3, "broker_generation": 8, "type": "reply",
            "id": requestID(attach), "result": "attached", "terminal": legacyTerminal,
            "input_epoch": 2, "lease_id": "legacy-lease",
            "recovery": [
                "mode": "snapshot", "cursor": 5, "format": "ansi_replay",
                "scope": "viewport", "snapshot_version": 1,
                "data": legacyCheckpoint.base64EncodedString()
            ]
        ], to: fd)
        let input = try Wire.read(from: fd)
        guard input["version"] as? Int == 3,
              input["op"] as? String == "input",
              input["lease_id"] as? String == "legacy-lease" else { throw POSIXError(.EBADMSG) }
        try Wire.send([
            "version": 3, "broker_generation": 8, "type": "reply",
            "id": requestID(input), "result": "accepted"
        ], to: fd)
        usleep(100_000)
    }
    let unusedV4 = URL(fileURLWithPath: "/tmp/unused-v4-\(UUID().uuidString.prefix(8)).sock")
    let client = BrokerClient(socketURL: unusedV4, legacySocketURL: server.socketURL)
    var connected = false
    var labelled = false
    var prepared: BrokerPreparedRecovery?
    var attachment: BrokerAttachment?
    var accepted = false
    var detachRejected = false
    client.onCompatibilityMode = { _ in labelled = true }
    client.startLegacyCompatibility { if case .success = $0 { connected = true } }
    require(runMain(until: { connected && labelled }), "explicit v3 mode was not connected and labelled")
    client.prepareAttachment(terminalID: "term-1") { prepared = try? $0.get() }
    require(runMain(until: { prepared != nil }), "v3 canonical snapshot was not prepared offscreen")
    require(prepared?.checkpoint == legacyCheckpoint, "v3 compatibility checkpoint changed")
    client.commitAttachment(prepared!, onEvent: { _ in }) { attachment = try? $0.get() }
    require(runMain(until: { attachment != nil }), "v3 local commit did not gate authority")
    client.input(Data("x".utf8), using: attachment!) { accepted = (try? $0.get()) != nil }
    require(runMain(until: { accepted }), "v3 compatibility lease input failed")
    client.detach(attachment!) { if case .failure = $0 { detachRejected = true } }
    require(runMain(until: { detachRejected }), "v3 compatibility pretended to support detach")
    require(server.failure == nil, server.failure ?? "legacy fake broker failed")
    client.stop()
}

private func kernelPeerPidMismatchIsRejected() throws {
    let server = try FakeBroker { fd in
        var hello = Wire.hello()
        hello["pid"] = getpid() + 1
        try Wire.send(hello, to: fd)
        usleep(100_000)
    }
    let client = BrokerClient(socketURL: server.socketURL)
    var failure: String?
    client.start {
        if case .failure(let error) = $0 {
            failure = error.localizedDescription
        }
    }
    require(runMain(until: { failure != nil }), "kernel peer PID mismatch was not rejected")
    require(
        failure?.contains("kernel peer identity") == true,
        "kernel peer PID mismatch returned the wrong failure"
    )
    client.stop()
}

@main
enum BrokerClientV4Smoke {
    static func main() throws {
        require(
            checkpointDigest(Data("abc".utf8)) == "sha256:295f150351bd02910106ee8a36dd64855f1a1f2547dfa26aa7163acd2ad80657",
            "cross-language checkpoint digest vector changed"
        )
        try fullWidthUnsignedGenerationIsAccepted()
        try wrongManifestIsRejected()
        try reorderedChunkIsRejected()
        try digestMismatchSendsAbort()
        try recoveryManifestMismatchSendsAbort()
        try recoveryBeginSizeMismatchSendsAbort()
        try commitBeforeEndIsImpossible()
        try rendererRefusalSendsAbort()
        try commitFailureSendsAbort()
        try cancelledPrepareAbortsLateRecoveryBegin()
        try detachIsAnOrderedMutationFence()
        try liveEventAfterDetachReplyFailsClosed()
        try happyPath()
        try globalMailboxOverflowIsIsolatedAndRequestsOneResync()
        try explicitLegacyCompatibility()
        try kernelPeerPidMismatchIsRejected()
        print("PASS: v4 manifest/order/recovery/resize/lease/detach/cancel/gap, kernel peer PID, plus explicit limited v3 compatibility")
    }
}
