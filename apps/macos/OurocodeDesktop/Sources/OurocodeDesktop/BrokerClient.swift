import CryptoKit
import Darwin
import Foundation

// The desktop is deliberately a view of broker-owned PTYs. This client keeps
// the wire transport on one serial queue and never creates a thread per
// terminal. All callbacks cross to the main queue.

struct BrokerHello: Equatable {
    let generation: UInt64
    let pid: UInt32
    let build: String
    let capabilities: Set<String>
    let manifest: BrokerRecoveryManifest?
    /// Present only when the authenticated terminal broker owns a live,
    /// private session-message gateway for this exact generation.
    let sessionMessageGateway: SessionMessageGatewayDescriptorV1?
}

struct BrokerTerminalSummary: Equatable {
    let id: String
    let createNonce: String
    let stateSequence: UInt64
    let columns: Int
    let rows: Int
    let layoutEpoch: UInt64
    let running: Bool
    let foregroundProcess: Bool

    // Kept as a source-compatible name for the first broker UI spike.
    var cursor: UInt64 { stateSequence }
}

struct BrokerRecoveryManifest: Equatable {
    let protocolVersion: UInt64
    let terminalABIVersion: UInt64
    let engineSourceCommit: String
    let snapshotMagic: String
    let snapshotFormatVersion: UInt64
    let unicodeWidthPolicy: String
    let graphicsPolicy: String
    let maximumSnapshotBytes: UInt64
    let maximumTerminalHistoryBytes: UInt64
    let maximumGlobalHistoryBytes: UInt64
    let maximumDeltaBytes: UInt64
    let maximumRecoveryPinnedBytes: UInt64
    let maximumChunkBytes: UInt64
    let compression: String
}

enum BrokerStateEvent: Equatable {
    case ptyBytes(sequence: UInt64, data: Data)
    case resize(
        sequence: UInt64,
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int,
        layoutEpoch: UInt64
    )

    var sequence: UInt64 {
        switch self {
        case let .ptyBytes(sequence, _),
             let .resize(sequence, _, _, _, _, _):
            return sequence
        }
    }
}

struct BrokerPreparedRecovery {
    let terminal: BrokerTerminalSummary
    let manifest: BrokerRecoveryManifest
    let checkpoint: Data
    let cutoverStateSequence: UInt64
    let digest: String

    fileprivate let recoveryID: String
    fileprivate let brokerGeneration: UInt64
    fileprivate let connectionID: UUID
}

/// Immutable pane-facing projection of one exact broker attachment authority.
///
/// Construction is deliberately confined to this file. Callers can retain and
/// compare the small value without gaining access to the attachment, its
/// one-shot catch-up payload, or BrokerClient's fileprivate connection fields.
struct PaneAttachmentIdentityToken: Equatable, Hashable, Sendable {
    let terminalID: String
    let brokerGeneration: UInt64
    let connectionID: UUID
    let inputEpoch: UInt64
    let leaseID: String
    let surfaceInstanceID: UUID
    let runtimeGeneration: UInt64

    fileprivate init(
        terminalID: String,
        brokerGeneration: UInt64,
        connectionID: UUID,
        inputEpoch: UInt64,
        leaseID: String,
        surfaceInstanceID: UUID,
        runtimeGeneration: UInt64
    ) {
        self.terminalID = terminalID
        self.brokerGeneration = brokerGeneration
        self.connectionID = connectionID
        self.inputEpoch = inputEpoch
        self.leaseID = leaseID
        self.surfaceInstanceID = surfaceInstanceID
        self.runtimeGeneration = runtimeGeneration
    }
}

struct BrokerAttachment {
    let terminal: BrokerTerminalSummary
    let inputEpoch: UInt64
    let leaseID: String

    fileprivate let brokerGeneration: UInt64
    fileprivate let connectionID: UUID
    fileprivate let catchUp: OneShotHandoff<BrokerStateEvent>?

    /// Catch-up is a synchronous, one-shot renderer handoff. It is never part
    /// of the durable attachment authority, so storing this attachment in a
    /// tab cannot retain already-rendered PTY payloads.
    func consumeCatchUpEvents(_ body: ([BrokerStateEvent]) throws -> Void) rethrows {
        if let catchUp {
            _ = try catchUp.consume(body)
        } else {
            try body([])
        }
    }

    /// Export only the immutable identity needed to invalidate pane work.
    ///
    /// This comparison authority is strictly stronger than the legacy
    /// terminal/inputEpoch/leaseID checks: it also binds the broker generation,
    /// exact transport connection, surface allocation, and renderer runtime.
    func paneProjectionIdentity(
        surfaceInstanceID: UUID,
        runtimeGeneration: UInt64
    ) -> PaneAttachmentIdentityToken? {
        guard !terminal.id.isEmpty,
              brokerGeneration > 0,
              connectionID != Self.zeroUUID,
              inputEpoch > 0,
              !leaseID.isEmpty,
              surfaceInstanceID != Self.zeroUUID,
              runtimeGeneration > 0 else {
            return nil
        }
        return PaneAttachmentIdentityToken(
            terminalID: terminal.id,
            brokerGeneration: brokerGeneration,
            connectionID: connectionID,
            inputEpoch: inputEpoch,
            leaseID: leaseID,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        )
    }

    private static let zeroUUID = UUID(uuid: (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    ))
}

#if OUROCODE_PANE_PROJECTION_FIXTURE
extension BrokerAttachment {
    /// Test-only construction remains in the file that owns fileprivate broker
    /// authority. Production builds expose no arbitrary attachment initializer.
    static func paneProjectionFixtureAttachment(
        terminalID: String,
        brokerGeneration: UInt64,
        connectionID: UUID,
        inputEpoch: UInt64,
        leaseID: String,
        layoutEpoch: UInt64
    ) -> BrokerAttachment {
        BrokerAttachment(
            terminal: BrokerTerminalSummary(
                id: terminalID,
                createNonce: "pane-projection-fixture",
                stateSequence: 1,
                columns: 120,
                rows: 36,
                layoutEpoch: layoutEpoch,
                running: true,
                foregroundProcess: false
            ),
            inputEpoch: inputEpoch,
            leaseID: leaseID,
            brokerGeneration: brokerGeneration,
            connectionID: connectionID,
            catchUp: nil
        )
    }
}
#endif

struct BrokerDetachReceipt: Equatable {
    let terminalID: String
    let stateSequence: UInt64
}

struct BrokerFlowControlSnapshot: Equatable {
    let retainedEventBytes: Int
    let activeAttachments: Int
    let scheduledDeliveries: Int
}

enum BrokerClientError: Error, Equatable {
    case notConnected
    case helperMissing(String)
    case connectFailed(String)
    case disconnected(String)
    case invalidRequest(String)
    case protocolViolation(String)
    case server(code: String, message: String)
    case resyncRequired(String)
    case staleAttachment
    case timedOut(String)
    case unavailable(String)
}

extension BrokerClientError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "The terminal broker is not connected."
        case let .helperMissing(path):
            return "The bundled terminal broker is missing at \(path)."
        case let .connectFailed(message), let .disconnected(message):
            return message
        case let .invalidRequest(message), let .protocolViolation(message):
            return message
        case let .server(code, message):
            return "Terminal broker error \(code): \(message)"
        case let .resyncRequired(message):
            return "Terminal state must be resynchronized: \(message)"
        case .staleAttachment:
            return "This terminal attachment belongs to an older broker connection."
        case let .timedOut(operation):
            return "Terminal broker operation \(operation) timed out."
        case let .unavailable(message):
            return message
        }
    }
}

final class BrokerClient {
    static let protocolVersion = 4
    static let maximumChunkBytes = 64 * 1_024

    var onReconnect: ((BrokerHello) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var onExit: ((String, Int32?) -> Void)?
    var onResyncRequired: ((String, Error) -> Void)?
    var onCompatibilityMode: ((String) -> Void)?

    var socketURL: URL { protocolMode == .orderedV4 ? v4SocketURL : legacyV3SocketURL }

    private typealias JSONObject = [String: Any]
    private typealias ReplyHandler = (Result<JSONObject, Error>) -> Void

    private struct RecoveryAssembly {
        let requestID: UInt64
        let terminal: BrokerTerminalSummary
        let recoveryID: String
        let cutoverStateSequence: UInt64
        let totalBytes: Int
        let chunkCount: Int
        let digest: String
        let manifest: BrokerRecoveryManifest
        let completion: (Result<BrokerPreparedRecovery, Error>) -> Void
        var nextChunkIndex = 0
        var bytes = Data()
    }

    private struct CommitState {
        let requestID: UInt64
        let prepared: BrokerPreparedRecovery
        let eventHandler: (BrokerStateEvent) -> Void
        let completion: (Result<BrokerAttachment, Error>) -> Void
        var nextSequence: UInt64
        var events: [BrokerStateEvent] = []
        var retainedEventBytes = 0
    }

    private struct ActiveAttachment {
        var attachment: BrokerAttachment
        var lastSequence: UInt64
        let eventHandler: (BrokerStateEvent) -> Void
        var pendingEvents = BoundedEventQueue<BrokerStateEvent>(
            capacity: BrokerClient.maximumAttachmentEventBytes
        )
        var inFlightEventBytes = 0
        var deliveryScheduled = false
        let deliveryToken = BrokerDeliveryToken()
    }

    private struct PendingDetachDelivery {
        let attachment: BrokerAttachment
        let result: Result<JSONObject, Error>
        let completion: (Result<BrokerDetachReceipt, Error>) -> Void
    }

    private struct NormalizedInputState {
        let connectionID: UUID
        let brokerGeneration: UInt64
        let inputEpoch: UInt64
        let leaseID: String
        var nextSequence: UInt64 = 1
        var inFlight: (sequence: UInt64, digest: String)?
        var outcomeIsAmbiguous = false
    }

    private struct RecoveryContext {
        let recoveryID: String
        let terminalID: String
        let brokerGeneration: UInt64
    }

    private struct PendingTerminalRecovery {
        let connectionID: UUID
        let deadline: DispatchTime
        var ignoredStateEvents: Int
    }

    private struct PendingPrepareRequest {
        let requestID: UInt64
        let terminalID: String
        let completion: (Result<BrokerPreparedRecovery, Error>) -> Void
        var cancellationReason: String?
        var cancellationDelivered: Bool
    }

    private struct LegacyAuthority {
        let terminal: BrokerTerminalSummary
        let inputEpoch: UInt64
        let leaseID: String
    }

    private enum ProtocolMode {
        case orderedV4
        case legacyV3

        var version: Int { self == .orderedV4 ? 4 : 3 }
        var helperName: String { self == .orderedV4 ? "ouro-broker-v4" : "ouro-broker" }
    }

    private static let maximumWireLineBytes = 256 * 1_024
    private static let maximumQueuedWriteBytes = 2 * 1_024 * 1_024
    private static let maximumAttachmentEventBytes = 256 * 1_024
    private static let maximumRetainedEventBytes = 2 * 1_024 * 1_024
    private static let maximumDeliveryBatchBytes = 64 * 1_024
    private static let maximumDeliveryBatchEvents = 32
    private static let stateEventAccountingOverhead = 256
    private static let maximumIgnoredRecoveries = 64
    private static let maximumIgnoredStateEvents = 64
    private static let maximumDetachedBoundaries = 64
    private static let maximumRecoveryBytes = 16 * 1_024 * 1_024
    private static let ignoredRecoverySeconds: TimeInterval = 10
    private static let pendingTerminalSeconds: TimeInterval = 10
    private static let retryDelays: [TimeInterval] = [0.025, 0.05, 0.1, 0.2, 0.4, 0.8]

    private let ioQueue = DispatchQueue(label: "com.ourolabs.ourocode.broker-v4")
    private let v4SocketURL: URL
    private let legacyV3SocketURL: URL
    private let orderedV4HelperName: String
    private var protocolMode = ProtocolMode.orderedV4
    private var socketFD: Int32 = -1
    private var kernelPeerPID: pid_t?
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var readBuffer = Data()
    private var writeQueue: [Data] = []
    private var writeOffset = 0
    private var queuedWriteBytes = 0
    private var nextRequestID: UInt64 = 1
    private var pendingReplies: [UInt64: ReplyHandler] = [:]
    private var startCompletions: [(Result<BrokerHello, Error>) -> Void] = []
    private var hello: BrokerHello?
    private var connectionID = UUID()
    private var connectionAttempt = 0
    private var spawnedInCycle = false
    private var started = false
    private var reconnectWorkItem: DispatchWorkItem?
    private var helloTimeoutWorkItem: DispatchWorkItem?
    private var brokerProcess: Process?
    private var recoveries: [String: RecoveryAssembly] = [:]
    private var preparedRecoveries: [String: BrokerPreparedRecovery] = [:]
    private var commits: [String: CommitState] = [:]
    private var attachments: [String: ActiveAttachment] = [:]
    private var retainedEventBytes = 0
    private var pendingDetachDeliveries: [String: PendingDetachDelivery] = [:]
    private var normalizedInputStates: [String: NormalizedInputState] = [:]
    private var detachingAttachments: [String: BrokerAttachment] = [:]
    private var detachedStateSequences: [String: UInt64] = [:]
    private var pendingPrepareRequests: [String: PendingPrepareRequest] = [:]
    private var legacyAuthorities: [String: LegacyAuthority] = [:]
    private var recoveryContexts: [String: RecoveryContext] = [:]
    private var ignoredRecoveries: [String: DispatchTime] = [:]
    private var pendingTerminalRecoveries: [String: PendingTerminalRecovery] = [:]

    init(
        socketURL: URL? = nil,
        legacySocketURL: URL? = nil,
        orderedV4HelperName: String = "ouro-broker-v4"
    ) {
        v4SocketURL = socketURL ?? Self.defaultSocketURL(version: 4)
        legacyV3SocketURL = legacySocketURL ?? Self.defaultSocketURL(version: 3)
        self.orderedV4HelperName = orderedV4HelperName
        ioQueue.setSpecific(key: Self.queueKey, value: Self.queueIdentity)
    }

    deinit {
        stop()
    }

    /// Queue-confined diagnostics for tests and memory telemetry. Reading the
    /// ledger through this method avoids racing the broker I/O queue.
    func flowControlSnapshot(
        completion: @escaping (BrokerFlowControlSnapshot) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let snapshot = BrokerFlowControlSnapshot(
                retainedEventBytes: self.retainedEventBytes,
                activeAttachments: self.attachments.count,
                scheduledDeliveries: self.attachments.values.reduce(into: 0) { count, active in
                    if active.deliveryScheduled { count += 1 }
                }
            )
            self.dispatchMain { completion(snapshot) }
        }
    }

    func start(completion: ((Result<BrokerHello, Error>) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if let completion {
                if let hello = self.hello {
                    self.dispatchMain { completion(.success(hello)) }
                } else {
                    self.startCompletions.append(completion)
                }
            }
            guard !self.started else { return }
            self.started = true
            self.connectionAttempt = 0
            self.spawnedInCycle = false
            do {
                try self.prepareSocketDirectory()
                self.tryConnect()
            } catch {
                self.finishStart(.failure(error))
                self.notifyDisconnect(error)
            }
        }
    }

    /// Explicit user-authorized compatibility path. It never runs as an
    /// automatic downgrade: callers must surface the v4 failure and reason
    /// before invoking it.
    func startLegacyCompatibility(completion: @escaping (Result<BrokerHello, Error>) -> Void) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.reconnectWorkItem?.cancel()
            self.helloTimeoutWorkItem?.cancel()
            self.closeSocket()
            self.failOutstanding(with: BrokerClientError.disconnected("Switching to explicit broker v3 compatibility mode."))
            self.protocolMode = .legacyV3
            self.startCompletions.append(completion)
            self.started = true
            self.connectionAttempt = 0
            self.spawnedInCycle = false
            do {
                try self.prepareSocketDirectory()
                self.tryConnect()
            } catch {
                self.finishStart(.failure(error))
            }
        }
    }

    func stop() {
        let work = { [weak self] in
            guard let self else { return }
            self.started = false
            self.reconnectWorkItem?.cancel()
            self.reconnectWorkItem = nil
            self.helloTimeoutWorkItem?.cancel()
            self.helloTimeoutWorkItem = nil
            self.closeSocket()
            self.failOutstanding(with: BrokerClientError.disconnected("Terminal broker client stopped."))
        }
        if DispatchQueue.getSpecific(key: queueKey) == queueIdentity {
            work()
        } else {
            ioQueue.sync(execute: work)
        }
    }

    /// An authority-moving operation such as detach can fail after the broker
    /// has observed the request but before its FIFO barrier reaches this
    /// client. The old lease is then ambiguous. Tear down the owning
    /// connection so the broker revokes every connection-scoped lease before
    /// any new attachment is recovered.
    func reconnectAfterAuthorityFailure(_ error: Error) {
        ioQueue.async { [weak self] in
            guard let self, self.started else { return }
            self.connectionFailed(error)
        }
    }

    func list(completion: @escaping (Result<[BrokerTerminalSummary], Error>) -> Void) {
        ioQueue.async { [weak self] in
            self?.sendRequest(operation: "list", fields: [:]) { result in
                let parsed = result.flatMap { object -> Result<[BrokerTerminalSummary], Error> in
                    do {
                        guard Self.string(object, "result") == "listed",
                              let values = object["terminals"] as? [Any] else {
                            throw BrokerClientError.protocolViolation("list reply is malformed")
                        }
                        return .success(try values.map(Self.parseTerminal))
                    } catch {
                        return .failure(error)
                    }
                }
                self?.dispatchMain { completion(parsed) }
            }
        }
    }

    func create(
        createNonce: String = UUID().uuidString,
        program: String,
        args: [String] = [],
        currentDirectory: String? = nil,
        environment: [String: String] = [:],
        columns: Int,
        rows: Int,
        completion: @escaping (Result<BrokerTerminalSummary, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard !program.isEmpty,
                  (1...Int(UInt16.max)).contains(columns),
                  (1...Int(UInt16.max)).contains(rows) else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.invalidRequest("Invalid terminal program or dimensions.")))
                }
                return
            }
            var fields: JSONObject = [
                "create_nonce": createNonce,
                "program": program,
                "args": args,
                "environment": environment,
                "columns": columns,
                "rows": rows
            ]
            if let currentDirectory {
                fields["current_directory"] = currentDirectory
            }
            self.sendRequest(operation: "create", fields: fields) { result in
                let parsed = result.flatMap { object -> Result<BrokerTerminalSummary, Error> in
                    do {
                        guard Self.string(object, "result") == "created",
                              let value = object["terminal"] else {
                            throw BrokerClientError.protocolViolation("create reply is malformed")
                        }
                        var terminal = try Self.parseTerminal(value)
                        if let stateSequence = Self.unsigned(object, "state_seq"),
                           terminal.stateSequence != stateSequence {
                            terminal = Self.replacingSequence(of: terminal, with: stateSequence)
                        }
                        return .success(terminal)
                    } catch {
                        return .failure(error)
                    }
                }
                self.dispatchMain { completion(parsed) }
            }
        }
    }

    /// Begins a recovery transaction. The returned checkpoint is verified but
    /// not yet committed. Import it into an offscreen renderer first.
    func prepareAttachment(
        terminalID: String,
        afterStateSequence: UInt64? = nil,
        completion: @escaping (Result<BrokerPreparedRecovery, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard let hello = self.hello else {
                self.dispatchMain { completion(.failure(BrokerClientError.notConnected)) }
                return
            }
            if self.protocolMode == .legacyV3 {
                self.prepareLegacyAttachment(
                    terminalID: terminalID,
                    generation: hello.generation,
                    completion: completion
                )
                return
            }
            guard self.detachingAttachments[terminalID] == nil else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("Wait for the current detach barrier before recovering this terminal.")))
                }
                return
            }
            guard self.pendingPrepareRequests[terminalID] == nil else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("A recovery request for this terminal is already pending.")))
                }
                return
            }
            // Stop local authority before the request enters the socket. Old
            // state already queued ahead of recovery_begin is now bounded-
            // ignored instead of escalating to a connection-wide failure.
            self.removeAttachment(terminalID: terminalID)
            self.normalizedInputStates.removeValue(forKey: terminalID)
            self.markTerminalRecoveryPending(terminalID)
            var fields: JSONObject = [
                "terminal_id": terminalID,
                "broker_generation": hello.generation
            ]
            if let afterStateSequence {
                fields["after_state_seq"] = afterStateSequence
            }
            let requestID = self.sendRequest(operation: "attach_prepare", fields: fields) { [weak self] result in
                self?.finishPrepareReply(
                    terminalID: terminalID,
                    result: result,
                    fallbackCompletion: completion
                )
            }
            if let requestID {
                self.pendingPrepareRequests[terminalID] = PendingPrepareRequest(
                    requestID: requestID,
                    terminalID: terminalID,
                    completion: completion,
                    cancellationReason: nil,
                    cancellationDelivered: false
                )
            }
        }
    }

    /// Cancels a prepare even when the broker has not revealed recovery_id.
    /// The request reply stays registered so a late recovery_begin can be
    /// identified, bounded-ignored, and immediately recovery_abort'ed.
    func cancelAttachmentPreparation(terminalID: String, reason: String) {
        ioQueue.async { [weak self] in
            guard let self, var pending = self.pendingPrepareRequests[terminalID] else { return }
            pending.cancellationReason = reason
            if !pending.cancellationDelivered {
                pending.cancellationDelivered = true
                let error = BrokerClientError.unavailable("Attachment preparation cancelled: \(reason)")
                self.dispatchMain { pending.completion(.failure(error)) }
            }
            self.pendingPrepareRequests[terminalID] = pending
        }
    }

    /// Commits only after an offscreen renderer accepted the checkpoint. The
    /// completion contains every ordered catch-up event to apply before the UI
    /// atomically swaps the selected renderer.
    func commitAttachment(
        _ prepared: BrokerPreparedRecovery,
        onEvent: @escaping (BrokerStateEvent) -> Void,
        completion: @escaping (Result<BrokerAttachment, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            if self.protocolMode == .legacyV3 {
                self.commitLegacyAttachment(prepared, onEvent: onEvent, completion: completion)
                return
            }
            guard prepared.connectionID == self.connectionID,
                  prepared.brokerGeneration == self.hello?.generation,
                  self.preparedRecoveries[prepared.recoveryID] != nil else {
                self.dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
                return
            }
            let fields: JSONObject = [
                "recovery_id": prepared.recoveryID,
                "terminal_id": prepared.terminal.id,
                "broker_generation": prepared.brokerGeneration,
                "cutover_state_seq": prepared.cutoverStateSequence,
                "digest": prepared.digest
            ]
            var requestID: UInt64 = 0
            guard let sentID = self.sendRequest(operation: "recovery_commit", fields: fields, completion: { [weak self] result in
                self?.finishCommit(recoveryID: prepared.recoveryID, result: result)
            }) else {
                self.dispatchMain { completion(.failure(BrokerClientError.notConnected)) }
                return
            }
            requestID = sentID
            self.commits[prepared.recoveryID] = CommitState(
                requestID: requestID,
                prepared: prepared,
                eventHandler: onEvent,
                completion: completion,
                nextSequence: prepared.cutoverStateSequence + 1
            )
        }
    }

    /// Releases a prepared checkpoint that the renderer declined to import.
    /// This is best-effort because a concurrent broker failure may already have
    /// released the pin. Local authority is revoked synchronously on ioQueue.
    func abortRecovery(_ prepared: BrokerPreparedRecovery, reason: String) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard prepared.connectionID == self.connectionID else { return }
            let error = BrokerClientError.resyncRequired(reason)
            self.abortRecoveryLocally(prepared.recoveryID, error: error, notifyCompletion: true)
            self.sendRecoveryAbort(
                RecoveryContext(
                    recoveryID: prepared.recoveryID,
                    terminalID: prepared.terminal.id,
                    brokerGeneration: prepared.brokerGeneration
                )
            )
        }
    }

    func input(
        _ data: Data,
        using attachment: BrokerAttachment,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard !data.isEmpty, data.count <= Self.maximumChunkBytes else {
                self.dispatchMain {
                    completion?(.failure(BrokerClientError.invalidRequest("Input must be between 1 and 65536 bytes.")))
                }
                return
            }
            if self.protocolMode == .orderedV4,
               self.hello?.capabilities.contains("terminal.input.normalized.v1") == true {
                self.dispatchMain {
                    completion?(.failure(BrokerClientError.unavailable("Raw PTY input is disabled for terminal.input.normalized.v1.")))
                }
                return
            }
            self.mutate(using: attachment, operation: "input", extra: ["data": data.base64EncodedString()], completion: completion)
        }
    }

    /// Sends one immutable, mode-aware input event. Each attachment starts at
    /// sequence 1 and permits one request in flight. Explicit broker rejection
    /// does not advance the sequence, so a caller may retry the same event with
    /// byte-identical authority and digest fields. A transport failure is
    /// ambiguous and is never replayed onto a later attachment/epoch.
    func normalizedInput(
        _ event: NormalizedTerminalInputEvent,
        using attachment: BrokerAttachment,
        completion: @escaping (Result<NormalizedTerminalInputReceipt, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let terminalID = attachment.terminal.id
            guard self.protocolMode == .orderedV4,
                  self.hello?.capabilities.contains("terminal.input.normalized.v1") == true else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("The broker does not advertise terminal.input.normalized.v1.")))
                }
                return
            }
            if event.isPointerEvent,
               self.hello?.capabilities.contains("terminal.pointer.disposition.v1") != true {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable(
                        "The broker does not advertise terminal.pointer.disposition.v1.")))
                }
                return
            }
            guard attachment.connectionID == self.connectionID,
                  attachment.brokerGeneration == self.hello?.generation,
                  self.detachingAttachments[terminalID] == nil,
                  let active = self.attachments[terminalID],
                  Self.sameLease(active.attachment, attachment),
                  var state = self.normalizedInputStates[terminalID],
                  state.connectionID == attachment.connectionID,
                  state.brokerGeneration == attachment.brokerGeneration,
                  state.inputEpoch == attachment.inputEpoch,
                  state.leaseID == attachment.leaseID,
                  !state.outcomeIsAmbiguous else {
                self.dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
                return
            }
            guard state.inFlight == nil else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("A normalized input receipt is already pending for this attachment.")))
                }
                return
            }
            guard state.nextSequence != 0, state.nextSequence != UInt64.max else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("The normalized input sequence is exhausted; recover a fresh attachment.")))
                }
                return
            }
            do {
                let wireEvent = try event.validatedWireObject()
                let digest = try event.digestV1()
                let sequence = state.nextSequence
                let fields: JSONObject = [
                    "terminal_id": terminalID,
                    "broker_generation": attachment.brokerGeneration,
                    "input_epoch": attachment.inputEpoch,
                    "input_seq": sequence,
                    "lease_id": attachment.leaseID,
                    "event_digest": digest,
                    "event": wireEvent
                ]
                try self.preflightRequest(operation: "normalized_input", fields: fields)
                state.inFlight = (sequence, digest)
                self.normalizedInputStates[terminalID] = state
                self.sendRequest(operation: "normalized_input", fields: fields) { [weak self] result in
                    self?.finishNormalizedInput(
                        terminalID: terminalID,
                        attachment: attachment,
                        sequence: sequence,
                        digest: digest,
                        event: event,
                        result: result,
                        completion: completion
                    )
                }
            } catch {
                self.dispatchMain { completion(.failure(error)) }
            }
        }
    }

    func resize(
        columns: Int,
        rows: Int,
        cellWidthPixels: Int,
        cellHeightPixels: Int,
        layoutEpoch: UInt64,
        using attachment: BrokerAttachment,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard (1...Int(UInt16.max)).contains(columns),
                  (1...Int(UInt16.max)).contains(rows),
                  (1...Int(UInt16.max)).contains(cellWidthPixels),
                  (1...Int(UInt16.max)).contains(cellHeightPixels) else {
                self.dispatchMain { completion?(.failure(BrokerClientError.invalidRequest("Invalid terminal dimensions."))) }
                return
            }
            self.mutate(
                using: attachment,
                operation: "resize",
                extra: [
                    "columns": columns,
                    "rows": rows,
                    "cell_width_px": cellWidthPixels,
                    "cell_height_px": cellHeightPixels,
                    "layout_epoch": layoutEpoch
                ],
                completion: completion
            )
        }
    }

    /// Releases this renderer subscription and its lease without terminating
    /// the broker-owned PTY. Events already queued for the attachment are
    /// delivered before completion; the broker promises that none follow it.
    /// Protocol v3 has no equivalent ordering barrier and is rejected rather
    /// than pretending that a local renderer release detached the broker.
    func detach(
        _ attachment: BrokerAttachment,
        completion: @escaping (Result<BrokerDetachReceipt, Error>) -> Void
    ) {
        ioQueue.async { [weak self] in
            guard let self else { return }
            guard self.protocolMode == .orderedV4 else {
                self.dispatchMain {
                    completion(.failure(BrokerClientError.unavailable("Lease-aware detach requires broker v4; explicit v3 compatibility cannot detach safely.")))
                }
                return
            }
            let terminalID = attachment.terminal.id
            guard attachment.connectionID == self.connectionID,
                  attachment.brokerGeneration == self.hello?.generation,
                  let active = self.attachments[terminalID],
                  Self.sameLease(active.attachment, attachment),
                  self.detachingAttachments[terminalID] == nil else {
                self.dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
                return
            }

            // Keep the active event handler until the reply crosses the FIFO
            // barrier, but reject any new mutation as soon as detach begins.
            self.detachingAttachments[terminalID] = attachment
            let fields: JSONObject = [
                "terminal_id": terminalID,
                "broker_generation": attachment.brokerGeneration,
                "input_epoch": attachment.inputEpoch,
                "lease_id": attachment.leaseID
            ]
            guard self.sendRequest(operation: "detach", fields: fields, completion: { [weak self] result in
                self?.finishDetach(attachment, result: result, completion: completion)
            }) != nil else {
                self.detachingAttachments.removeValue(forKey: terminalID)
                return
            }
        }
    }

    func terminate(terminalID: String, completion: ((Result<Void, Error>) -> Void)? = nil) {
        ioQueue.async { [weak self] in
            guard let self, let generation = self.hello?.generation else {
                DispatchQueue.main.async { completion?(.failure(BrokerClientError.notConnected)) }
                return
            }
            self.sendAccepted(
                operation: "terminate",
                fields: ["terminal_id": terminalID, "broker_generation": generation],
                completion: completion
            )
        }
    }

    // MARK: - Connection

    private static let queueKey = DispatchSpecificKey<UInt8>()
    private static let queueIdentity: UInt8 = 1
    private var queueKey: DispatchSpecificKey<UInt8> { Self.queueKey }
    private var queueIdentity: UInt8 { Self.queueIdentity }

    private static func defaultSocketURL(version: Int) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Ourocode", isDirectory: true)
            .appendingPathComponent("broker-v\(version).sock", isDirectory: false)
    }

    private func prepareSocketDirectory() throws {
        let directory = socketURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func tryConnect() {
        guard started else { return }
        reconnectWorkItem = nil
        do {
            let fd = try openUnixSocket(path: socketURL.path)
            do {
                let peerPID = try verifiedPeerPID(fd: fd)
                installSocket(fd, peerPID: peerPID)
            } catch {
                Darwin.close(fd)
                throw error
            }
        } catch {
            if !spawnedInCycle {
                do {
                    try launchBundledBroker()
                    spawnedInCycle = true
                    scheduleConnect(after: Self.retryDelays[0])
                } catch {
                    finishStart(.failure(error))
                    notifyDisconnect(error)
                    scheduleNewConnectCycle()
                }
                return
            }
            guard connectionAttempt < Self.retryDelays.count else {
                let failure = BrokerClientError.connectFailed("Unable to connect to the terminal broker at \(socketURL.path).")
                finishStart(.failure(failure))
                notifyDisconnect(failure)
                scheduleNewConnectCycle()
                return
            }
            let delay = Self.retryDelays[connectionAttempt]
            connectionAttempt += 1
            scheduleConnect(after: delay)
        }
    }

    private func scheduleConnect(after delay: TimeInterval) {
        let item = DispatchWorkItem { [weak self] in self?.tryConnect() }
        reconnectWorkItem?.cancel()
        reconnectWorkItem = item
        ioQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func scheduleNewConnectCycle() {
        guard started else { return }
        connectionAttempt = 0
        spawnedInCycle = true // Never create a helper storm while one may be starting.
        scheduleConnect(after: 2)
    }

    private func openUnixSocket(path: String) throws -> Int32 {
        let bytes = Array(path.utf8CString)
        var address = sockaddr_un()
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw BrokerClientError.connectFailed("Terminal broker socket path is too long.")
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &address.sun_path) { destination in
            path.withCString { source in
                memcpy(destination, source, bytes.count)
            }
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw BrokerClientError.connectFailed(String(cString: strerror(errno)))
        }
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw BrokerClientError.connectFailed(message)
        }
        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            Darwin.close(fd)
            throw BrokerClientError.connectFailed(message)
        }
        return fd
    }

    /// Kernel peer credentials are the minimum admission fence for every
    /// local broker connection. They do not grant mutation authority by
    /// themselves, but an unverified peer must never reach protocol parsing.
    private func verifiedPeerPID(fd: Int32) throws -> pid_t {
        var peerUID = uid_t.max
        var peerGID = gid_t.max
        guard getpeereid(fd, &peerUID, &peerGID) == 0 else {
            throw BrokerClientError.connectFailed("Unable to verify terminal broker peer credentials.")
        }
        guard peerUID == geteuid() else {
            throw BrokerClientError.connectFailed("Terminal broker peer belongs to another user.")
        }

        var peerPID: pid_t = 0
        var peerPIDSize = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &peerPIDSize) == 0,
              peerPIDSize == MemoryLayout<pid_t>.size,
              peerPID > 0 else {
            throw BrokerClientError.connectFailed("Unable to verify terminal broker peer process.")
        }
        if let expected = try expectedBuildNamedHelper() {
            // proc_pidpath recommends a 4 * MAXPATHLEN buffer; the macro is
            // not imported by Swift because it expands through C structure
            // constants.
            var executablePath = [CChar](repeating: 0, count: 4_096)
            let pathLength = proc_pidpath(peerPID, &executablePath, UInt32(executablePath.count))
            guard pathLength > 0 else {
                throw BrokerClientError.connectFailed(
                    "Unable to verify the build-namespaced terminal broker executable."
                )
            }
            let actualURL = URL(fileURLWithPath: String(cString: executablePath))
                .resolvingSymlinksInPath().standardizedFileURL
            guard actualURL == expected.url.resolvingSymlinksInPath().standardizedFileURL else {
                throw BrokerClientError.connectFailed(
                    "Terminal broker executable does not match this app's build namespace."
                )
            }
        }
        return peerPID
    }

    private func expectedBuildNamedHelper() throws -> (url: URL, buildID: String)? {
        guard protocolMode == .orderedV4,
              orderedV4HelperName.hasPrefix("ouro-broker-v4-ghostty-") else { return nil }
        let buildID = String(orderedV4HelperName.suffix(16))
        guard orderedV4HelperName.count > 16,
              orderedV4HelperName[orderedV4HelperName.index(
                orderedV4HelperName.endIndex,
                offsetBy: -17
              )] == "-",
              buildID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(orderedV4HelperName, isDirectory: false)
        guard let bytes = try? Data(contentsOf: helperURL, options: [.mappedIfSafe]) else {
            throw BrokerClientError.helperMissing(helperURL.path)
        }
        let actualBuildID = SHA256.hash(data: bytes).prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualBuildID == buildID else {
            throw BrokerClientError.connectFailed(
                "Packaged terminal broker bytes do not match their build namespace."
            )
        }
        return (helperURL, buildID)
    }

    private func launchBundledBroker() throws {
        let helperName = protocolMode == .orderedV4
            ? orderedV4HelperName
            : protocolMode.helperName
        let helper = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(helperName, isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw BrokerClientError.helperMissing(helper.path)
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = [socketURL.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        brokerProcess = process
    }

    private func installSocket(_ fd: Int32, peerPID: pid_t) {
        closeSocket()
        socketFD = fd
        kernelPeerPID = peerPID
        connectionID = UUID()
        connectionAttempt = 0
        readBuffer.removeAll(keepingCapacity: true)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler {}
        readSource = source
        source.resume()

        let timeout = DispatchWorkItem { [weak self] in
            guard let self, self.hello == nil, self.socketFD == fd else { return }
            self.connectionFailed(BrokerClientError.protocolViolation("Terminal broker did not send a v4 hello."))
        }
        helloTimeoutWorkItem = timeout
        ioQueue.asyncAfter(deadline: .now() + 2, execute: timeout)
    }

    private func closeSocket() {
        readSource?.cancel()
        readSource = nil
        writeSource?.cancel()
        writeSource = nil
        if socketFD >= 0 {
            Darwin.close(socketFD)
            socketFD = -1
        }
        kernelPeerPID = nil
        hello = nil
        readBuffer.removeAll(keepingCapacity: false)
        writeQueue.removeAll(keepingCapacity: false)
        writeOffset = 0
        queuedWriteBytes = 0
    }

    private func connectionFailed(_ error: Error) {
        let wasConnected = hello != nil
        let wasStarting = !startCompletions.isEmpty
        closeSocket()
        failOutstanding(with: error)
        if wasStarting {
            finishStart(.failure(error))
        }
        if wasConnected || wasStarting {
            notifyDisconnect(error)
        }
        guard started else { return }
        connectionAttempt = 0
        spawnedInCycle = true
        scheduleConnect(after: 0.1)
    }

    // MARK: - Framing

    private func readAvailable() {
        var scratch = [UInt8](repeating: 0, count: 32 * 1_024)
        while socketFD >= 0 {
            let count = Darwin.read(socketFD, &scratch, scratch.count)
            if count > 0 {
                readBuffer.append(contentsOf: scratch.prefix(count))
                if readBuffer.count > Self.maximumWireLineBytes,
                   !readBuffer.contains(0x0A) {
                    connectionFailed(BrokerClientError.protocolViolation("Terminal broker frame exceeded the bounded line size."))
                    return
                }
                consumeLines()
            } else if count == 0 {
                connectionFailed(BrokerClientError.disconnected("Terminal broker closed the connection."))
                return
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                connectionFailed(BrokerClientError.disconnected(String(cString: strerror(errno))))
                return
            }
        }
    }

    private func consumeLines() {
        while let newline = readBuffer.firstIndex(of: 0x0A) {
            let line = Data(readBuffer[..<newline])
            readBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard line.count <= Self.maximumWireLineBytes else {
                connectionFailed(BrokerClientError.protocolViolation("Terminal broker frame exceeded the bounded line size."))
                return
            }
            do {
                guard let object = try JSONSerialization.jsonObject(with: line) as? JSONObject else {
                    throw BrokerClientError.protocolViolation("Terminal broker sent a non-object JSON frame.")
                }
                try handle(object)
            } catch {
                connectionFailed(error)
                return
            }
        }
    }

    private func enqueue(_ object: JSONObject) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)
        guard queuedWriteBytes + data.count <= Self.maximumQueuedWriteBytes else {
            throw BrokerClientError.protocolViolation("Terminal broker write queue exceeded its memory bound.")
        }
        queuedWriteBytes += data.count
        writeQueue.append(data)
        flushWrites()
    }

    private func flushWrites() {
        while socketFD >= 0, let data = writeQueue.first {
            let result = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return Darwin.write(socketFD, base.advanced(by: writeOffset), data.count - writeOffset)
            }
            if result > 0 {
                writeOffset += result
                queuedWriteBytes -= result
                if writeOffset == data.count {
                    writeQueue.removeFirst()
                    writeOffset = 0
                }
            } else if result < 0, errno == EINTR {
                continue
            } else if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                installWriteSource()
                return
            } else {
                connectionFailed(BrokerClientError.disconnected("Unable to write to the terminal broker."))
                return
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    private func installWriteSource() {
        guard writeSource == nil, socketFD >= 0 else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: socketFD, queue: ioQueue)
        source.setEventHandler { [weak self] in self?.flushWrites() }
        source.setCancelHandler {}
        writeSource = source
        source.resume()
    }

    // MARK: - Protocol

    @discardableResult
    private func sendRequest(operation: String, fields: JSONObject, completion: @escaping ReplyHandler) -> UInt64? {
        guard hello != nil, socketFD >= 0 else {
            completion(.failure(BrokerClientError.notConnected))
            return nil
        }
        let id = nextRequestID
        nextRequestID &+= 1
        var object: JSONObject = ["version": protocolMode.version, "id": id, "op": operation]
        fields.forEach { object[$0] = $1 }
        pendingReplies[id] = completion
        do {
            try enqueue(object)
            return id
        } catch {
            pendingReplies.removeValue(forKey: id)
            completion(.failure(error))
            return nil
        }
    }

    private func preflightRequest(operation: String, fields: JSONObject) throws {
        var object: JSONObject = [
            "version": protocolMode.version,
            "id": nextRequestID,
            "op": operation
        ]
        fields.forEach { object[$0] = $1 }
        guard JSONSerialization.isValidJSONObject(object) else {
            throw BrokerClientError.invalidRequest("Normalized terminal input cannot be represented on the broker wire.")
        }
        let bytes = try JSONSerialization.data(withJSONObject: object, options: []).count + 1
        guard bytes <= Self.maximumWireLineBytes else {
            throw BrokerClientError.invalidRequest("Normalized terminal input exceeds the bounded broker frame size.")
        }
        guard bytes <= Self.maximumQueuedWriteBytes - min(queuedWriteBytes, Self.maximumQueuedWriteBytes) else {
            throw BrokerClientError.unavailable("The terminal broker write queue cannot accept this input yet.")
        }
    }

    private func handle(_ object: JSONObject) throws {
        guard Self.integer(object, "version") == protocolMode.version else {
            throw BrokerClientError.protocolViolation("Terminal broker protocol does not match the selected mode.")
        }
        guard let type = Self.string(object, "type") else {
            throw BrokerClientError.protocolViolation("Terminal broker message has no type.")
        }
        if type == "hello" {
            try handleHello(object)
            return
        }
        guard let hello else {
            throw BrokerClientError.protocolViolation("Terminal broker sent data before hello.")
        }
        guard Self.unsigned(object, "broker_generation") == hello.generation else {
            throw BrokerClientError.resyncRequired("Broker generation changed on an active connection.")
        }
        switch type {
        case "reply":
            guard let id = Self.unsigned(object, "id"), let handler = pendingReplies.removeValue(forKey: id) else {
                throw BrokerClientError.protocolViolation("Terminal broker replied to an unknown request.")
            }
            handler(.success(object))
        case "error":
            let id = Self.unsigned(object, "id") ?? 0
            let code = Self.string(object, "code") ?? "unknown"
            let message = Self.string(object, "message") ?? "Unknown broker error"
            let error: Error = code == "resync_required"
                ? BrokerClientError.resyncRequired(message)
                : BrokerClientError.server(code: code, message: message)
            if let handler = pendingReplies.removeValue(forKey: id) {
                handler(.failure(error))
            } else if code == "resync_required" {
                throw error
            }
        case "recovery_chunk":
            try handleRecoveryChunk(object)
        case "recovery_end":
            try handleRecoveryEnd(object)
        case "recovery_delta":
            try handleRecoveryDelta(object)
        case "state_event":
            try handleLiveEvent(object)
        case "output" where protocolMode == .legacyV3:
            try handleLegacyOutput(object)
        case "exited":
            let terminalID = try Self.requiredString(object, "terminal_id")
            let status = Self.integer(object, "status").map(Int32.init)
            removeAttachment(terminalID: terminalID)
            normalizedInputStates.removeValue(forKey: terminalID)
            dispatchMain { [weak self] in self?.onExit?(terminalID, status) }
        default:
            throw BrokerClientError.protocolViolation("Unknown terminal broker message type \(type).")
        }
    }

    private func handleHello(_ object: JSONObject) throws {
        if protocolMode == .legacyV3 {
            guard hello == nil,
                  let generation = Self.unsigned(object, "broker_generation"),
                  let pidValue = Self.unsigned(object, "pid"),
                  pidValue <= UInt64(pid_t.max),
                  let build = Self.string(object, "build"),
                  let values = object["capabilities"] as? [String] else {
                throw BrokerClientError.protocolViolation("Terminal broker v3 hello is malformed.")
            }
            let value = BrokerHello(
                generation: generation,
                pid: UInt32(pidValue),
                build: build,
                capabilities: Set(values),
                manifest: nil,
                sessionMessageGateway: nil
            )
            guard pid_t(pidValue) == kernelPeerPID else {
                throw BrokerClientError.protocolViolation(
                    "Terminal broker v3 hello PID disagrees with the kernel peer identity."
                )
            }
            hello = value
            helloTimeoutWorkItem?.cancel()
            helloTimeoutWorkItem = nil
            finishStart(.success(value))
            dispatchMain { [weak self] in
                self?.onCompatibilityMode?("Broker v4 was unavailable; using explicitly approved broker v3 ANSI compatibility mode.")
                self?.onReconnect?(value)
            }
            return
        }
        guard hello == nil,
              let generation = Self.unsigned(object, "broker_generation"),
              let pidValue = Self.unsigned(object, "pid"),
              pidValue <= UInt64(pid_t.max),
              let build = Self.string(object, "build"),
              let values = object["capabilities"] as? [String],
              let manifestValue = object["manifest"] as? JSONObject else {
            throw BrokerClientError.protocolViolation("Terminal broker v4 hello is malformed.")
        }
        let capabilities = Set(values)
        guard capabilities.contains("terminal.state.ordered.v4"),
              capabilities.contains("terminal.recovery.two_phase.v4"),
              capabilities.contains("terminal.detach.lease.v4") else {
            throw BrokerClientError.protocolViolation("Terminal broker lacks mandatory v4 recovery capabilities.")
        }
        let manifest = try Self.parseManifest(manifestValue)
        try Self.validateManifest(manifest)
        let sessionMessageGateway = try SessionMessageGatewayDescriptorV1.decode(
            object["session_message_gateway"],
            terminalBrokerGeneration: generation
        )
        let value = BrokerHello(
            generation: generation,
            pid: UInt32(pidValue),
            build: build,
            capabilities: capabilities,
            manifest: manifest,
            sessionMessageGateway: sessionMessageGateway
        )
        guard pid_t(pidValue) == kernelPeerPID else {
            throw BrokerClientError.protocolViolation(
                "Terminal broker v4 hello PID disagrees with the kernel peer identity."
            )
        }
        hello = value
        helloTimeoutWorkItem?.cancel()
        helloTimeoutWorkItem = nil
        finishStart(.success(value))
        dispatchMain { [weak self] in self?.onReconnect?(value) }
    }

    private func beginRecovery(
        requestID: UInt64,
        object: JSONObject,
        completion: @escaping (Result<BrokerPreparedRecovery, Error>) -> Void
    ) throws {
        guard Self.string(object, "result") == "recovery_begin",
              let recoveryID = Self.string(object, "recovery_id"),
              let terminalValue = object["terminal"],
              let terminalObject = terminalValue as? JSONObject,
              let terminalID = Self.string(terminalObject, "id"),
              let generation = hello?.generation else {
            throw BrokerClientError.protocolViolation("attach_prepare reply is malformed.")
        }
        let context = RecoveryContext(
            recoveryID: recoveryID,
            terminalID: terminalID,
            brokerGeneration: generation
        )
        // Once these identity fields exist, every remaining rejection owns an
        // immediate abort path; malformed size/chunk metadata cannot leak a pin
        // until the broker TTL expires.
        recoveryContexts[recoveryID] = context
        removeAttachment(terminalID: terminalID)
        markTerminalRecoveryPending(terminalID)

        do {
            guard let manifestValue = object["manifest"] as? JSONObject,
                  let cutover = Self.unsigned(object, "cutover_state_seq"),
                  let totalValue = Self.unsigned(object, "total_bytes"),
                  let countValue = Self.unsigned(object, "chunk_count"),
                  let digest = Self.string(object, "digest") else {
                throw BrokerClientError.protocolViolation("recovery_begin fields are malformed.")
            }
            let manifest = try Self.parseManifest(manifestValue)
            let terminal = try Self.parseTerminal(terminalValue)
            let digestHex = digest.dropFirst("sha256:".count)
            let validManifest = manifest.protocolVersion == UInt64(Self.protocolVersion)
                && manifest == hello?.manifest
                && manifest.maximumChunkBytes == UInt64(Self.maximumChunkBytes)
                && manifest.compression == "none"
                && totalValue <= manifest.maximumSnapshotBytes
                && totalValue <= manifest.maximumRecoveryPinnedBytes
                && totalValue <= UInt64(Self.maximumRecoveryBytes)
                && countValue <= UInt64(Int.max)
                && digest.hasPrefix("sha256:")
                && digest.count == 71
                && digestHex.allSatisfy { $0.isHexDigit && !$0.isUppercase }
                && recoveries[recoveryID] == nil
            guard validManifest else {
                throw BrokerClientError.resyncRequired("Recovery manifest violates the negotiated v4 bounds.")
            }
            let total = Int(totalValue)
            let count = Int(countValue)
            let expectedChunks = total == 0
                ? 0
                : (total + Self.maximumChunkBytes - 1) / Self.maximumChunkBytes
            guard count == expectedChunks else {
                throw BrokerClientError.resyncRequired("Recovery chunk count does not match total_bytes.")
            }
            var assembly = RecoveryAssembly(
                requestID: requestID,
                terminal: terminal,
                recoveryID: recoveryID,
                cutoverStateSequence: cutover,
                totalBytes: total,
                chunkCount: count,
                digest: digest,
                manifest: manifest,
                completion: completion
            )
            assembly.bytes.reserveCapacity(total)
            recoveries[recoveryID] = assembly
        } catch {
            rememberIgnoredRecovery(recoveryID)
            sendRecoveryAbort(context)
            throw error
        }
    }

    private func finishPrepareReply(
        terminalID: String,
        result: Result<JSONObject, Error>,
        fallbackCompletion: @escaping (Result<BrokerPreparedRecovery, Error>) -> Void
    ) {
        guard let pending = pendingPrepareRequests.removeValue(forKey: terminalID) else {
            // sendRequest can fail synchronously before its request ID is
            // installed in pendingPrepareRequests.
            if case let .failure(error) = result {
                dispatchMain { fallbackCompletion(.failure(error)) }
            }
            return
        }
        guard pending.cancellationReason == nil else {
            guard case let .success(object) = result else { return }
            do {
                guard Self.string(object, "result") == "recovery_begin",
                      let recoveryID = Self.string(object, "recovery_id"),
                      let terminal = object["terminal"] as? JSONObject,
                      Self.string(terminal, "id") == pending.terminalID,
                      let generation = hello?.generation else {
                    throw BrokerClientError.protocolViolation("Cancelled attach_prepare reply is malformed.")
                }
                let context = RecoveryContext(
                    recoveryID: recoveryID,
                    terminalID: pending.terminalID,
                    brokerGeneration: generation
                )
                recoveryContexts[recoveryID] = context
                rememberIgnoredRecovery(recoveryID)
                sendRecoveryAbort(context)
            } catch {
                // Without a trustworthy recovery identity there is no safe
                // targeted abort. Dropping the connection makes the broker
                // release every pin owned by this client incarnation.
                connectionFailed(error)
            }
            return
        }

        switch result {
        case let .failure(error):
            dispatchMain { pending.completion(.failure(error)) }
        case let .success(object):
            do {
                try beginRecovery(
                    requestID: pending.requestID,
                    object: object,
                    completion: pending.completion
                )
            } catch {
                dispatchMain { pending.completion(.failure(error)) }
            }
        }
    }

    private func handleRecoveryChunk(_ object: JSONObject) throws {
        let recoveryID = try Self.requiredString(object, "recovery_id")
        if shouldIgnoreRecovery(recoveryID) { return }
        guard var assembly = recoveries[recoveryID] else {
            throw BrokerClientError.protocolViolation("Recovery chunk referenced an unknown recovery ID.")
        }
        guard let index = Self.integer(object, "index"),
              index == assembly.nextChunkIndex,
              let encoded = Self.string(object, "data"),
              let bytes = Data(base64Encoded: encoded),
              bytes.count <= Self.maximumChunkBytes,
              assembly.bytes.count + bytes.count <= assembly.totalBytes else {
            failRecovery(recoveryID, reason: "Recovery chunks were missing, reordered, oversized, or invalid base64.")
            return
        }
        assembly.bytes.append(bytes)
        assembly.nextChunkIndex += 1
        recoveries[recoveryID] = assembly
    }

    private func handleRecoveryEnd(_ object: JSONObject) throws {
        let recoveryID = try Self.requiredString(object, "recovery_id")
        if shouldIgnoreRecovery(recoveryID) { return }
        guard let assembly = recoveries[recoveryID] else {
            throw BrokerClientError.protocolViolation("Recovery end referenced an unknown recovery ID.")
        }
        guard Self.string(object, "digest") == assembly.digest,
              assembly.nextChunkIndex == assembly.chunkCount,
              assembly.bytes.count == assembly.totalBytes else {
            failRecovery(recoveryID, reason: "Recovery ended before its declared snapshot was complete.")
            return
        }
        recoveries.removeValue(forKey: recoveryID)
        let computed = try Self.recoveryDigest(manifest: assembly.manifest, checkpoint: assembly.bytes)
        guard computed == assembly.digest else {
            let error = BrokerClientError.resyncRequired("Recovery checkpoint digest did not match its manifest.")
            dispatchMain { assembly.completion(.failure(error)) }
            if let context = recoveryContexts[recoveryID] {
                rememberIgnoredRecovery(recoveryID)
                sendRecoveryAbort(context)
                notifyResync(terminalID: context.terminalID, error: error)
            }
            return
        }
        guard let generation = hello?.generation else {
            dispatchMain { assembly.completion(.failure(BrokerClientError.notConnected)) }
            return
        }
        let prepared = BrokerPreparedRecovery(
            terminal: assembly.terminal,
            manifest: assembly.manifest,
            checkpoint: assembly.bytes,
            cutoverStateSequence: assembly.cutoverStateSequence,
            digest: assembly.digest,
            recoveryID: recoveryID,
            brokerGeneration: generation,
            connectionID: connectionID
        )
        preparedRecoveries[recoveryID] = prepared
        dispatchMain { assembly.completion(.success(prepared)) }
    }

    private func failRecovery(_ recoveryID: String, reason: String) {
        let error = BrokerClientError.resyncRequired(reason)
        if let assembly = recoveries.removeValue(forKey: recoveryID) {
            dispatchMain { assembly.completion(.failure(error)) }
        }
        if let context = recoveryContexts[recoveryID] {
            rememberIgnoredRecovery(recoveryID)
            sendRecoveryAbort(context)
            notifyResync(terminalID: context.terminalID, error: error)
        }
    }

    private func handleRecoveryDelta(_ object: JSONObject) throws {
        let recoveryID = try Self.requiredString(object, "recovery_id")
        if shouldIgnoreRecovery(recoveryID) { return }
        guard var commit = commits[recoveryID], let value = object["event"] as? JSONObject else {
            throw BrokerClientError.resyncRequired("Recovery delta arrived outside an active commit.")
        }
        let event = try Self.parseEvent(value)
        guard event.sequence == commit.nextSequence else {
            abortCommit(recoveryID, error: BrokerClientError.resyncRequired("Recovery delta sequence has a gap or conflict."))
            return
        }
        let cost = Self.deliveryCost(of: event)
        guard cost <= Self.maximumAttachmentEventBytes - commit.retainedEventBytes,
              cost <= Self.maximumRetainedEventBytes - retainedEventBytes else {
            abortCommit(
                recoveryID,
                error: BrokerClientError.resyncRequired("Recovery catch-up exceeded the bounded UI delivery mailbox.")
            )
            return
        }
        commit.events.append(event)
        commit.retainedEventBytes += cost
        retainedEventBytes += cost
        commit.nextSequence &+= 1
        commits[recoveryID] = commit
    }

    private func finishCommit(recoveryID: String, result: Result<JSONObject, Error>) {
        guard let commit = commits.removeValue(forKey: recoveryID) else { return }
        preparedRecoveries.removeValue(forKey: recoveryID)
        do {
            let object = try result.get()
            guard Self.string(object, "result") == "attached_ready",
                  let terminalValue = object["terminal"],
                  let stateSequence = Self.unsigned(object, "state_seq"),
                  let inputEpoch = Self.unsigned(object, "input_epoch"),
                  let leaseID = Self.string(object, "lease_id") else {
                throw BrokerClientError.protocolViolation("recovery_commit reply is malformed.")
            }
            var terminal = try Self.parseTerminal(terminalValue)
            guard stateSequence == commit.nextSequence - 1 else {
                throw BrokerClientError.resyncRequired("attached_ready skipped or duplicated recovery deltas.")
            }
            if terminal.stateSequence != stateSequence {
                terminal = BrokerTerminalSummary(
                    id: terminal.id,
                    createNonce: terminal.createNonce,
                    stateSequence: stateSequence,
                    columns: terminal.columns,
                    rows: terminal.rows,
                    layoutEpoch: terminal.layoutEpoch,
                    running: terminal.running,
                    foregroundProcess: terminal.foregroundProcess
                )
            }
            let attachment = BrokerAttachment(
                terminal: terminal,
                inputEpoch: inputEpoch,
                leaseID: leaseID,
                brokerGeneration: commit.prepared.brokerGeneration,
                connectionID: commit.prepared.connectionID,
                catchUp: OneShotHandoff(commit.events)
            )
            // Catch-up belongs to the one-shot commit handoff. The active
            // authority retains only immutable lease identity; otherwise each
            // selected terminal would permanently pin its recovery payload
            // outside the live mailbox ledger.
            let activeAttachment = BrokerAttachment(
                terminal: terminal,
                inputEpoch: inputEpoch,
                leaseID: leaseID,
                brokerGeneration: commit.prepared.brokerGeneration,
                connectionID: commit.prepared.connectionID,
                catchUp: nil
            )
            replaceAttachment(terminalID: terminal.id, with: ActiveAttachment(
                attachment: activeAttachment,
                lastSequence: stateSequence,
                eventHandler: commit.eventHandler
            ))
            normalizedInputStates[terminal.id] = NormalizedInputState(
                connectionID: attachment.connectionID,
                brokerGeneration: attachment.brokerGeneration,
                inputEpoch: attachment.inputEpoch,
                leaseID: attachment.leaseID
            )
            detachedStateSequences.removeValue(forKey: terminal.id)
            recoveryContexts.removeValue(forKey: recoveryID)
            ignoredRecoveries.removeValue(forKey: recoveryID)
            pendingTerminalRecoveries.removeValue(forKey: terminal.id)
            dispatchMain { [weak self] in
                // The completion synchronously imports catch-up events into
                // the renderer. Keep their bytes charged until that handoff
                // returns; only then may the global mailbox budget be reused.
                commit.completion(.success(attachment))
                attachment.catchUp?.discard()
                self?.ioQueue.async { [weak self] in
                    self?.releaseRetainedEventBytes(commit.retainedEventBytes)
                }
            }
        } catch {
            releaseRetainedEventBytes(commit.retainedEventBytes)
            dispatchMain { commit.completion(.failure(error)) }
            notifyResync(terminalID: commit.prepared.terminal.id, error: error)
            let context = recoveryContexts[recoveryID] ?? RecoveryContext(
                recoveryID: recoveryID,
                terminalID: commit.prepared.terminal.id,
                brokerGeneration: commit.prepared.brokerGeneration
            )
            rememberIgnoredRecovery(recoveryID)
            sendRecoveryAbort(context)
        }
    }

    private func releaseRetainedEventBytes(_ count: Int) {
        guard count > 0 else { return }
        retainedEventBytes -= count
        precondition(retainedEventBytes >= 0)
    }

    private func abortCommit(_ recoveryID: String, error: Error) {
        guard let commit = commits.removeValue(forKey: recoveryID) else { return }
        retainedEventBytes -= commit.retainedEventBytes
        precondition(retainedEventBytes >= 0)
        preparedRecoveries.removeValue(forKey: recoveryID)
        pendingReplies.removeValue(forKey: commit.requestID)
        dispatchMain { commit.completion(.failure(error)) }
        notifyResync(terminalID: commit.prepared.terminal.id, error: error)
        let context = recoveryContexts[recoveryID] ?? RecoveryContext(
            recoveryID: recoveryID,
            terminalID: commit.prepared.terminal.id,
            brokerGeneration: commit.prepared.brokerGeneration
        )
        rememberIgnoredRecovery(recoveryID)
        sendRecoveryAbort(context)
    }

    private func handleLiveEvent(_ object: JSONObject) throws {
        let terminalID = try Self.requiredString(object, "terminal_id")
        guard let value = object["event"] as? JSONObject else {
            throw BrokerClientError.resyncRequired("Live state event is missing its typed payload.")
        }
        if let detachedSequence = detachedStateSequences[terminalID] {
            let event = try Self.parseEvent(value)
            throw BrokerClientError.resyncRequired(
                "Live state event \(event.sequence) arrived after detached barrier \(detachedSequence)."
            )
        }
        if var pending = pendingTerminalRecoveries[terminalID],
           pending.connectionID == connectionID {
            _ = try Self.parseEvent(value)
            guard DispatchTime.now() <= pending.deadline,
                  pending.ignoredStateEvents < Self.maximumIgnoredStateEvents else {
                pendingTerminalRecoveries.removeValue(forKey: terminalID)
                throw BrokerClientError.resyncRequired("Too many late state events arrived during terminal recovery.")
            }
            pending.ignoredStateEvents += 1
            pendingTerminalRecoveries[terminalID] = pending
            return
        }
        guard var active = attachments[terminalID] else {
            throw BrokerClientError.resyncRequired("Live state arrived before attached_ready.")
        }
        let event = try Self.parseEvent(value)
        guard event.sequence == active.lastSequence + 1 else {
            removeAttachment(terminalID: terminalID)
            normalizedInputStates.removeValue(forKey: terminalID)
            markTerminalRecoveryPending(terminalID)
            let error = BrokerClientError.resyncRequired("Live terminal state sequence has a gap or conflict.")
            notifyResync(terminalID: terminalID, error: error)
            return
        }
        guard enqueueLiveEvent(event, terminalID: terminalID, active: &active) else { return }
        active.lastSequence = event.sequence
        let shouldSchedule = !active.deliveryScheduled
        if shouldSchedule { active.deliveryScheduled = true }
        attachments[terminalID] = active
        if shouldSchedule {
            scheduleEventDelivery(terminalID: terminalID, token: active.deliveryToken)
        }
    }

    private func enqueueLiveEvent(
        _ event: BrokerStateEvent,
        terminalID: String,
        active: inout ActiveAttachment
    ) -> Bool {
        let cost = Self.deliveryCost(of: event)
        guard cost <= Self.maximumRetainedEventBytes - retainedEventBytes,
              active.pendingEvents.enqueue(event, cost: cost) else {
            removeAttachment(terminalID: terminalID)
            normalizedInputStates.removeValue(forKey: terminalID)
            markTerminalRecoveryPending(terminalID)
            let error = BrokerClientError.resyncRequired(
                "Terminal output exceeded the bounded UI delivery mailbox. Recover the attachment before continuing."
            )
            notifyResync(terminalID: terminalID, error: error)
            return false
        }
        retainedEventBytes += cost
        return true
    }

    private static func deliveryCost(of event: BrokerStateEvent) -> Int {
        switch event {
        case let .ptyBytes(_, data):
            return stateEventAccountingOverhead + data.count
        case .resize:
            return stateEventAccountingOverhead
        }
    }

    /// Maintains at most one main-queue delivery closure per attachment. A
    /// producer can fill the bounded mailbox while rendering is slow, but it
    /// cannot manufacture an unbounded number of retained Dispatch closures.
    private func scheduleEventDelivery(terminalID: String, token: BrokerDeliveryToken) {
        dispatchMain { [weak self, weak token] in
            guard let self, let token else { return }
            self.ioQueue.async { [weak self, weak token] in
                guard let self,
                      let token,
                      token.isValid,
                      var active = self.attachments[terminalID],
                      active.deliveryToken === token,
                      active.deliveryScheduled,
                      active.inFlightEventBytes == 0 else { return }

                let batch = active.pendingEvents.takeBatch(
                    maximumCount: Self.maximumDeliveryBatchEvents,
                    maximumBytes: Self.maximumDeliveryBatchBytes
                )
                guard !batch.elements.isEmpty else {
                    active.deliveryScheduled = false
                    self.attachments[terminalID] = active
                    self.finishDeferredDetachIfReady(terminalID: terminalID)
                    return
                }
                active.inFlightEventBytes = batch.retainedBytes
                let handler = active.eventHandler
                self.attachments[terminalID] = active

                self.dispatchMain { [weak self, weak token] in
                    guard let self, let token else { return }
                    if token.isValid {
                        batch.elements.forEach(handler)
                    }
                    self.ioQueue.async { [weak self, weak token] in
                        guard let self, let token else { return }
                        self.acknowledgeEventDelivery(
                            terminalID: terminalID,
                            token: token,
                            deliveredBytes: batch.retainedBytes
                        )
                    }
                }
            }
        }
    }

    private func acknowledgeEventDelivery(
        terminalID: String,
        token: BrokerDeliveryToken,
        deliveredBytes: Int
    ) {
        guard var active = attachments[terminalID],
              active.deliveryToken === token,
              active.inFlightEventBytes == deliveredBytes else { return }
        active.inFlightEventBytes = 0
        retainedEventBytes -= deliveredBytes
        precondition(retainedEventBytes >= 0)
        if active.pendingEvents.isEmpty {
            active.deliveryScheduled = false
            attachments[terminalID] = active
            finishDeferredDetachIfReady(terminalID: terminalID)
        } else {
            attachments[terminalID] = active
            scheduleEventDelivery(terminalID: terminalID, token: token)
        }
    }

    @discardableResult
    private func removeAttachment(terminalID: String) -> ActiveAttachment? {
        guard let active = attachments.removeValue(forKey: terminalID) else { return nil }
        active.deliveryToken.invalidate()
        retainedEventBytes -= active.pendingEvents.retainedBytes + active.inFlightEventBytes
        precondition(retainedEventBytes >= 0)
        pendingDetachDeliveries.removeValue(forKey: terminalID)
        return active
    }

    private func replaceAttachment(terminalID: String, with active: ActiveAttachment) {
        removeAttachment(terminalID: terminalID)
        attachments[terminalID] = active
    }

    private func markTerminalRecoveryPending(_ terminalID: String) {
        pendingTerminalRecoveries[terminalID] = PendingTerminalRecovery(
            connectionID: connectionID,
            deadline: .now() + Self.pendingTerminalSeconds,
            ignoredStateEvents: 0
        )
    }

    private func rememberIgnoredRecovery(_ recoveryID: String) {
        let now = DispatchTime.now().uptimeNanoseconds
        ignoredRecoveries = ignoredRecoveries.filter { $0.value.uptimeNanoseconds > now }
        if ignoredRecoveries.count >= Self.maximumIgnoredRecoveries,
           let oldest = ignoredRecoveries.min(by: {
               $0.value.uptimeNanoseconds < $1.value.uptimeNanoseconds
           })?.key {
            ignoredRecoveries.removeValue(forKey: oldest)
        }
        ignoredRecoveries[recoveryID] = .now() + Self.ignoredRecoverySeconds
    }

    private func shouldIgnoreRecovery(_ recoveryID: String) -> Bool {
        guard let deadline = ignoredRecoveries[recoveryID] else { return false }
        if deadline.uptimeNanoseconds > DispatchTime.now().uptimeNanoseconds {
            return true
        }
        ignoredRecoveries.removeValue(forKey: recoveryID)
        return false
    }

    private func abortRecoveryLocally(
        _ recoveryID: String,
        error: Error,
        notifyCompletion: Bool
    ) {
        rememberIgnoredRecovery(recoveryID)
        if let assembly = recoveries.removeValue(forKey: recoveryID), notifyCompletion {
            dispatchMain { assembly.completion(.failure(error)) }
        }
        preparedRecoveries.removeValue(forKey: recoveryID)
        legacyAuthorities.removeValue(forKey: recoveryID)
        if let commit = commits.removeValue(forKey: recoveryID) {
            retainedEventBytes -= commit.retainedEventBytes
            precondition(retainedEventBytes >= 0)
            pendingReplies.removeValue(forKey: commit.requestID)
            if notifyCompletion {
                dispatchMain { commit.completion(.failure(error)) }
            }
        }
        if let context = recoveryContexts[recoveryID] {
            removeAttachment(terminalID: context.terminalID)
            markTerminalRecoveryPending(context.terminalID)
        }
    }

    private func sendRecoveryAbort(_ context: RecoveryContext) {
        guard protocolMode == .orderedV4,
              context.brokerGeneration == hello?.generation,
              socketFD >= 0 else {
            recoveryContexts.removeValue(forKey: context.recoveryID)
            return
        }
        sendRequest(
            operation: "recovery_abort",
            fields: [
                "recovery_id": context.recoveryID,
                "terminal_id": context.terminalID,
                "broker_generation": context.brokerGeneration
            ]
        ) { [weak self] _ in
            self?.recoveryContexts.removeValue(forKey: context.recoveryID)
        }
    }

    // MARK: - Explicit protocol-v3 compatibility

    private func prepareLegacyAttachment(
        terminalID: String,
        generation: UInt64,
        completion: @escaping (Result<BrokerPreparedRecovery, Error>) -> Void
    ) {
        // Always request a canonical snapshot. A v3 byte-delta can update an
        // existing renderer but cannot initialize the required offscreen one.
        sendRequest(
            operation: "attach",
            fields: ["terminal_id": terminalID, "broker_generation": generation]
        ) { [weak self] result in
            guard let self else { return }
            do {
                let object = try result.get()
                guard Self.string(object, "result") == "attached",
                      let terminalValue = object["terminal"],
                      let inputEpoch = Self.unsigned(object, "input_epoch"),
                      let leaseID = Self.string(object, "lease_id"),
                      let recovery = object["recovery"] as? JSONObject,
                      Self.string(recovery, "mode") == "snapshot",
                      Self.string(recovery, "format") == "ansi_replay",
                      Self.string(recovery, "scope") == "viewport",
                      Self.unsigned(recovery, "snapshot_version") == 1,
                      let cursor = Self.unsigned(recovery, "cursor"),
                      let encoded = Self.string(recovery, "data"),
                      let checkpoint = Data(base64Encoded: encoded),
                      checkpoint.count <= Self.maximumRecoveryBytes else {
                    throw BrokerClientError.protocolViolation("Broker v3 did not return a bounded canonical ANSI snapshot.")
                }
                var terminal = try Self.parseTerminal(terminalValue)
                terminal = Self.replacingSequence(of: terminal, with: cursor)
                let recoveryID = "legacy-v3-\(UUID().uuidString)"
                let prepared = BrokerPreparedRecovery(
                    terminal: terminal,
                    manifest: Self.legacyManifest,
                    checkpoint: checkpoint,
                    cutoverStateSequence: cursor,
                    digest: recoveryID,
                    recoveryID: recoveryID,
                    brokerGeneration: generation,
                    connectionID: self.connectionID
                )
                self.preparedRecoveries[recoveryID] = prepared
                self.legacyAuthorities[recoveryID] = LegacyAuthority(
                    terminal: terminal,
                    inputEpoch: inputEpoch,
                    leaseID: leaseID
                )
                self.dispatchMain { completion(.success(prepared)) }
            } catch {
                self.dispatchMain { completion(.failure(error)) }
            }
        }
    }

    private func commitLegacyAttachment(
        _ prepared: BrokerPreparedRecovery,
        onEvent: @escaping (BrokerStateEvent) -> Void,
        completion: @escaping (Result<BrokerAttachment, Error>) -> Void
    ) {
        guard prepared.connectionID == connectionID,
              prepared.brokerGeneration == hello?.generation,
              let authority = legacyAuthorities.removeValue(forKey: prepared.recoveryID),
              preparedRecoveries.removeValue(forKey: prepared.recoveryID) != nil else {
            dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
            return
        }
        let attachment = BrokerAttachment(
            terminal: authority.terminal,
            inputEpoch: authority.inputEpoch,
            leaseID: authority.leaseID,
            brokerGeneration: prepared.brokerGeneration,
            connectionID: prepared.connectionID,
            catchUp: nil
        )
        replaceAttachment(terminalID: authority.terminal.id, with: ActiveAttachment(
            attachment: attachment,
            lastSequence: prepared.cutoverStateSequence,
            eventHandler: onEvent
        ))
        normalizedInputStates.removeValue(forKey: authority.terminal.id)
        dispatchMain { completion(.success(attachment)) }
    }

    private func handleLegacyOutput(_ object: JSONObject) throws {
        let terminalID = try Self.requiredString(object, "terminal_id")
        guard var active = attachments[terminalID],
              let cursor = Self.unsigned(object, "cursor"),
              let encoded = Self.string(object, "data"),
              let data = Data(base64Encoded: encoded),
              data.count <= Self.maximumChunkBytes else {
            throw BrokerClientError.resyncRequired("Broker v3 output is malformed or arrived before explicit attach commit.")
        }
        guard cursor == active.lastSequence + 1 else {
            removeAttachment(terminalID: terminalID)
            notifyResync(
                terminalID: terminalID,
                error: BrokerClientError.resyncRequired("Broker v3 output cursor has a gap or conflict.")
            )
            return
        }
        let event = BrokerStateEvent.ptyBytes(sequence: cursor, data: data)
        guard enqueueLiveEvent(event, terminalID: terminalID, active: &active) else { return }
        active.lastSequence = cursor
        let shouldSchedule = !active.deliveryScheduled
        if shouldSchedule { active.deliveryScheduled = true }
        attachments[terminalID] = active
        if shouldSchedule {
            scheduleEventDelivery(terminalID: terminalID, token: active.deliveryToken)
        }
    }

    private static let legacyManifest = BrokerRecoveryManifest(
        protocolVersion: 3,
        terminalABIVersion: 1,
        engineSourceCommit: "fixture:vt100-0.15.2",
        snapshotMagic: "OUROCODE-ANSI-REPLAY",
        snapshotFormatVersion: 1,
        unicodeWidthPolicy: "unicode-width:fixture",
        graphicsPolicy: "disabled",
        maximumSnapshotBytes: UInt64(maximumRecoveryBytes),
        maximumTerminalHistoryBytes: 8 * 1_024 * 1_024,
        maximumGlobalHistoryBytes: 128 * 1_024 * 1_024,
        maximumDeltaBytes: 512 * 1_024,
        maximumRecoveryPinnedBytes: 16 * 1_024 * 1_024,
        maximumChunkBytes: UInt64(maximumChunkBytes),
        compression: "none"
    )

    private func mutate(
        using attachment: BrokerAttachment,
        operation: String,
        extra: JSONObject,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        guard attachment.connectionID == connectionID,
              attachment.brokerGeneration == hello?.generation,
              detachingAttachments[attachment.terminal.id] == nil,
              let active = attachments[attachment.terminal.id],
              active.attachment.inputEpoch == attachment.inputEpoch,
              active.attachment.leaseID == attachment.leaseID else {
            dispatchMain { completion?(.failure(BrokerClientError.staleAttachment)) }
            return
        }
        var fields: JSONObject = [
            "terminal_id": attachment.terminal.id,
            "broker_generation": attachment.brokerGeneration,
            "input_epoch": attachment.inputEpoch,
            "lease_id": attachment.leaseID
        ]
        if protocolMode == .legacyV3, operation == "resize" {
            fields["columns"] = extra["columns"]
            fields["rows"] = extra["rows"]
        } else {
            extra.forEach { fields[$0] = $1 }
        }
        sendAccepted(operation: operation, fields: fields, completion: completion)
    }

    private func finishDetach(
        _ attachment: BrokerAttachment,
        result: Result<JSONObject, Error>,
        completion: @escaping (Result<BrokerDetachReceipt, Error>) -> Void
    ) {
        let terminalID = attachment.terminal.id
        guard let pending = detachingAttachments[terminalID],
              Self.sameLease(pending, attachment) else {
            dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
            return
        }
        do {
            let object = try result.get()
            guard Self.string(object, "result") == "detached",
                  Self.string(object, "terminal_id") == terminalID,
                  let stateSequence = Self.unsigned(object, "state_seq"),
                  let active = attachments[terminalID],
                  Self.sameLease(active.attachment, attachment),
                  active.lastSequence == stateSequence else {
                throw BrokerClientError.resyncRequired("Detached reply did not match the final received terminal state.")
            }
            guard active.pendingEvents.isEmpty, active.inFlightEventBytes == 0 else {
                pendingDetachDeliveries[terminalID] = PendingDetachDelivery(
                    attachment: attachment,
                    result: result,
                    completion: completion
                )
                return
            }
            if var inputState = normalizedInputStates[terminalID],
               inputState.connectionID == attachment.connectionID,
               inputState.brokerGeneration == attachment.brokerGeneration,
               inputState.inputEpoch == attachment.inputEpoch,
               inputState.leaseID == attachment.leaseID,
               inputState.inFlight != nil {
                // A conforming broker enqueues every earlier input receipt
                // before this FIFO barrier. Accepting a reordered detach would
                // discard the only identity needed to classify that input's
                // outcome. Keep both objects until the caller tears down this
                // connection-scoped authority.
                inputState.outcomeIsAmbiguous = true
                normalizedInputStates[terminalID] = inputState
                detachingAttachments[terminalID] = attachment
                let error = BrokerClientError.resyncRequired(
                    "Detached reply arrived before the pending normalized input receipt."
                )
                notifyResync(terminalID: terminalID, error: error)
                dispatchMain { completion(.failure(error)) }
                return
            }
            detachingAttachments.removeValue(forKey: terminalID)
            removeAttachment(terminalID: terminalID)
            normalizedInputStates.removeValue(forKey: terminalID)
            recordDetachedBoundary(terminalID: terminalID, stateSequence: stateSequence)
            dispatchMain {
                completion(.success(BrokerDetachReceipt(
                    terminalID: terminalID,
                    stateSequence: stateSequence
                )))
            }
        } catch {
            detachingAttachments.removeValue(forKey: terminalID)
            pendingDetachDeliveries.removeValue(forKey: terminalID)
            // An explicit failure or an ambiguous transport outcome cannot
            // preserve local authority safely. Recovery establishes a fresh
            // subscription and lease if the user selects the terminal again.
            if let current = attachments[terminalID],
               Self.sameLease(current.attachment, attachment) {
                removeAttachment(terminalID: terminalID)
                normalizedInputStates.removeValue(forKey: terminalID)
                markTerminalRecoveryPending(terminalID)
            }
            notifyResync(terminalID: terminalID, error: error)
            dispatchMain { completion(.failure(error)) }
        }
    }

    private func finishDeferredDetachIfReady(terminalID: String) {
        guard let pending = pendingDetachDeliveries[terminalID],
              let active = attachments[terminalID],
              active.pendingEvents.isEmpty,
              active.inFlightEventBytes == 0 else { return }
        pendingDetachDeliveries.removeValue(forKey: terminalID)
        finishDetach(
            pending.attachment,
            result: pending.result,
            completion: pending.completion
        )
    }

    private static func sameLease(_ lhs: BrokerAttachment, _ rhs: BrokerAttachment) -> Bool {
        lhs.connectionID == rhs.connectionID
            && lhs.brokerGeneration == rhs.brokerGeneration
            && lhs.terminal.id == rhs.terminal.id
            && lhs.inputEpoch == rhs.inputEpoch
            && lhs.leaseID == rhs.leaseID
    }

    private func finishNormalizedInput(
        terminalID: String,
        attachment: BrokerAttachment,
        sequence: UInt64,
        digest: String,
        event: NormalizedTerminalInputEvent,
        result: Result<JSONObject, Error>,
        completion: @escaping (Result<NormalizedTerminalInputReceipt, Error>) -> Void
    ) {
        guard var state = normalizedInputStates[terminalID],
              state.connectionID == attachment.connectionID,
              state.brokerGeneration == attachment.brokerGeneration,
              state.inputEpoch == attachment.inputEpoch,
              state.leaseID == attachment.leaseID,
              state.inFlight?.sequence == sequence,
              state.inFlight?.digest == digest else {
            dispatchMain { completion(.failure(BrokerClientError.staleAttachment)) }
            return
        }
        if state.outcomeIsAmbiguous {
            // The pending reply may arrive after a maliciously reordered
            // detach. It can no longer prove that the stream respected its
            // FIFO contract, so never convert it into a successful receipt.
            state.inFlight = nil
            normalizedInputStates[terminalID] = state
            let error = BrokerClientError.resyncRequired(
                "Normalized input outcome is ambiguous after invalid detach ordering."
            )
            dispatchMain { completion(.failure(error)) }
            return
        }
        do {
            let object = try result.get()
            guard Self.string(object, "result") == "input_receipt",
                  Self.string(object, "terminal_id") == terminalID,
                  Self.unsigned(object, "input_epoch") == attachment.inputEpoch,
                  Self.unsigned(object, "input_seq") == sequence,
                  Self.string(object, "lease_id") == attachment.leaseID,
                  Self.string(object, "event_digest") == digest,
                  let observedStateSequence = Self.unsigned(object, "observed_state_seq"),
                  let layoutEpoch = Self.unsigned(object, "layout_epoch") else {
                state.outcomeIsAmbiguous = true
                state.inFlight = nil
                normalizedInputStates[terminalID] = state
                throw BrokerClientError.protocolViolation("Normalized input receipt did not match its exact request identity.")
            }
            let disposition: NormalizedPointerDisposition?
            if let rawDisposition = Self.string(object, "pointer_disposition") {
                guard let decoded = NormalizedPointerDisposition(rawValue: rawDisposition) else {
                    throw BrokerClientError.protocolViolation(
                        "Normalized input receipt returned an unknown pointer disposition.")
                }
                disposition = decoded
            } else {
                disposition = nil
            }
            guard event.requiresPointerDisposition == (disposition != nil),
                  event.pointerLayoutEpoch.map({ $0 == layoutEpoch }) ?? true else {
                throw BrokerClientError.protocolViolation(
                    "Normalized pointer receipt omitted or invented its routing disposition.")
            }
            state.inFlight = nil
            state.nextSequence = sequence + 1
            normalizedInputStates[terminalID] = state
            let receipt = NormalizedTerminalInputReceipt(
                terminalID: terminalID,
                inputEpoch: attachment.inputEpoch,
                inputSequence: sequence,
                eventDigest: digest,
                leaseID: attachment.leaseID,
                observedStateSequence: observedStateSequence,
                layoutEpoch: layoutEpoch,
                pointerDisposition: disposition
            )
            dispatchMain { completion(.success(receipt)) }
        } catch {
            state.inFlight = nil
            if Self.isAmbiguousNormalizedInputError(error) {
                state.outcomeIsAmbiguous = true
            }
            normalizedInputStates[terminalID] = state
            dispatchMain { completion(.failure(error)) }
        }
    }

    private static func isAmbiguousNormalizedInputError(_ error: Error) -> Bool {
        guard let brokerError = error as? BrokerClientError else { return true }
        switch brokerError {
        case .server, .invalidRequest, .staleAttachment, .unavailable:
            // A framed broker error is an explicit non-commit. `staleAttachment`
            // and local availability failures did not enter this completion.
            return false
        case .notConnected, .helperMissing, .connectFailed, .disconnected,
             .protocolViolation, .resyncRequired, .timedOut:
            return true
        }
    }

    private func recordDetachedBoundary(terminalID: String, stateSequence: UInt64) {
        if detachedStateSequences[terminalID] == nil,
           detachedStateSequences.count >= Self.maximumDetachedBoundaries,
           let evicted = detachedStateSequences.keys.first {
            detachedStateSequences.removeValue(forKey: evicted)
        }
        detachedStateSequences[terminalID] = stateSequence
    }

    private func sendAccepted(
        operation: String,
        fields: JSONObject,
        completion: ((Result<Void, Error>) -> Void)?
    ) {
        sendRequest(operation: operation, fields: fields) { [weak self] result in
            let parsed = result.flatMap { object -> Result<Void, Error> in
                Self.string(object, "result") == "accepted"
                    ? .success(())
                    : .failure(BrokerClientError.protocolViolation("\(operation) was not acknowledged."))
            }
            self?.dispatchMain { completion?(parsed) }
        }
    }

    // MARK: - Decoding and digest

    private static func parseTerminal(_ value: Any) throws -> BrokerTerminalSummary {
        guard let object = value as? JSONObject,
              let id = string(object, "id"),
              let columns = integer(object, "columns"),
              let rows = integer(object, "rows"),
              let running = boolean(object, "running") else {
            throw BrokerClientError.protocolViolation("Terminal summary is malformed.")
        }
        let sequence = unsigned(object, "state_seq") ?? unsigned(object, "cursor") ?? 0
        return BrokerTerminalSummary(
            id: id,
            createNonce: string(object, "create_nonce") ?? "",
            stateSequence: sequence,
            columns: columns,
            rows: rows,
            layoutEpoch: unsigned(object, "layout_epoch") ?? 0,
            running: running,
            foregroundProcess: boolean(object, "foreground_process") ?? false
        )
    }

    private static func replacingSequence(
        of terminal: BrokerTerminalSummary,
        with sequence: UInt64
    ) -> BrokerTerminalSummary {
        BrokerTerminalSummary(
            id: terminal.id,
            createNonce: terminal.createNonce,
            stateSequence: sequence,
            columns: terminal.columns,
            rows: terminal.rows,
            layoutEpoch: terminal.layoutEpoch,
            running: terminal.running,
            foregroundProcess: terminal.foregroundProcess
        )
    }

    private static func parseManifest(_ object: JSONObject) throws -> BrokerRecoveryManifest {
        guard let protocolVersion = unsigned(object, "protocol_version"),
              let terminalABI = unsigned(object, "terminal_abi_version"),
              let engineCommit = string(object, "engine_source_commit"),
              let magic = string(object, "snapshot_magic"),
              let formatVersion = unsigned(object, "snapshot_format_version"),
              let unicodePolicy = string(object, "unicode_width_policy"),
              let graphicsPolicy = string(object, "graphics_policy"),
              let maxSnapshot = unsigned(object, "max_snapshot_bytes"),
              let maxTerminalHistory = unsigned(object, "max_terminal_history_bytes"),
              let maxGlobalHistory = unsigned(object, "max_global_history_bytes"),
              let maxDelta = unsigned(object, "max_delta_bytes"),
              let maxPinned = unsigned(object, "max_recovery_pinned_bytes"),
              let maxChunk = unsigned(object, "max_chunk_bytes"),
              let compression = string(object, "compression") else {
            throw BrokerClientError.protocolViolation("Recovery manifest is malformed.")
        }
        return BrokerRecoveryManifest(
            protocolVersion: protocolVersion,
            terminalABIVersion: terminalABI,
            engineSourceCommit: engineCommit,
            snapshotMagic: magic,
            snapshotFormatVersion: formatVersion,
            unicodeWidthPolicy: unicodePolicy,
            graphicsPolicy: graphicsPolicy,
            maximumSnapshotBytes: maxSnapshot,
            maximumTerminalHistoryBytes: maxTerminalHistory,
            maximumGlobalHistoryBytes: maxGlobalHistory,
            maximumDeltaBytes: maxDelta,
            maximumRecoveryPinnedBytes: maxPinned,
            maximumChunkBytes: maxChunk,
            compression: compression
        )
    }

    private static func validateManifest(_ manifest: BrokerRecoveryManifest) throws {
        guard manifest.protocolVersion == UInt64(protocolVersion),
              manifest.terminalABIVersion > 0,
              !manifest.engineSourceCommit.isEmpty,
              !manifest.snapshotMagic.isEmpty,
              manifest.snapshotFormatVersion > 0,
              !manifest.unicodeWidthPolicy.isEmpty,
              !manifest.graphicsPolicy.isEmpty,
              manifest.maximumSnapshotBytes > 0,
              manifest.maximumDeltaBytes > 0,
              manifest.maximumRecoveryPinnedBytes > 0,
              manifest.maximumChunkBytes == UInt64(maximumChunkBytes),
              manifest.compression == "none" else {
            throw BrokerClientError.protocolViolation("Terminal broker capability manifest violates the v4 contract.")
        }
    }

    private static func parseEvent(_ object: JSONObject) throws -> BrokerStateEvent {
        guard let kind = string(object, "event"), let sequence = unsigned(object, "state_seq") else {
            throw BrokerClientError.resyncRequired("Terminal state event is malformed.")
        }
        switch kind {
        case "pty_bytes":
            guard let encoded = string(object, "data"),
                  let data = Data(base64Encoded: encoded),
                  data.count <= maximumChunkBytes else {
                throw BrokerClientError.resyncRequired("PTY event exceeded the 64 KiB cap or had invalid base64.")
            }
            return .ptyBytes(sequence: sequence, data: data)
        case "resize":
            guard let columns = integer(object, "columns"),
                  let rows = integer(object, "rows"),
                  let cellWidth = integer(object, "cell_width_px"),
                  let cellHeight = integer(object, "cell_height_px"),
                  let layoutEpoch = unsigned(object, "layout_epoch"),
                  columns > 0, rows > 0, cellWidth > 0, cellHeight > 0 else {
                throw BrokerClientError.resyncRequired("Resize event is malformed.")
            }
            return .resize(
                sequence: sequence,
                columns: columns,
                rows: rows,
                cellWidthPixels: cellWidth,
                cellHeightPixels: cellHeight,
                layoutEpoch: layoutEpoch
            )
        default:
            throw BrokerClientError.resyncRequired("Unsupported ordered state event \(kind).")
        }
    }

    private static func recoveryDigest(manifest: BrokerRecoveryManifest, checkpoint: Data) throws -> String {
        guard manifest.protocolVersion <= UInt64(UInt16.max),
              manifest.terminalABIVersion <= UInt64(UInt32.max),
              manifest.snapshotFormatVersion <= UInt64(UInt32.max),
              manifest.maximumChunkBytes <= UInt64(UInt32.max) else {
            throw BrokerClientError.protocolViolation("Recovery manifest integer exceeds its v4 wire width.")
        }
        var input = Data("ourocode-broker-v4-checkpoint\0".utf8)
        appendInteger(UInt16(manifest.protocolVersion), to: &input)
        appendInteger(UInt32(manifest.terminalABIVersion), to: &input)
        appendString(manifest.engineSourceCommit, to: &input)
        appendString(manifest.snapshotMagic, to: &input)
        appendInteger(UInt32(manifest.snapshotFormatVersion), to: &input)
        appendString(manifest.unicodeWidthPolicy, to: &input)
        appendString(manifest.graphicsPolicy, to: &input)
        appendInteger(manifest.maximumSnapshotBytes, to: &input)
        appendInteger(manifest.maximumTerminalHistoryBytes, to: &input)
        appendInteger(manifest.maximumGlobalHistoryBytes, to: &input)
        appendInteger(manifest.maximumDeltaBytes, to: &input)
        appendInteger(manifest.maximumRecoveryPinnedBytes, to: &input)
        appendInteger(UInt32(manifest.maximumChunkBytes), to: &input)
        appendString(manifest.compression, to: &input)
        appendInteger(UInt64(checkpoint.count), to: &input)
        input.append(checkpoint)
        let digest = SHA256.hash(data: input).map { String(format: "%02x", $0) }.joined()
        return "sha256:\(digest)"
    }

    private static func appendInteger<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func appendString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        appendInteger(UInt64(bytes.count), to: &data)
        data.append(bytes)
    }

    private static func requiredString(_ object: JSONObject, _ key: String) throws -> String {
        guard let value = string(object, key) else {
            throw BrokerClientError.protocolViolation("Terminal broker message is missing \(key).")
        }
        return value
    }

    private static func string(_ object: JSONObject, _ key: String) -> String? {
        object[key] as? String
    }

    private static func unsigned(_ object: JSONObject, _ key: String) -> UInt64? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        // JSONSerialization preserves an unsigned JSON integer as NSNumber,
        // but int64Value wraps values above Int64.max. The broker generation
        // and every v4 sequence field are true u64 values, so parse the exact
        // decimal representation and reject negatives, fractions and exponents.
        return UInt64(number.stringValue)
    }

    private static func integer(_ object: JSONObject, _ key: String) -> Int? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private static func boolean(_ object: JSONObject, _ key: String) -> Bool? {
        guard let number = object[key] as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    // MARK: - Completion fanout

    private func failOutstanding(with error: Error) {
        let replies = pendingReplies.values
        pendingReplies.removeAll()
        replies.forEach { $0(.failure(error)) }

        let recoveryValues = recoveries.values
        recoveries.removeAll()
        recoveryValues.forEach { value in dispatchMain { value.completion(.failure(error)) } }

        let commitValues = commits.values
        commits.removeAll()
        commitValues.forEach { value in dispatchMain { value.completion(.failure(error)) } }

        preparedRecoveries.removeAll()
        legacyAuthorities.removeAll()
        recoveryContexts.removeAll()
        ignoredRecoveries.removeAll()
        pendingTerminalRecoveries.removeAll()
        pendingPrepareRequests.removeAll()
        detachingAttachments.removeAll()
        detachedStateSequences.removeAll()
        attachments.values.forEach { $0.deliveryToken.invalidate() }
        attachments.removeAll()
        retainedEventBytes = 0
        let deferredDetaches = pendingDetachDeliveries.values
        pendingDetachDeliveries.removeAll()
        deferredDetaches.forEach { value in
            dispatchMain { value.completion(.failure(error)) }
        }
        normalizedInputStates.removeAll()
    }

    private func finishStart(_ result: Result<BrokerHello, Error>) {
        let values = startCompletions
        startCompletions.removeAll()
        values.forEach { completion in dispatchMain { completion(result) } }
    }

    private func notifyDisconnect(_ error: Error) {
        dispatchMain { [weak self] in self?.onDisconnect?(error) }
    }

    private func notifyResync(terminalID: String, error: Error) {
        dispatchMain { [weak self] in self?.onResyncRequired?(terminalID, error) }
    }

    private func dispatchMain(_ work: @escaping () -> Void) {
        DispatchQueue.main.async(execute: work)
    }
}
