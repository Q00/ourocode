import Darwin
import Foundation

/// Broker-owned description of the private RFC 0005 gateway. This value is
/// accepted only from the kernel-authenticated terminal-broker hello; MCP
/// catalog metadata and public endpoint responses never enter this decoder.
struct SessionMessageGatewayDescriptorV1: Equatable {
    let socketPath: String
    let brokerGeneration: UInt64
    let capabilities: Set<String>
    let authority: SessionMessageAuthorityV1?

    static func decode(
        _ value: Any?,
        terminalBrokerGeneration: UInt64
    ) throws -> SessionMessageGatewayDescriptorV1? {
        guard let value else { return nil }
        guard let object = value as? [String: Any] else {
            throw SessionMessageGatewayClientError.invalidDescriptor
        }
        let allowedKeys: Set<String> = [
            "version", "socket_path", "broker_generation", "capabilities", "authority"
        ]
        guard Set(object.keys).isSubset(of: allowedKeys),
              Self.uint(object["version"]) == 1,
              let socketPath = object["socket_path"] as? String,
              Self.isCanonicalAbsolutePath(socketPath),
              let generation = Self.uint(object["broker_generation"]),
              generation > 0,
              generation == terminalBrokerGeneration,
              let capabilityValues = object["capabilities"] as? [String],
              !capabilityValues.isEmpty,
              capabilityValues.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw SessionMessageGatewayClientError.invalidDescriptor
        }
        let capabilities = Set(capabilityValues)
        guard capabilities.count == capabilityValues.count else {
            throw SessionMessageGatewayClientError.invalidDescriptor
        }

        let authority: SessionMessageAuthorityV1?
        if object.keys.contains("authority"), !(object["authority"] is NSNull) {
            guard let authorityObject = object["authority"] as? [String: Any],
                  Set(authorityObject.keys) == ["binding_id", "authority_epoch"],
                  let bindingID = authorityObject["binding_id"] as? String,
                  !bindingID.isEmpty,
                  bindingID.utf8.count <= SessionMessageContractV1.maximumIDBytes,
                  let authorityEpoch = Self.uint(authorityObject["authority_epoch"]) else {
                throw SessionMessageGatewayClientError.invalidDescriptor
            }
            authority = SessionMessageAuthorityV1(
                brokerGeneration: generation,
                authorityEpoch: authorityEpoch,
                bindingID: bindingID
            )
        } else {
            authority = nil
        }

        return SessionMessageGatewayDescriptorV1(
            socketPath: socketPath,
            brokerGeneration: generation,
            capabilities: capabilities,
            authority: authority
        )
    }

    private static func uint(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.uint64Value
        return NSNumber(value: result) == number ? result : nil
    }

    private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count < 104 else {
            return false
        }
        return (path as NSString).standardizingPath == path
    }
}

enum SessionMessageGatewayClientError: Error, Equatable, CustomStringConvertible {
    case invalidDescriptor
    case unavailable(String)
    case peerMismatch
    case staleBrokerGeneration
    case requestAlreadyPending
    case outcomeUnknown(requestNonce: String)
    case transport(String)

    var description: String {
        switch self {
        case .invalidDescriptor: return "Authenticated session gateway descriptor is malformed"
        case .unavailable(let reason): return reason
        case .peerMismatch: return "Authenticated session gateway is not owned by the terminal broker"
        case .staleBrokerGeneration: return "Authenticated session gateway belongs to a stale broker generation"
        case .requestAlreadyPending: return "Another authenticated session message is still pending"
        case .outcomeUnknown: return "Delivery outcome is unknown; check status with the same nonce"
        case .transport(let message): return message
        }
    }
}

/// One bounded private connection for the desktop principal. It deliberately
/// serializes requests stop-and-wait: a second effect can never be issued
/// while the first write or reply has an ambiguous outcome.
final class SessionMessageGatewayClientV1 {
    private static let timeoutSeconds = 3

    private let descriptor: SessionMessageGatewayDescriptorV1
    private let expectedBrokerPID: pid_t
    private let queue = DispatchQueue(label: "works.ourocode.session-message-gateway", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var socketFD: Int32 = -1
    private var pending = false
    private var stopped = false

    var onCapabilityStateChange: ((SessionMessageCapabilityStateV1) -> Void)?

    init(descriptor: SessionMessageGatewayDescriptorV1, expectedBrokerPID: UInt32) {
        self.descriptor = descriptor
        self.expectedBrokerPID = pid_t(expectedBrokerPID)
    }

    deinit {
        if socketFD >= 0 { Darwin.close(socketFD) }
    }

    func start() {
        publish(.verifying)
        queue.async { [weak self] in
            guard let self, !self.stopped else { return }
            do {
                self.socketFD = try self.openVerifiedSocket()
                let state = SessionMessageCapabilityStateV1.negotiate(
                    advertisedCapabilities: self.descriptor.capabilities,
                    reciprocalPeerVerified: true,
                    durableBindingAcknowledged: true,
                    knownVectorVerified: Self.codecSelfTest(),
                    authority: self.descriptor.authority
                )
                self.publish(state)
            } catch {
                self.closeSocket()
                self.publish(.unavailable(reason: Self.describe(error)))
            }
        }
    }

    func stop(reason: String = "Terminal broker disconnected") {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopped = true
            self.closeSocket()
            self.publish(.revoked(reason: reason))
        }
    }

    func submit(
        _ request: SessionMessageRequestV1,
        completion: @escaping (Result<SessionMessageReplyV1, Error>) -> Void
    ) {
        transact(
            payload: { try request.wireData() },
            expectedID: request.id,
            brokerGeneration: request.brokerGeneration,
            requestNonce: request.requestNonce,
            completion: completion
        )
    }

    func status(
        _ request: SessionMessageStatusRequestV1,
        completion: @escaping (Result<SessionMessageReplyV1, Error>) -> Void
    ) {
        transact(
            payload: { try request.wireData() },
            expectedID: request.id,
            brokerGeneration: request.brokerGeneration,
            requestNonce: request.requestNonce,
            completion: completion
        )
    }

    private func transact(
        payload: @escaping () throws -> Data,
        expectedID: UInt64,
        brokerGeneration: UInt64,
        requestNonce: String,
        completion: @escaping (Result<SessionMessageReplyV1, Error>) -> Void
    ) {
        guard claimPendingRequest() else {
            complete(completion, .failure(SessionMessageGatewayClientError.requestAlreadyPending))
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            defer { self.releasePendingRequest() }
            guard !self.stopped, self.socketFD >= 0 else {
                return self.complete(completion, .failure(SessionMessageGatewayClientError.unavailable(
                    "Authenticated session gateway is disconnected"
                )))
            }
            guard brokerGeneration == self.descriptor.brokerGeneration else {
                return self.complete(completion, .failure(SessionMessageGatewayClientError.staleBrokerGeneration))
            }
            var attemptedWrite = false
            do {
                let frame = try SessionMessageWireCodecV1.frame(payload())
                attemptedWrite = true
                try self.writeAll(frame)
                let reply = try self.readFrame()
                let decoded = try SessionMessageWireCodecV1.decodeReply(
                    reply,
                    expectedID: expectedID,
                    brokerGeneration: brokerGeneration
                )
                self.complete(completion, .success(decoded))
            } catch {
                self.closeSocket()
                // Once write(2) is attempted, userspace cannot prove the
                // private service observed zero bytes. Preserve the nonce and
                // require status instead of ever issuing a second effect.
                let failure: Error = attemptedWrite
                    ? SessionMessageGatewayClientError.outcomeUnknown(requestNonce: requestNonce)
                    : error
                self.complete(completion, .failure(failure))
                self.publish(.revoked(reason: Self.describe(failure)))
            }
        }
    }

    private func claimPendingRequest() -> Bool {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        guard !pending else { return false }
        pending = true
        return true
    }

    private func releasePendingRequest() {
        pendingLock.lock()
        pending = false
        pendingLock.unlock()
    }

    private func openVerifiedSocket() throws -> Int32 {
        var address = sockaddr_un()
        let pathBytes = Array(descriptor.socketPath.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw SessionMessageGatewayClientError.invalidDescriptor
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            descriptor.socketPath.withCString { source in
                memcpy(destination, source, pathBytes.count)
            }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Self.transportError("create authenticated session socket") }
        do {
            var noSignal: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
                throw Self.transportError("configure authenticated session socket")
            }
            var timeout = timeval(tv_sec: Self.timeoutSeconds, tv_usec: 0)
            guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw Self.transportError("bound authenticated session timeout")
            }
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard connected == 0 else { throw Self.transportError("connect authenticated session gateway") }
            try verifyPeer(fd)
            guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
                throw Self.transportError("protect authenticated session descriptor")
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func verifyPeer(_ fd: Int32) throws {
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == geteuid() else {
            throw SessionMessageGatewayClientError.peerMismatch
        }
        var peerPID: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &size) == 0,
              size == MemoryLayout<pid_t>.size,
              peerPID == expectedBrokerPID else {
            throw SessionMessageGatewayClientError.peerMismatch
        }
    }

    private func writeAll(_ data: Data) throws {
        var written = 0
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw SessionMessageGatewayClientError.transport("Authenticated session frame is empty")
            }
            while written < rawBuffer.count {
                let count = Darwin.write(socketFD, base.advanced(by: written), rawBuffer.count - written)
                if count > 0 { written += count; continue }
                if count < 0, errno == EINTR { continue }
                throw Self.transportError("write authenticated session request")
            }
        }
    }

    private func readFrame() throws -> Data {
        let prefix = try readExactly(4)
        let length = prefix.withUnsafeBytes { rawBuffer -> UInt32 in
            rawBuffer.loadUnaligned(as: UInt32.self).bigEndian
        }
        guard length > 0, length <= UInt32(SessionMessageContractV1.maximumReceiptBytes) else {
            throw SessionMessageContractError.replyTooLarge
        }
        return try readExactly(Int(length))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data(count: count)
        var offset = 0
        try result.withUnsafeMutableBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else {
                throw SessionMessageGatewayClientError.transport("Authenticated session reply is empty")
            }
            while offset < count {
                let received = Darwin.read(socketFD, base.advanced(by: offset), count - offset)
                if received > 0 { offset += received; continue }
                if received < 0, errno == EINTR { continue }
                throw Self.transportError("read authenticated session reply")
            }
        }
        return result
    }

    private func closeSocket() {
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
    }

    private func publish(_ state: SessionMessageCapabilityStateV1) {
        DispatchQueue.main.async { [weak self] in self?.onCapabilityStateChange?(state) }
    }

    private func complete<T>(
        _ completion: @escaping (Result<T, Error>) -> Void,
        _ result: Result<T, Error>
    ) {
        DispatchQueue.main.async { completion(result) }
    }

    private static func transportError(_ operation: String) -> SessionMessageGatewayClientError {
        .transport("Failed to \(operation): \(String(cString: strerror(errno)))")
    }

    private static func describe(_ error: Error) -> String {
        String(describing: error)
    }

    /// A small frozen check that exercises the same closed reply decoder used
    /// on the socket before any broker-advertised authority can become ready.
    static func codecSelfTest() -> Bool {
        let payload = Data(#"{"version":1,"broker_generation":7,"id":9,"error":"session_message_error","code":"unauthorized","message":"read only"}"#.utf8)
        guard case .failure(let reply)? = try? SessionMessageWireCodecV1.decodeReply(
            payload,
            expectedID: 9,
            brokerGeneration: 7
        ) else { return false }
        return reply.code == .unauthorized && reply.message == "read only"
    }
}
