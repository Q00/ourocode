import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

private func socketAddress(_ path: String) -> sockaddr_un {
    var address = sockaddr_un()
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8CString)
    require(bytes.count <= MemoryLayout.size(ofValue: address.sun_path), "fixture socket path fits")
    _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
        path.withCString { source in memcpy(destination, source, bytes.count) }
    }
    return address
}

private func writeAll(_ fd: Int32, _ data: Data) {
    var offset = 0
    data.withUnsafeBytes { raw in
        while offset < raw.count {
            let count = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
            require(count > 0, "fixture server write")
            offset += count
        }
    }
}

private func readExactly(_ fd: Int32, _ count: Int) -> Data {
    var data = Data(count: count)
    var offset = 0
    data.withUnsafeMutableBytes { raw in
        while offset < count {
            let received = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            require(received > 0, "fixture server read")
            offset += received
        }
    }
    return data
}

private func makeListener(path: String) -> Int32 {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    require(fd >= 0, "fixture listener socket")
    unlink(path)
    var address = socketAddress(path)
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    require(bound == 0, "fixture listener bind")
    require(Darwin.listen(fd, 1) == 0, "fixture listener listen")
    return fd
}

private func spinUntil(_ predicate: () -> Bool, timeout: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    require(predicate(), "asynchronous gateway fixture completed")
}

@main
enum SessionMessageGatewayClientFixture {
static func main() throws {
require(SessionMessageGatewayClientV1.codecSelfTest(), "closed codec self-test")

do {
    let absent = try SessionMessageGatewayDescriptorV1.decode(nil, terminalBrokerGeneration: 7)
    require(absent == nil, "absent broker descriptor remains unavailable")
    _ = try SessionMessageGatewayDescriptorV1.decode([
        "version": 1,
        "socket_path": "relative.sock",
        "broker_generation": 7,
        "capabilities": Array(SessionMessageContractV1.requiredCapabilities),
        "authority": NSNull(),
    ], terminalBrokerGeneration: 7)
    require(false, "relative broker descriptor must fail")
} catch SessionMessageGatewayClientError.invalidDescriptor {
    // Expected.
} catch {
    require(false, "relative descriptor failed closed with expected error")
}

do {
    _ = try SessionMessageGatewayDescriptorV1.decode([
        "version": 1,
        "socket_path": "/tmp/session-message.sock",
        "broker_generation": 8,
        "capabilities": Array(SessionMessageContractV1.requiredCapabilities),
        "authority": NSNull(),
    ], terminalBrokerGeneration: 7)
    require(false, "stale descriptor generation must fail")
} catch SessionMessageGatewayClientError.invalidDescriptor {
    // Expected.
} catch {
    require(false, "stale descriptor failed closed with expected error")
}

let publicMCPOnly = SessionMessageCapabilityStateV1.negotiate(
    advertisedCapabilities: ["tools/list", "experimental.session_message"],
    reciprocalPeerVerified: true,
    durableBindingAcknowledged: true,
    knownVectorVerified: true,
    authority: SessionMessageAuthorityV1(brokerGeneration: 7, authorityEpoch: 1, bindingID: "forged")
)
require(publicMCPOnly.authority == nil, "public MCP metadata cannot enable authority")

let temporary = URL(fileURLWithPath: "/tmp", isDirectory: true)
    .appendingPathComponent("ourocode-gw-\(UUID().uuidString.prefix(8))", isDirectory: true)
try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
let socketPath = temporary.appendingPathComponent("gateway.sock").path
let listener = makeListener(path: socketPath)

let server = DispatchQueue(label: "fixture.session-message-server")
server.async {
    let client = Darwin.accept(listener, nil, nil)
    require(client >= 0, "fixture accepts client")
    let prefix = readExactly(client, 4)
    let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
    _ = readExactly(client, Int(length))
    let reply = Data(#"{"version":1,"broker_generation":7,"id":9,"error":"session_message_error","code":"unauthorized","message":"fixture read only"}"#.utf8)
    let framed = try! SessionMessageWireCodecV1.frame(reply)
    writeAll(client, framed)
    Darwin.close(client)
    Darwin.close(listener)
}

let descriptor = try SessionMessageGatewayDescriptorV1.decode([
    "version": 1,
    "socket_path": socketPath,
    "broker_generation": 7,
    "capabilities": Array(SessionMessageContractV1.requiredCapabilities),
    "authority": ["binding_id": "desktop-binding-1", "authority_epoch": 4],
], terminalBrokerGeneration: 7)!
let client = SessionMessageGatewayClientV1(descriptor: descriptor, expectedBrokerPID: UInt32(getpid()))
var capability: SessionMessageCapabilityStateV1?
client.onCapabilityStateChange = { capability = $0 }
client.start()
spinUntil { capability?.authority != nil }

let request = SessionMessageRequestV1(
    id: 9,
    brokerGeneration: 7,
    authorityEpoch: 4,
    requestNonce: "EiQ2SFpscYKTpLXNZ2mr7A",
    targetSessionID: "target-session",
    expectedExecutionID: nil,
    expectedTargetGeneration: nil,
    mode: .afterTurn,
    message: "fixture",
    reason: "gateway fixture",
    expiresAt: "2026-08-16T12:30:00Z",
    correlationID: nil
)
var reply: Result<SessionMessageReplyV1, Error>?
client.submit(request) { reply = $0 }
var overlappingReply: Result<SessionMessageReplyV1, Error>?
client.submit(request) { overlappingReply = $0 }
spinUntil { overlappingReply != nil }
if case .failure(let error)? = overlappingReply {
    require(
        error as? SessionMessageGatewayClientError == .requestAlreadyPending,
        "stop-and-wait rejects an overlapping effect"
    )
} else {
    require(false, "overlapping effect fails locally")
}
spinUntil { reply != nil }
if case .success(.failure(let failure))? = reply {
    require(failure.code == .unauthorized, "live private gateway reply decoded")
} else {
    require(false, "live private gateway returned closed error reply")
}
var staleReply: Result<SessionMessageReplyV1, Error>?
client.status(SessionMessageStatusRequestV1(
    id: 10,
    brokerGeneration: 8,
    authorityEpoch: 4,
    requestNonce: request.requestNonce
)) { staleReply = $0 }
spinUntil { staleReply != nil }
if case .failure(let error)? = staleReply {
    require(
        error as? SessionMessageGatewayClientError == .staleBrokerGeneration,
        "stale broker generation fails before transport"
    )
} else {
    require(false, "stale broker generation is rejected")
}
client.stop(reason: "fixture complete")
try? FileManager.default.removeItem(at: temporary)

print("session-message gateway client fixture passed")
}
}
