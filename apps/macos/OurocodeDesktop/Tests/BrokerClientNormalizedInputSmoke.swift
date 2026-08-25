import CryptoKit
import Darwin
import Foundation

// Standalone cross-language wire smoke. Build with NormalizedTerminalInput.swift
// and BrokerClient.swift; no app target or TerminalHost dependency is required.

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

private func runMain(until predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
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
  "max_snapshot_bytes": 786_432,
  "max_terminal_history_bytes": 8_388_608,
  "max_global_history_bytes": 134_217_728,
  "max_delta_bytes": 524_288,
  "max_recovery_pinned_bytes": 16_777_216,
  "max_chunk_bytes": 65_536,
  "compression": "none",
]

private let terminal: [String: Any] = [
  "id": "term-input",
  "create_nonce": "input-smoke",
  "cursor": 0,
  "columns": 80,
  "rows": 24,
  "running": true,
  "foreground_process": false,
]

private final class FakeBroker {
  let socketURL: URL
  private let listener: Int32
  private let queue = DispatchQueue(label: "fake-normalized-input-broker")
  private let lock = NSLock()
  private var storedFailure: String?

  var failure: String? {
    lock.lock()
    defer { lock.unlock() }
    return storedFailure
  }

  convenience init(script: @escaping (Int32) throws -> Void) throws {
    try self.init(scripts: [script])
  }

  init(scripts: [(Int32) throws -> Void]) throws {
    let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
      .appendingPathComponent("oc-input-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    socketURL = directory.appendingPathComponent("broker-v4.sock")
    listener = try Self.bind(path: socketURL.path)
    queue.async { [weak self] in
      guard let self else { return }
      for script in scripts {
        let client = Darwin.accept(self.listener, nil, nil)
        guard client >= 0 else {
          self.record("accept failed")
          return
        }
        var noSignal: Int32 = 1
        setsockopt(
          client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
          socklen_t(MemoryLayout<Int32>.size))
        do {
          try script(client)
        } catch {
          self.record(error.localizedDescription)
        }
        Darwin.close(client)
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
    guard bytes.count <= 256 * 1_024,
      let object = try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    else {
      throw POSIXError(.EBADMSG)
    }
    return object
  }

  static func hello() -> [String: Any] {
    [
      "version": 4,
      "broker_generation": 7,
      "type": "hello",
      "pid": 42,
      "build": "normalized-input-smoke",
      "capabilities": [
        "terminal.state.ordered.v4",
        "terminal.recovery.two_phase.v4",
        "terminal.detach.lease.v4",
        "terminal.input.normalized.v1",
        "terminal.pointer.disposition.v1",
      ],
      "manifest": manifest,
    ]
  }

  static func reply(id: UInt64, result: String, fields: [String: Any] = [:]) -> [String: Any] {
    var object: [String: Any] = [
      "version": 4,
      "broker_generation": 7,
      "type": "reply",
      "id": id,
      "result": result,
    ]
    for (key, value) in fields {
      object[key] = value
    }
    return object
  }

  static func error(
    id: UInt64,
    code: String,
    message: String? = nil
  ) -> [String: Any] {
    [
      "version": 4,
      "broker_generation": 7,
      "type": "error",
      "id": id,
      "code": code,
      "message": message ?? "synthetic \(code)",
    ]
  }
}

private func requestID(_ object: [String: Any]) -> UInt64 {
  (object["id"] as! NSNumber).uint64Value
}

private func hasReadableBytes(_ fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
  var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
  let result = Darwin.poll(&descriptor, 1, timeoutMilliseconds)
  guard result >= 0 else { throw POSIXError(.EIO) }
  return result > 0 && (descriptor.revents & Int16(POLLIN)) != 0
}

private func attach(on fd: Int32, inputEpoch: UInt64, leaseID: String) throws {
  let prepare = try Wire.read(from: fd)
  guard prepare["op"] as? String == "attach_prepare",
    (prepare["broker_generation"] as? NSNumber)?.uint64Value == 7
  else {
    throw POSIXError(.EBADMSG)
  }
  try Wire.send(
    Wire.reply(
      id: requestID(prepare), result: "recovery_begin",
      fields: [
        "terminal": terminal,
        "recovery_id": "recovery-\(inputEpoch)",
        "cutover_state_seq": 0,
        "total_bytes": 0,
        "chunk_count": 0,
        "digest": checkpointDigest(Data()),
        "manifest": manifest,
      ]), to: fd)
  try Wire.send(
    [
      "version": 4,
      "broker_generation": 7,
      "type": "recovery_end",
      "recovery_id": "recovery-\(inputEpoch)",
      "digest": checkpointDigest(Data()),
    ], to: fd)
  let commit = try Wire.read(from: fd)
  guard commit["op"] as? String == "recovery_commit" else { throw POSIXError(.EBADMSG) }
  try Wire.send(
    Wire.reply(
      id: requestID(commit), result: "attached_ready",
      fields: [
        "terminal": terminal,
        "state_seq": 0,
        "input_epoch": inputEpoch,
        "lease_id": leaseID,
      ]), to: fd)
}

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
  for value: UInt64 in [786_432, 8_388_608, 134_217_728, 524_288, 16_777_216] {
    appendInteger(value, to: &input)
  }
  appendInteger(UInt32(65_536), to: &input)
  appendString("none", to: &input)
  appendInteger(UInt64(checkpoint.count), to: &input)
  input.append(checkpoint)
  return "sha256:" + SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
}

private func assertIdentity(
  _ request: [String: Any],
  sequence: UInt64,
  epoch: UInt64,
  lease: String
) throws {
  guard request["op"] as? String == "normalized_input",
    request["terminal_id"] as? String == "term-input",
    (request["broker_generation"] as? NSNumber)?.uint64Value == 7,
    (request["input_epoch"] as? NSNumber)?.uint64Value == epoch,
    (request["input_seq"] as? NSNumber)?.uint64Value == sequence,
    request["lease_id"] as? String == lease,
    let digest = request["event_digest"] as? String,
    digest.hasPrefix("sha256:"), digest.count == 71,
    request["event"] is [String: Any]
  else {
    throw POSIXError(.EBADMSG)
  }
}

private func receipt(for request: [String: Any]) -> [String: Any] {
  let event = request["event"] as? [String: Any]
  let kind = event?["kind"] as? String
  var fields: [String: Any] = [
    "terminal_id": request["terminal_id"]!,
    "input_epoch": request["input_epoch"]!,
    "input_seq": request["input_seq"]!,
    "event_digest": request["event_digest"]!,
    "lease_id": request["lease_id"]!,
    "observed_state_seq": 0,
    "layout_epoch": event?["layout_epoch"] ?? 0,
  ]
  if kind == "mouse" || kind == "scroll" {
    fields["pointer_disposition"] = "pty"
  }
  return Wire.reply(
    id: requestID(request), result: "input_receipt",
    fields: fields)
}

private func serverErrorCode(_ result: Result<NormalizedTerminalInputReceipt, Error>?) -> String? {
  guard case .failure(let error)? = result,
    case .server(let code, _) = error as? BrokerClientError
  else { return nil }
  return code
}

private func serverErrorMessage(
  _ result: Result<NormalizedTerminalInputReceipt, Error>?
) -> String? {
  guard case .failure(let error)? = result,
    case .server(_, let message) = error as? BrokerClientError
  else { return nil }
  return message
}

private func normalizedContract() throws {
  let focusDigest = try NormalizedTerminalInputEvent.focus(true).digestV1()
  require(
    focusDigest == "sha256:26fbfeca81af92b8d75869e54552f09881cff9540377db5d73624db1656d915e",
    "Swift normalized digest diverged from the Rust known vector"
  )

  let server = try FakeBroker { fd in
    try Wire.send(Wire.hello(), to: fd)
    try attach(on: fd, inputEpoch: 11, leaseID: "lease-11")

    let first = try Wire.read(from: fd)
    try assertIdentity(first, sequence: 1, epoch: 11, lease: "lease-11")
    guard (first["event"] as? [String: Any])?["kind"] as? String == "focus" else {
      throw POSIXError(.EBADMSG)
    }
    usleep(40_000)  // let the client prove a second request stays local
    try Wire.send(Wire.error(id: requestID(first), code: "queue_full"), to: fd)

    let retry = try Wire.read(from: fd)
    try assertIdentity(retry, sequence: 1, epoch: 11, lease: "lease-11")
    guard retry["event_digest"] as? String == first["event_digest"] as? String,
      retry["event"] as? NSDictionary == first["event"] as? NSDictionary
    else {
      throw POSIXError(.EBADMSG)
    }
    try Wire.send(receipt(for: retry), to: fd)

    for code in ["input_conflict", "input_gap", "stale_lease", "queue_full"] {
      let rejected = try Wire.read(from: fd)
      try assertIdentity(rejected, sequence: 2, epoch: 11, lease: "lease-11")
      try Wire.send(Wire.error(id: requestID(rejected), code: code), to: fd)
    }

    let key = try Wire.read(from: fd)
    try assertIdentity(key, sequence: 2, epoch: 11, lease: "lease-11")
    guard let keyEvent = key["event"] as? [String: Any],
      keyEvent["kind"] as? String == "key",
      keyEvent["action"] as? String == "press"
    else { throw POSIXError(.EBADMSG) }
    let detach = try Wire.read(from: fd)
    guard detach["op"] as? String == "detach",
      (detach["input_epoch"] as? NSNumber)?.uint64Value == 11,
      detach["lease_id"] as? String == "lease-11"
    else { throw POSIXError(.EBADMSG) }
    try Wire.send(receipt(for: key), to: fd)
    try Wire.send(
      Wire.reply(
        id: requestID(detach), result: "detached",
        fields: [
          "terminal_id": "term-input", "state_seq": 0,
        ]), to: fd)

    try attach(on: fd, inputEpoch: 12, leaseID: "lease-12")
    let fresh = try Wire.read(from: fd)
    try assertIdentity(fresh, sequence: 1, epoch: 12, lease: "lease-12")
    try Wire.send(receipt(for: fresh), to: fd)
    usleep(50_000)
  }

  let client = BrokerClient(socketURL: server.socketURL)
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected }), "normalized broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "normalized attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "normalized attachment did not commit")

  var queueFull: Result<NormalizedTerminalInputReceipt, Error>?
  var concurrent: Result<NormalizedTerminalInputReceipt, Error>?
  client.normalizedInput(.focus(true), using: attachment!) { queueFull = $0 }
  client.normalizedInput(.committedText("a"), using: attachment!) { concurrent = $0 }
  require(runMain(until: { concurrent != nil }), "second in-flight input was not rejected locally")
  require(serverErrorCode(concurrent) == nil, "single-in-flight rejection became a broker error")
  require(runMain(until: { queueFull != nil }), "queue_full was not parsed")
  require(serverErrorCode(queueFull) == "queue_full", "queue_full code changed")

  var retryReceipt: NormalizedTerminalInputReceipt?
  client.normalizedInput(.focus(true), using: attachment!) { retryReceipt = try? $0.get() }
  require(runMain(until: { retryReceipt != nil }), "same-sequence retry was not receipted")
  require(retryReceipt?.inputSequence == 1, "retry advanced input_seq")
  require(
    retryReceipt?.leaseID == "lease-11"
      && retryReceipt?.observedStateSequence == 0
      && retryReceipt?.layoutEpoch == 0
      && retryReceipt?.pointerDisposition == nil,
    "retry receipt lost the v1 lease/state/layout identity")

  let events: [NormalizedTerminalInputEvent] = [
    .focus(false), .committedText("한"), .paste("retry"), .focus(false),
  ]
  let codes = ["input_conflict", "input_gap", "stale_lease", "queue_full"]
  for (event, code) in zip(events, codes) {
    var outcome: Result<NormalizedTerminalInputReceipt, Error>?
    client.normalizedInput(event, using: attachment!) { outcome = $0 }
    require(runMain(until: { outcome != nil }), "\(code) was not delivered")
    require(serverErrorCode(outcome) == code, "\(code) was not preserved")
  }

  var oversize: Result<NormalizedTerminalInputReceipt, Error>?
  client.normalizedInput(
    .paste(String(repeating: "x", count: NormalizedTerminalInputEvent.maximumPasteBytes + 1)),
    using: attachment!
  ) { oversize = $0 }
  require(runMain(until: { oversize != nil }), "oversize paste preflight did not complete")
  guard case .failure(let error)? = oversize,
    case .invalidRequest = error as? BrokerClientError
  else {
    require(false, "oversize paste crossed the wire")
    return
  }

  let key = NormalizedTerminalKey(
    hidUsage: 0x04,
    action: .press,
    modifiers: [.shift],
    consumedModifiers: [],
    composing: false,
    unshiftedCodepoint: 0x61,
    text: "A"
  )
  var keyReceipt: NormalizedTerminalInputReceipt?
  var detached: BrokerDetachReceipt?
  var callbackOrder: [String] = []
  client.normalizedInput(.key(key), using: attachment!) { result in
    keyReceipt = try? result.get()
    callbackOrder.append("input")
  }
  client.detach(attachment!) { result in
    detached = try? result.get()
    callbackOrder.append("detach")
  }
  require(
    runMain(until: { keyReceipt != nil && detached != nil }), "input/detach FIFO barrier failed")
  require(callbackOrder == ["input", "detach"], "detach completed before the input receipt")
  require(keyReceipt?.inputSequence == 2, "explicit rejections consumed input_seq")

  prepared = nil
  var freshAttachment: BrokerAttachment?
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "fresh epoch was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { freshAttachment = try? $0.get() })
  require(runMain(until: { freshAttachment != nil }), "fresh epoch did not commit")
  var freshReceipt: NormalizedTerminalInputReceipt?
  client.normalizedInput(.focus(true), using: freshAttachment!) { freshReceipt = try? $0.get() }
  require(runMain(until: { freshReceipt != nil }), "fresh epoch input was not receipted")
  require(
    freshReceipt?.inputEpoch == 12 && freshReceipt?.inputSequence == 1,
    "new epoch did not reset input_seq")
  require(server.failure == nil, server.failure ?? "normalized input fake broker failed")
  client.stop()
}

private func ambiguousTransportIsNotRetried() throws {
  let server = try FakeBroker { fd in
    try Wire.send(Wire.hello(), to: fd)
    try attach(on: fd, inputEpoch: 21, leaseID: "lease-21")
    let input = try Wire.read(from: fd)
    try assertIdentity(input, sequence: 1, epoch: 21, lease: "lease-21")
    // Close after observation but before a receipt. Whether the broker
    // committed is unknowable; the client must not synthesize a retry.
  }
  let client = BrokerClient(socketURL: server.socketURL)
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  var outcome: Result<NormalizedTerminalInputReceipt, Error>?
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected }), "ambiguity broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "ambiguity attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "ambiguity attachment did not commit")
  client.normalizedInput(.focus(true), using: attachment!) { outcome = $0 }
  require(runMain(until: { outcome != nil }), "ambiguous transport did not fail the input")
  guard case .failure(let error)? = outcome,
    case .disconnected = error as? BrokerClientError
  else {
    require(false, "ambiguous transport outcome was misclassified")
    return
  }
  require(server.failure == nil, server.failure ?? "ambiguity fake broker failed")
  client.stop()
}

private func reorderedDetachFailsClosedUntilFreshEpoch() throws {
  let server = try FakeBroker(scripts: [
    { fd in
      try Wire.send(Wire.hello(), to: fd)
      try attach(on: fd, inputEpoch: 31, leaseID: "lease-31")
      let input = try Wire.read(from: fd)
      try assertIdentity(input, sequence: 1, epoch: 31, lease: "lease-31")
      let detach = try Wire.read(from: fd)
      guard detach["op"] as? String == "detach" else { throw POSIXError(.EBADMSG) }
      // Deliberately violate the broker's FIFO contract: detached must never
      // cross the wire while this earlier input lacks a receipt.
      try Wire.send(
        Wire.reply(
          id: requestID(detach), result: "detached",
          fields: ["terminal_id": "term-input", "state_seq": 0]),
        to: fd)
      guard try hasReadableBytes(fd, timeoutMilliseconds: 2_000) else {
        throw POSIXError(.ETIMEDOUT)
      }
      var byte: UInt8 = 0
      guard Darwin.read(fd, &byte, 1) == 0 else {
        throw POSIXError(.EBADMSG)
      }
    },
    { fd in
      try Wire.send(Wire.hello(), to: fd)
      // Any automatic replay would arrive before attach_prepare and fail this
      // exact fresh-authority handshake.
      try attach(on: fd, inputEpoch: 32, leaseID: "lease-32")
      let fresh = try Wire.read(from: fd)
      try assertIdentity(fresh, sequence: 1, epoch: 32, lease: "lease-32")
      try Wire.send(receipt(for: fresh), to: fd)
      usleep(50_000)
    },
  ])

  let client = BrokerClient(socketURL: server.socketURL)
  var reconnects = 0
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  var inputOutcome: Result<NormalizedTerminalInputReceipt, Error>?
  var detachOutcome: Result<BrokerDetachReceipt, Error>?
  var blockedRetry: Result<NormalizedTerminalInputReceipt, Error>?
  client.onReconnect = { _ in reconnects += 1 }
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected && reconnects == 1 }), "reorder broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "reorder attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "reorder attachment did not commit")

  client.normalizedInput(.focus(true), using: attachment!) { inputOutcome = $0 }
  client.detach(attachment!) { result in
    detachOutcome = result
    guard case .failure(let detachError) = result else { return }
    client.normalizedInput(.focus(false), using: attachment!) { retry in
      blockedRetry = retry
      client.reconnectAfterAuthorityFailure(detachError)
    }
  }
  require(runMain(until: { detachOutcome != nil }), "reordered detach had no completion")
  guard case .failure(let detachError)? = detachOutcome,
    case .resyncRequired = detachError as? BrokerClientError
  else {
    require(false, "reordered detached reply was accepted")
    return
  }
  require(runMain(until: { blockedRetry != nil }), "ambiguous lease accepted another input")
  guard case .failure(let retryError)? = blockedRetry,
    case .staleAttachment = retryError as? BrokerClientError
  else {
    require(false, "normalized ambiguity lock did not reject retry")
    return
  }
  require(
    runMain(until: { inputOutcome != nil && reconnects >= 2 }),
    "authority reconnect did not resolve ambiguity")
  guard case .failure(let inputError)? = inputOutcome,
    case .resyncRequired = inputError as? BrokerClientError
  else {
    require(false, "pending input was not classified as ambiguous")
    return
  }

  prepared = nil
  var freshAttachment: BrokerAttachment?
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "fresh reordered epoch was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { freshAttachment = try? $0.get() })
  require(runMain(until: { freshAttachment != nil }), "fresh reordered epoch did not commit")
  var freshReceipt: NormalizedTerminalInputReceipt?
  client.normalizedInput(.focus(true), using: freshAttachment!) { freshReceipt = try? $0.get() }
  require(runMain(until: { freshReceipt != nil }), "fresh reordered epoch input failed")
  require(
    freshReceipt?.inputEpoch == 32 && freshReceipt?.inputSequence == 1,
    "reordered input leaked into the fresh epoch")
  require(server.failure == nil, server.failure ?? "reordered detach fake broker failed")
  client.stop()
}

private func malformedReceiptLocksNormalizedInput() throws {
  let server = try FakeBroker { fd in
    try Wire.send(Wire.hello(), to: fd)
    try attach(on: fd, inputEpoch: 41, leaseID: "lease-41")
    let input = try Wire.read(from: fd)
    try assertIdentity(input, sequence: 1, epoch: 41, lease: "lease-41")
    var malformed = receipt(for: input)
    malformed["event_digest"] = "sha256:" + String(repeating: "0", count: 64)
    try Wire.send(malformed, to: fd)
    guard !(try hasReadableBytes(fd, timeoutMilliseconds: 150)) else {
      throw POSIXError(.EBADMSG)
    }
  }
  let client = BrokerClient(socketURL: server.socketURL)
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  var malformed: Result<NormalizedTerminalInputReceipt, Error>?
  var blocked: Result<NormalizedTerminalInputReceipt, Error>?
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected }), "malformed receipt broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "malformed receipt attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "malformed receipt attachment did not commit")
  client.normalizedInput(.focus(true), using: attachment!) { malformed = $0 }
  require(runMain(until: { malformed != nil }), "malformed receipt had no completion")
  guard case .failure(let malformedError)? = malformed,
    case .protocolViolation = malformedError as? BrokerClientError
  else {
    require(false, "malformed receipt was accepted")
    return
  }
  client.normalizedInput(.focus(false), using: attachment!) { blocked = $0 }
  require(runMain(until: { blocked != nil }), "malformed receipt did not lock the stream")
  guard case .failure(let blockedError)? = blocked,
    case .staleAttachment = blockedError as? BrokerClientError
  else {
    require(false, "input followed a malformed receipt")
    return
  }
  require(server.failure == nil, server.failure ?? "malformed receipt fake broker failed")
  client.stop()
}

private func pointerGeometryDispositionsAndStaleLayout() throws {
  let layoutEpoch: UInt64 = 73
  let geometry = NormalizedTerminalMouseGeometry(
    screenWidthQ8: 204_800,
    screenHeightQ8: 153_600,
    cellWidthQ8: 2_304,
    cellHeightQ8: 4_608,
    paddingTopQ8: 2_560,
    paddingBottomQ8: 2_816,
    paddingRightQ8: 3_072,
    paddingLeftQ8: 3_328
  )
  let geometryEvent = NormalizedTerminalInputEvent.mouseGeometry(
    layoutEpoch: layoutEpoch,
    geometry
  )
  let localSelectionEvent = NormalizedTerminalInputEvent.mouse(
    gestureID: 101,
    layoutEpoch: layoutEpoch,
    action: .press,
    button: .left,
    modifiers: [.shift, .option],
    xQ8: 3_584,
    yQ8: 5_376
  )
  let ptyEvent = NormalizedTerminalInputEvent.mouse(
    gestureID: 202,
    layoutEpoch: layoutEpoch,
    action: .motion,
    button: .none,
    modifiers: [.control],
    xQ8: 7_424,
    yQ8: 9_216
  )
  let localScrollbackEvent = NormalizedTerminalInputEvent.scroll(
    gestureID: 303,
    layoutEpoch: layoutEpoch,
    direction: .down,
    modifiers: [.command],
    xQ8: 11_264,
    yQ8: 13_056
  )
  let staleEvent = NormalizedTerminalInputEvent.mouse(
    gestureID: 404,
    layoutEpoch: layoutEpoch - 1,
    action: .release,
    button: .right,
    modifiers: [],
    xQ8: 256,
    yQ8: 512
  )

  let server = try FakeBroker { fd in
    try Wire.send(Wire.hello(), to: fd)
    try attach(on: fd, inputEpoch: 51, leaseID: "lease-51")

    let geometryRequest = try Wire.read(from: fd)
    try assertIdentity(geometryRequest, sequence: 1, epoch: 51, lease: "lease-51")
    guard let event = geometryRequest["event"] as? [String: Any],
      event["kind"] as? String == "mouse_geometry",
      (event["layout_epoch"] as? NSNumber)?.uint64Value == layoutEpoch,
      let wireGeometry = event["geometry"] as? [String: Any],
      (wireGeometry["screen_width_q8"] as? NSNumber)?.uint32Value
        == geometry.screenWidthQ8,
      (wireGeometry["screen_height_q8"] as? NSNumber)?.uint32Value
        == geometry.screenHeightQ8,
      (wireGeometry["cell_width_q8"] as? NSNumber)?.uint32Value
        == geometry.cellWidthQ8,
      (wireGeometry["cell_height_q8"] as? NSNumber)?.uint32Value
        == geometry.cellHeightQ8,
      (wireGeometry["padding_top_q8"] as? NSNumber)?.uint32Value
        == geometry.paddingTopQ8,
      (wireGeometry["padding_bottom_q8"] as? NSNumber)?.uint32Value
        == geometry.paddingBottomQ8,
      (wireGeometry["padding_right_q8"] as? NSNumber)?.uint32Value
        == geometry.paddingRightQ8,
      (wireGeometry["padding_left_q8"] as? NSNumber)?.uint32Value
        == geometry.paddingLeftQ8
    else { throw POSIXError(.EBADMSG) }
    var geometryReceipt = receipt(for: geometryRequest)
    geometryReceipt["observed_state_seq"] = 81
    try Wire.send(geometryReceipt, to: fd)

    let localSelection = try Wire.read(from: fd)
    try assertIdentity(localSelection, sequence: 2, epoch: 51, lease: "lease-51")
    guard let event = localSelection["event"] as? [String: Any],
      event["kind"] as? String == "mouse",
      (event["gesture_id"] as? NSNumber)?.uint64Value == 101,
      (event["layout_epoch"] as? NSNumber)?.uint64Value == layoutEpoch,
      event["action"] as? String == "press",
      event["button"] as? String == "left",
      (event["modifiers"] as? NSNumber)?.uint16Value
        == NormalizedTerminalModifiers([.shift, .option]).rawValue,
      (event["x_q8"] as? NSNumber)?.int32Value == 3_584,
      (event["y_q8"] as? NSNumber)?.int32Value == 5_376
    else { throw POSIXError(.EBADMSG) }
    var localSelectionReceipt = receipt(for: localSelection)
    localSelectionReceipt["observed_state_seq"] = 82
    localSelectionReceipt["pointer_disposition"] = "local_selection"
    try Wire.send(localSelectionReceipt, to: fd)

    let pty = try Wire.read(from: fd)
    try assertIdentity(pty, sequence: 3, epoch: 51, lease: "lease-51")
    guard let event = pty["event"] as? [String: Any],
      event["kind"] as? String == "mouse",
      (event["gesture_id"] as? NSNumber)?.uint64Value == 202,
      event["action"] as? String == "motion",
      event["button"] as? String == "none"
    else { throw POSIXError(.EBADMSG) }
    var ptyReceipt = receipt(for: pty)
    ptyReceipt["observed_state_seq"] = 83
    ptyReceipt["pointer_disposition"] = "pty"
    try Wire.send(ptyReceipt, to: fd)

    let localScrollback = try Wire.read(from: fd)
    try assertIdentity(localScrollback, sequence: 4, epoch: 51, lease: "lease-51")
    guard let event = localScrollback["event"] as? [String: Any],
      event["kind"] as? String == "scroll",
      (event["gesture_id"] as? NSNumber)?.uint64Value == 303,
      (event["layout_epoch"] as? NSNumber)?.uint64Value == layoutEpoch,
      event["direction"] as? String == "down",
      (event["modifiers"] as? NSNumber)?.uint16Value
        == NormalizedTerminalModifiers.command.rawValue,
      (event["x_q8"] as? NSNumber)?.int32Value == 11_264,
      (event["y_q8"] as? NSNumber)?.int32Value == 13_056
    else { throw POSIXError(.EBADMSG) }
    var localScrollbackReceipt = receipt(for: localScrollback)
    localScrollbackReceipt["observed_state_seq"] = 84
    localScrollbackReceipt["pointer_disposition"] = "local_scrollback"
    try Wire.send(localScrollbackReceipt, to: fd)

    let stale = try Wire.read(from: fd)
    try assertIdentity(stale, sequence: 5, epoch: 51, lease: "lease-51")
    guard let event = stale["event"] as? [String: Any],
      (event["layout_epoch"] as? NSNumber)?.uint64Value == layoutEpoch - 1
    else { throw POSIXError(.EBADMSG) }
    try Wire.send(
      Wire.error(
        id: requestID(stale),
        code: "bad_request",
        message: "pointer layout epoch 72 is stale; expected 73"
      ),
      to: fd
    )
    usleep(50_000)
  }

  let client = BrokerClient(socketURL: server.socketURL)
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected }), "pointer broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "pointer attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "pointer attachment did not commit")

  var geometryOutcome: Result<NormalizedTerminalInputReceipt, Error>?
  client.normalizedInput(geometryEvent, using: attachment!) { geometryOutcome = $0 }
  require(runMain(until: { geometryOutcome != nil }), "mouse geometry had no receipt")
  let geometryResult = try geometryOutcome!.get()
  require(
    geometryResult.layoutEpoch == layoutEpoch
      && geometryResult.observedStateSequence == 81
      && geometryResult.leaseID == "lease-51"
      && geometryResult.pointerDisposition == nil,
    "mouse geometry receipt lost exact layout/state/lease identity"
  )

  let routedEvents: [(NormalizedTerminalInputEvent, NormalizedPointerDisposition, UInt64)] = [
    (localSelectionEvent, .localSelection, 82),
    (ptyEvent, .pty, 83),
    (localScrollbackEvent, .localScrollback, 84),
  ]
  for (event, disposition, observedStateSequence) in routedEvents {
    var outcome: Result<NormalizedTerminalInputReceipt, Error>?
    client.normalizedInput(event, using: attachment!) { outcome = $0 }
    require(runMain(until: { outcome != nil }), "\(disposition.rawValue) had no receipt")
    let parsed = try outcome!.get()
    require(
      parsed.pointerDisposition == disposition
        && parsed.layoutEpoch == layoutEpoch
        && parsed.observedStateSequence == observedStateSequence
        && parsed.leaseID == "lease-51",
      "\(disposition.rawValue) receipt did not preserve exact routing identity"
    )
  }

  var staleOutcome: Result<NormalizedTerminalInputReceipt, Error>?
  client.normalizedInput(staleEvent, using: attachment!) { staleOutcome = $0 }
  require(runMain(until: { staleOutcome != nil }), "stale layout error was not delivered")
  require(serverErrorCode(staleOutcome) == "bad_request", "stale layout error code changed")
  require(
    serverErrorMessage(staleOutcome) == "pointer layout epoch 72 is stale; expected 73",
    "stale layout diagnostics changed"
  )
  require(server.failure == nil, server.failure ?? "pointer fake broker failed")
  client.stop()
}

private func expectReceiptProtocolViolation(
  _ label: String,
  event: NormalizedTerminalInputEvent,
  mutate: @escaping (inout [String: Any]) -> Void
) throws {
  let server = try FakeBroker { fd in
    try Wire.send(Wire.hello(), to: fd)
    try attach(on: fd, inputEpoch: 61, leaseID: "lease-61")
    let request = try Wire.read(from: fd)
    try assertIdentity(request, sequence: 1, epoch: 61, lease: "lease-61")
    var malformed = receipt(for: request)
    mutate(&malformed)
    try Wire.send(malformed, to: fd)
    guard !(try hasReadableBytes(fd, timeoutMilliseconds: 150)) else {
      throw POSIXError(.EBADMSG)
    }
  }

  let client = BrokerClient(socketURL: server.socketURL)
  var connected = false
  var prepared: BrokerPreparedRecovery?
  var attachment: BrokerAttachment?
  var malformed: Result<NormalizedTerminalInputReceipt, Error>?
  var blocked: Result<NormalizedTerminalInputReceipt, Error>?
  client.start { if case .success = $0 { connected = true } }
  require(runMain(until: { connected }), "\(label) broker did not connect")
  client.prepareAttachment(terminalID: "term-input") { prepared = try? $0.get() }
  require(runMain(until: { prepared != nil }), "\(label) attachment was not prepared")
  client.commitAttachment(
    prepared!, onEvent: { _ in }, completion: { attachment = try? $0.get() })
  require(runMain(until: { attachment != nil }), "\(label) attachment did not commit")
  client.normalizedInput(event, using: attachment!) { malformed = $0 }
  require(runMain(until: { malformed != nil }), "\(label) had no completion")
  guard case .failure(let malformedError)? = malformed,
    case .protocolViolation = malformedError as? BrokerClientError
  else {
    require(false, "\(label) receipt was accepted")
    return
  }
  client.normalizedInput(.focus(false), using: attachment!) { blocked = $0 }
  require(runMain(until: { blocked != nil }), "\(label) did not lock the input stream")
  guard case .failure(let blockedError)? = blocked,
    case .staleAttachment = blockedError as? BrokerClientError
  else {
    require(false, "input followed the \(label) protocol violation")
    return
  }
  require(server.failure == nil, server.failure ?? "\(label) fake broker failed")
  client.stop()
}

private func malformedPointerReceiptMatrix() throws {
  let geometry = NormalizedTerminalInputEvent.mouseGeometry(
    layoutEpoch: 91,
    NormalizedTerminalMouseGeometry(
      screenWidthQ8: 100,
      screenHeightQ8: 200,
      cellWidthQ8: 10,
      cellHeightQ8: 20,
      paddingTopQ8: 1,
      paddingBottomQ8: 2,
      paddingRightQ8: 3,
      paddingLeftQ8: 4
    )
  )
  let mouse = NormalizedTerminalInputEvent.mouse(
    gestureID: 1,
    layoutEpoch: 91,
    action: .press,
    button: .left,
    modifiers: [],
    xQ8: 0,
    yQ8: 0
  )

  try expectReceiptProtocolViolation("missing pointer disposition", event: mouse) {
    $0.removeValue(forKey: "pointer_disposition")
  }
  try expectReceiptProtocolViolation("invented geometry disposition", event: geometry) {
    $0["pointer_disposition"] = "pty"
  }
  try expectReceiptProtocolViolation("unknown pointer disposition", event: mouse) {
    $0["pointer_disposition"] = "future_route"
  }
  try expectReceiptProtocolViolation("mismatched layout epoch", event: mouse) {
    $0["layout_epoch"] = 90
  }
  try expectReceiptProtocolViolation("mismatched lease", event: mouse) {
    $0["lease_id"] = "lease-forged"
  }
  try expectReceiptProtocolViolation("missing observed state sequence", event: mouse) {
    $0.removeValue(forKey: "observed_state_seq")
  }
}

@main
enum BrokerClientNormalizedInputSmoke {
  static func main() throws {
    try normalizedContract()
    try ambiguousTransportIsNotRetried()
    try reorderedDetachFailsClosedUntilFreshEpoch()
    try malformedReceiptLocksNormalizedInput()
    try pointerGeometryDispositionsAndStaleLayout()
    try malformedPointerReceiptMatrix()
    print(
      "PASS: normalized input digest/FIFO/retry/detach/geometry/disposition/identity/stale-layout"
    )
  }
}
