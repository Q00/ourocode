#if OUROCODE_GHOSTTY_RENDERER
import COuroRender
import Darwin
import Foundation

enum GhosttyBrokerContract {
    static let wireNamespace = "input-v2"
    static let sourceCommit = "136f436a3bbb14fd48d18e927a83fc6585d5a63c"
    static let helperInfoKey = "OurocodeGhosttyBrokerHelperName"
    static let buildIDInfoKey = "OurocodeGhosttyBrokerBuildID"
    static let wireNamespaceInfoKey = "OurocodeGhosttyBrokerWireNamespace"
}

struct GhosttyBrokerDeployment: Equatable {
    let sourceCommit: String
    let buildID: String?
    let helperName: String
    let socketURL: URL

    var pinNamespace: String { String(sourceCommit.prefix(12)) }

    static func resolve(
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
        applicationSupportURL: URL? = nil
    ) throws -> GhosttyBrokerDeployment {
        let helper = infoDictionary?[GhosttyBrokerContract.helperInfoKey] as? String
        let buildID = infoDictionary?[GhosttyBrokerContract.buildIDInfoKey] as? String
        let wireNamespace = infoDictionary?[GhosttyBrokerContract.wireNamespaceInfoKey] as? String

        if [helper, buildID, wireNamespace].contains(where: { $0 != nil }) {
            guard let helper, let buildID, let wireNamespace else {
                throw GhosttyRenderBridgeError.invalidConfiguration(
                    "Packaged Ghostty broker deployment metadata is incomplete."
                )
            }
            guard wireNamespace == GhosttyBrokerContract.wireNamespace else {
                throw GhosttyRenderBridgeError.invalidConfiguration(
                    "Packaged Ghostty broker wire namespace does not match this client."
                )
            }
            guard buildID.count == 16,
                  buildID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw GhosttyRenderBridgeError.invalidConfiguration(
                    "Packaged Ghostty broker build identity must be 16 lowercase hexadecimal bytes."
                )
            }
            let expected = "ouro-broker-v4-ghostty-\(GhosttyBrokerContract.sourceCommit)-\(buildID)"
            guard helper == expected else {
                throw GhosttyRenderBridgeError.invalidConfiguration(
                    "Packaged Ghostty broker helper name does not match its build identity."
                )
            }
        }

        let resolvedHelper = helper
            ?? "ouro-broker-v4-ghostty-\(GhosttyBrokerContract.sourceCommit)"
        let base = applicationSupportURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        let socketName: String
        if let buildID {
            // Keep this deliberately compact: Darwin's sockaddr_un path is 104
            // bytes and the user's Application Support prefix is not bounded.
            socketName = "broker-v4-g6-\(buildID).sock"
        } else {
            socketName = "broker-v4-ghostty-\(String(GhosttyBrokerContract.sourceCommit.prefix(12)))-\(GhosttyBrokerContract.wireNamespace).sock"
        }
        let socketURL = base
            .appendingPathComponent("Ourocode", isDirectory: true)
            .appendingPathComponent(socketName, isDirectory: false)
        let socketPathBytes = socketURL.path.utf8.count.addingReportingOverflow(1)
        let unixPathCapacity = MemoryLayout<sockaddr_un>.size - MemoryLayout<sa_family_t>.size
        guard !socketPathBytes.overflow,
              socketPathBytes.partialValue <= unixPathCapacity else {
            throw GhosttyRenderBridgeError.invalidConfiguration(
                "Build-namespaced Ghostty broker socket exceeds Darwin's sockaddr_un bound."
            )
        }
        return GhosttyBrokerDeployment(
            sourceCommit: GhosttyBrokerContract.sourceCommit,
            buildID: buildID,
            helperName: resolvedHelper,
            socketURL: socketURL
        )
    }
}

enum GhosttyRenderBridgeError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidPayload(String)
    case manifestMismatch(String)
    case ffi(operation: String, code: UInt32)
}

extension GhosttyRenderBridgeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidPayload(message),
             let .manifestMismatch(message):
            return message
        case let .ffi(operation, code):
            return "Ghostty render bridge \(operation) failed with ABI result \(code)."
        }
    }
}

struct GhosttyRenderStream: Hashable {
    let brokerGeneration: UInt64
    let terminalID: String
}

enum GhosttyRenderMetadataField: Equatable {
    case value(String)
    case cleared
    case invalid
}

struct GhosttyRenderMetadata: Equatable {
    let epoch: UInt64
    let title: GhosttyRenderMetadataField
    let pwd: GhosttyRenderMetadataField
}

struct GhosttyRenderSelectionPoint: Equatable {
    let column: UInt16
    let row: UInt32
    let surfaceX: Double
    let surfaceY: Double
    let timeNanoseconds: UInt64?
}

struct GhosttyRenderSelectionGeometry: Equatable {
    let columns: UInt32
    let cellWidth: Double
    let paddingLeft: Double
    let screenHeight: Double
}

enum GhosttyRenderSelectionAutoscroll: Int32, Equatable {
    case none = 0
    case up = 1
    case down = 2
}

struct GhosttyRenderSelectionOutcome: Equatable {
    let observedStateSequence: UInt64
    let hasSelection: Bool
    let autoscroll: GhosttyRenderSelectionAutoscroll
}

enum GhosttyRenderViewportScroll: Equatable {
    case top
    case bottom
    case delta(Int64)
    case row(UInt64)
}

struct GhosttyRenderScrollbar: Equatable {
    let observedStateSequence: UInt64
    let total: UInt64
    let offset: UInt64
    let length: UInt64
}

struct GhosttyRenderFindProjection: Equatable {
    let text: String
    let scrollbar: GhosttyRenderScrollbar
}

struct GhosttyRenderRecoveryManifest: Equatable {
    let terminalEngineABIVersion: UInt32
    let snapshotFormatVersion: UInt32
    let ghosttySourceCommit: String
    let snapshotMagic: String
    let unicodeWidthPolicy: String
    let graphicsPolicy: String
}

struct GhosttyRenderConfiguration {
    let initialStream: GhosttyRenderStream
    let columns: UInt16
    let rows: UInt16
    let cellWidthPixels: UInt32
    let cellHeightPixels: UInt32
    let initialStateSequence: UInt64
    let scrollbackMaximumBytes: Int
    let scrollbackMaximumLines: Int
    let snapshotMaximumBytes: Int
    let engineMemoryMaximumBytes: Int
    let projectionMemoryMaximumBytes: Int
    let sharedPageBudgetMaximumBytes: Int
    let maximumGraphemeBytes: Int
    let maximumFeedBytes: Int
    let cpuCacheMaximumBytes: Int
    let brokerDeployment: GhosttyBrokerDeployment?

    init(
        initialStream: GhosttyRenderStream,
        columns: UInt16,
        rows: UInt16,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32,
        initialStateSequence: UInt64,
        scrollbackMaximumBytes: Int = 8 * 1_024 * 1_024,
        scrollbackMaximumLines: Int = 20_000,
        snapshotMaximumBytes: Int = 16 * 1_024 * 1_024,
        engineMemoryMaximumBytes: Int = 32 * 1_024 * 1_024,
        projectionMemoryMaximumBytes: Int = 16 * 1_024 * 1_024,
        sharedPageBudgetMaximumBytes: Int = 128 * 1_024 * 1_024,
        maximumGraphemeBytes: Int = 256,
        maximumFeedBytes: Int = 64 * 1_024,
        cpuCacheMaximumBytes: Int = 16 * 1_024 * 1_024,
        brokerDeployment: GhosttyBrokerDeployment? = nil
    ) {
        self.initialStream = initialStream
        self.columns = columns
        self.rows = rows
        self.cellWidthPixels = cellWidthPixels
        self.cellHeightPixels = cellHeightPixels
        self.initialStateSequence = initialStateSequence
        self.scrollbackMaximumBytes = scrollbackMaximumBytes
        self.scrollbackMaximumLines = scrollbackMaximumLines
        self.snapshotMaximumBytes = snapshotMaximumBytes
        self.engineMemoryMaximumBytes = engineMemoryMaximumBytes
        self.projectionMemoryMaximumBytes = projectionMemoryMaximumBytes
        self.sharedPageBudgetMaximumBytes = sharedPageBudgetMaximumBytes
        self.maximumGraphemeBytes = maximumGraphemeBytes
        self.maximumFeedBytes = maximumFeedBytes
        self.cpuCacheMaximumBytes = cpuCacheMaximumBytes
        self.brokerDeployment = brokerDeployment
    }
}

struct GhosttyRenderCandidate: Hashable {
    fileprivate let owner: UUID
    fileprivate let rawValue: UInt64
}

enum GhosttyRenderDirty: UInt32 {
    case none = 0
    case partial = 1
    case full = 2
}

enum GhosttyRenderLeaseDisposition {
    case consumed
    case retry
}

struct GhosttyRenderRGB: Equatable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
}

struct GhosttyRenderColor: Equatable {
    let kind: UInt32
    let paletteIndex: UInt8
    let rgb: GhosttyRenderRGB
}

struct GhosttyRenderRow: Equatable {
    let y: UInt16
    let firstCellIndex: Int
    let cellCount: Int
    let dirty: Bool
    let selection: Range<Int>?
    let wraps: Bool
    let continuesWrappedRow: Bool
    let semantic: UInt32
}

struct GhosttyRenderCell: Equatable {
    let x: UInt16
    let width: UInt8
    let graphemeRange: Range<Int>
    let flags: UInt32
    let semantic: UInt32
    let foreground: GhosttyRenderColor
    let background: GhosttyRenderColor
    let underlineColor: GhosttyRenderColor
    let underline: UInt32
}

struct GhosttyRenderCursor: Equatable {
    let x: UInt16
    let y: UInt16
    let wideTail: Bool
    let visible: Bool
    let blinking: Bool
    let passwordInput: Bool
    let style: UInt32
    let color: GhosttyRenderRGB?
}

fileprivate final class GhosttyFallibleBuffer<Element> {
    let count: Int
    let pointer: UnsafeMutablePointer<Element>?

    init(count: Int, byteLimit: Int) throws {
        guard count >= 0 else {
            throw GhosttyRenderBridgeError.invalidPayload("A render buffer has a negative element count.")
        }
        let bytes = count.multipliedReportingOverflow(by: MemoryLayout<Element>.stride)
        guard !bytes.overflow, bytes.partialValue <= byteLimit else {
            throw GhosttyRenderBridgeError.invalidPayload("A render buffer exceeds its checked byte ceiling.")
        }
        self.count = count
        guard count > 0 else {
            pointer = nil
            return
        }
        guard let allocation = calloc(count, MemoryLayout<Element>.stride) else {
            throw GhosttyRenderBridgeError.ffi(
                operation: "fallible bulk payload allocation",
                code: UInt32(OURO_RENDER_CLIENT_OUT_OF_MEMORY.rawValue)
            )
        }
        pointer = allocation.bindMemory(to: Element.self, capacity: count)
    }

    deinit {
        free(pointer)
    }

    func element(at index: Int) -> Element? {
        guard index >= 0, index < count, let pointer else { return nil }
        return pointer[index]
    }

    func bytesEqual(to other: GhosttyFallibleBuffer<Element>) -> Bool {
        guard count == other.count else { return false }
        guard count > 0 else { return true }
        guard let pointer, let otherPointer = other.pointer else { return false }
        return memcmp(pointer, otherPointer, count * MemoryLayout<Element>.stride) == 0
    }
}

final class GhosttyRenderRows: Equatable {
    let count: Int
    private let storage: GhosttyFallibleBuffer<OuroRenderClientRow>

    fileprivate init(storage: GhosttyFallibleBuffer<OuroRenderClientRow>) {
        self.storage = storage
        count = storage.count
    }

    func row(at index: Int) -> GhosttyRenderRow? {
        guard let row = storage.element(at: index) else { return nil }
        let selection = row.selection_has_value == 0
            ? nil
            : Int(row.selection_start_x)..<(Int(row.selection_end_x) + 1)
        return GhosttyRenderRow(
            y: row.y,
            firstCellIndex: row.first_cell_index,
            cellCount: row.cell_count,
            dirty: row.dirty != 0,
            selection: selection,
            wraps: row.wrap != 0,
            continuesWrappedRow: row.wrap_continuation != 0,
            semantic: row.semantic
        )
    }

    static func == (lhs: GhosttyRenderRows, rhs: GhosttyRenderRows) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs.row(at: index) != rhs.row(at: index) {
            return false
        }
        return true
    }
}

final class GhosttyRenderCells: Equatable {
    let count: Int
    private let storage: GhosttyFallibleBuffer<OuroRenderClientCell>

    fileprivate init(storage: GhosttyFallibleBuffer<OuroRenderClientCell>) {
        self.storage = storage
        count = storage.count
    }

    func cell(at index: Int) -> GhosttyRenderCell? {
        guard let cell = storage.element(at: index) else { return nil }
        return GhosttyRenderCell(
            x: cell.x,
            width: cell.width,
            graphemeRange: cell.grapheme_offset..<(cell.grapheme_offset + cell.grapheme_bytes),
            flags: cell.flags,
            semantic: cell.semantic,
            foreground: GhosttyRenderBridge.color(cell.foreground),
            background: GhosttyRenderBridge.color(cell.background),
            underlineColor: GhosttyRenderBridge.color(cell.underline_color),
            underline: cell.underline.rawValue
        )
    }

    static func == (lhs: GhosttyRenderCells, rhs: GhosttyRenderCells) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for index in 0..<lhs.count where lhs.cell(at: index) != rhs.cell(at: index) {
            return false
        }
        return true
    }
}

final class GhosttyRenderGraphemeArena: Equatable {
    let count: Int
    private let storage: GhosttyFallibleBuffer<UInt8>

    fileprivate init(storage: GhosttyFallibleBuffer<UInt8>) {
        self.storage = storage
        count = storage.count
    }

    /// Borrows validated UTF-8 bytes only for the duration of `body`.
    /// The fallible FFI allocation remains frame-lease owned and no pointer can
    /// escape into the renderer or a CoreText cache.
    func withUTF8Bytes<T>(
        in range: Range<Int>,
        _ body: (UnsafeBufferPointer<UInt8>) throws -> T
    ) rethrows -> T? {
        guard range.lowerBound >= 0, range.upperBound <= count,
              range.lowerBound <= range.upperBound else { return nil }
        if range.isEmpty {
            return try body(UnsafeBufferPointer(start: nil, count: 0))
        }
        guard let pointer = storage.pointer else { return nil }
        return try body(
            UnsafeBufferPointer(
                start: pointer.advanced(by: range.lowerBound),
                count: range.count
            )
        )
    }

    func string(in range: Range<Int>) -> String? {
        withUTF8Bytes(in: range) { String(bytes: $0, encoding: .utf8) } ?? nil
    }

    func containsUTF8(_ value: String) -> Bool {
        let needle = value.utf8
        guard !needle.isEmpty, needle.count <= count, let pointer = storage.pointer else {
            return false
        }
        for start in 0...(count - needle.count) {
            var matches = true
            for offset in 0..<needle.count {
                let index = needle.index(needle.startIndex, offsetBy: offset)
                if pointer[start + offset] != needle[index] {
                    matches = false
                    break
                }
            }
            if matches { return true }
        }
        return false
    }

    static func == (lhs: GhosttyRenderGraphemeArena, rhs: GhosttyRenderGraphemeArena) -> Bool {
        lhs.storage.bytesEqual(to: rhs.storage)
    }
}

struct GhosttyRenderPalette: Equatable {
    private var storage: OuroRenderClientBulkFrame

    fileprivate init(frame: OuroRenderClientBulkFrame) {
        storage = frame
    }

    func color(at index: Int) -> GhosttyRenderRGB? {
        guard index >= 0, index < Int(OURO_RENDER_PALETTE_COLORS) else { return nil }
        var palette = storage.palette
        return withUnsafeBytes(of: &palette) { bytes in
            let values = bytes.bindMemory(to: OuroRenderClientRgb.self)
            return GhosttyRenderBridge.rgb(values[index])
        }
    }

    static func == (lhs: GhosttyRenderPalette, rhs: GhosttyRenderPalette) -> Bool {
        var left = lhs.storage.palette
        var right = rhs.storage.palette
        return withUnsafeBytes(of: &left) { leftBytes in
            withUnsafeBytes(of: &right) { rightBytes in
                leftBytes.elementsEqual(rightBytes)
            }
        }
    }
}

struct GhosttyRenderFrame: Equatable {
    let stateSequence: UInt64
    let generation: UInt64
    let dirty: GhosttyRenderDirty
    let columns: UInt16
    let rows: UInt16
    let rowData: GhosttyRenderRows
    let cellData: GhosttyRenderCells
    let graphemes: GhosttyRenderGraphemeArena
    let cursor: GhosttyRenderCursor?
    let background: GhosttyRenderRGB
    let foreground: GhosttyRenderRGB
    let palette: GhosttyRenderPalette
}

struct GhosttyRenderMemoryInfo: Equatable {
    let cpuCacheLiveBytes: Int
    let cpuCachePeakBytes: Int
    let cpuCacheLimitBytes: Int
    let projectionLiveBytes: Int
    let projectionPeakBytes: Int
    let projectionLimitBytes: Int
    let projectionAllocationFailures: UInt64
    let activeEngineLiveBytes: Int
    let activeEnginePeakBytes: Int
    let activeEngineLimitBytes: Int
    let activeEngineAllocationFailures: UInt64
    let candidatePresent: Bool
    let candidateEngineLiveBytes: Int
    let candidateEnginePeakBytes: Int
    let candidateEngineLimitBytes: Int
    let candidateEngineAllocationFailures: UInt64
    let pageReservedBytes: Int
    let pagePeakReservedBytes: Int
    let pageLimitBytes: Int
    let pageDenialCount: Int
    let pageChildFailureCount: Int
    let activeTerminalCount: Int
    let candidateTerminalCount: Int
    let projectionCount: Int
}

final class GhosttyRenderFrameLease {
    let frame: GhosttyRenderFrame

    private let bridge: GhosttyRenderBridge
    private let generation: UInt64
    private let lock = NSLock()
    private var finished = false

    fileprivate init(bridge: GhosttyRenderBridge, frame: GhosttyRenderFrame) {
        self.bridge = bridge
        self.frame = frame
        generation = frame.generation
    }

    func finish(_ disposition: GhosttyRenderLeaseDisposition) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        try bridge.finishFrameLease(generation: generation, disposition: disposition)
        finished = true
    }

    deinit {
        // A dropped consumer must retain the exact CPU frame for a later retry;
        // silently consuming it would lose damage after a failed presentation.
        try? finish(.retry)
    }
}

/// Typed ownership boundary for the Rust render client.
///
/// The opaque client and every C ABI invocation are confined to `ffiQueue`.
/// Callers may enter from any thread, but no raw pointer, imported C struct, or
/// borrowed frame storage escapes this file or that serial executor.
final class GhosttyRenderBridge {
    let manifest: GhosttyRenderRecoveryManifest
    let pinNamespace: String
    let bundledHelperName: String
    let defaultSocketURL: URL

    private let owner = UUID()
    private let ffiQueue = DispatchQueue(label: "com.ourolabs.ourocode.ghostty-render-ffi")
    private let queueKey = DispatchSpecificKey<UUID>()
    private let client: OpaquePointer
    private let limits: Limits
    private var rawManifest: OuroRenderClientManifest

    private struct Limits {
        let maximumCells: Int
        let maximumGraphemeBytesPerCell: Int
        let feedBytes: Int
        let snapshotBytes: Int
        let cpuCacheBytes: Int
    }

    init(configuration: GhosttyRenderConfiguration) throws {
        let limits = try Self.validate(configuration)
        self.limits = limits
        ffiQueue.setSpecific(key: queueKey, value: owner)

        var queriedManifest = OuroRenderClientManifest()
        queriedManifest.size = MemoryLayout<OuroRenderClientManifest>.size
        queriedManifest.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        var rawClient: OpaquePointer?
        let creationQueue = ffiQueue
        let creationResult: OuroRenderClientResult = try creationQueue.sync {
            dispatchPrecondition(condition: .onQueue(creationQueue))
            try Self.requireOK(
                ouro_render_client_manifest(&queriedManifest),
                operation: "manifest"
            )
            try Self.requireOK(
                ouro_render_client_manifest_matches(&queriedManifest),
                operation: "manifest exact comparison"
            )
            var config = try Self.makeConfig(configuration)
            return ouro_render_client_new(&config, &rawClient)
        }
        try Self.requireOK(creationResult, operation: "new")
        guard let rawClient else {
            throw GhosttyRenderBridgeError.ffi(
                operation: "new returned no client",
                code: UInt32.max
            )
        }

        let decoded: GhosttyRenderRecoveryManifest
        do {
            decoded = try Self.decodeManifest(queriedManifest)
        } catch {
            creationQueue.sync {
                dispatchPrecondition(condition: .onQueue(creationQueue))
                ouro_render_client_free(rawClient)
            }
            throw error
        }
        guard decoded.ghosttySourceCommit.count == 40,
              decoded.ghosttySourceCommit.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
            creationQueue.sync {
                dispatchPrecondition(condition: .onQueue(creationQueue))
                ouro_render_client_free(rawClient)
            }
            throw GhosttyRenderBridgeError.manifestMismatch("Ghostty source pin is not a lowercase 40-byte commit.")
        }
        client = rawClient
        rawManifest = queriedManifest
        manifest = decoded
        let deployment: GhosttyBrokerDeployment
        do {
            deployment = try configuration.brokerDeployment ?? .resolve()
        } catch {
            creationQueue.sync {
                dispatchPrecondition(condition: .onQueue(creationQueue))
                ouro_render_client_free(rawClient)
            }
            throw error
        }
        guard deployment.sourceCommit == decoded.ghosttySourceCommit else {
            creationQueue.sync {
                dispatchPrecondition(condition: .onQueue(creationQueue))
                ouro_render_client_free(rawClient)
            }
            throw GhosttyRenderBridgeError.manifestMismatch(
                "Broker deployment source pin does not match the linked Ghostty render ABI."
            )
        }
        pinNamespace = deployment.pinNamespace
        bundledHelperName = deployment.helperName
        defaultSocketURL = deployment.socketURL
    }

    deinit {
        try? onQueue { ouro_render_client_free(client) }
    }

    func validateRecoveryManifest(_ candidate: GhosttyRenderRecoveryManifest) throws {
        guard candidate == manifest else {
            throw GhosttyRenderBridgeError.manifestMismatch("Broker recovery manifest does not exactly match the linked Ghostty render ABI.")
        }
        try onQueue {
            var value = rawManifest
            try Self.requireOK(
                ouro_render_client_manifest_matches(&value),
                operation: "manifest exact comparison"
            )
        }
    }

    @discardableResult
    func feedActive(
        stream: GhosttyRenderStream,
        stateSequence: UInt64,
        bytes: Data,
        previousMetadataEpoch: UInt64? = nil
    ) throws -> GhosttyRenderMetadata? {
        guard bytes.count <= limits.feedBytes else {
            throw GhosttyRenderBridgeError.invalidPayload("Active feed exceeds the configured byte ceiling.")
        }
        return try onQueue {
            var identity = try Self.makeStream(stream)
            let result = bytes.withUnsafeBytes { payload in
                ouro_render_client_active_feed(
                    client,
                    &identity,
                    stateSequence,
                    payload.bindMemory(to: UInt8.self).baseAddress,
                    payload.count
                )
            }
            try Self.requireOK(result, operation: "active feed")
            return try activeMetadataLocked(
                identity: &identity,
                minimumStateSequence: stateSequence,
                previousEpoch: previousMetadataEpoch
            )
        }
    }

    func activeMetadata(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64
    ) throws -> GhosttyRenderMetadata? {
        try onQueue {
            var identity = try Self.makeStream(stream)
            return try activeMetadataLocked(
                identity: &identity,
                minimumStateSequence: minimumStateSequence,
                previousEpoch: nil
            )
        }
    }

    private func activeMetadataLocked(
        identity: inout OuroRenderStreamIdentity,
        minimumStateSequence: UInt64,
        previousEpoch: UInt64?
    ) throws -> GhosttyRenderMetadata? {
        var context = OuroRenderClientProjectionContext()
        context.size = MemoryLayout<OuroRenderClientProjectionContext>.size
        context.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        context.stream = identity
        context.minimum_state_seq = minimumStateSequence
        var epoch: UInt64 = 0
        try Self.requireOK(
            ouro_render_client_active_metadata_epoch(client, &context, &epoch),
            operation: "active metadata epoch"
        )
        guard previousEpoch != epoch else { return nil }
        let title = try copyMetadata(
            kind: 1, context: &context
        )
        let pwd = try copyMetadata(
            kind: 2, context: &context
        )
        return GhosttyRenderMetadata(epoch: epoch, title: title, pwd: pwd)
    }

    private func copyMetadata(
        kind: UInt8,
        context: inout OuroRenderClientProjectionContext
    ) throws -> GhosttyRenderMetadataField {
        var required = 0
        let probe = ouro_render_client_active_copy_metadata(
            client, &context, kind, nil, 0, &required
        )
        if probe == OURO_RENDER_CLIENT_LIMIT_EXCEEDED {
            return .invalid
        }
        if probe == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL, required == 0 {
            // The Ghostty adapter reports an over-limit value as a bounded
            // BUFFER_TOO_SMALL query with no safe length. This is a metadata
            // side-channel failure, never a reason to reject the PTY feed.
            return .invalid
        }
        guard probe == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL || probe == OURO_RENDER_CLIENT_OK else {
            try Self.requireOK(probe, operation: "active metadata length")
            return .invalid
        }
        guard required <= 4_096 else {
            return .invalid
        }
        guard required > 0 else { return .cleared }
        var bytes = [UInt8](repeating: 0, count: required)
        let result = bytes.withUnsafeMutableBufferPointer { buffer in
            ouro_render_client_active_copy_metadata(
                client, &context, kind, buffer.baseAddress, buffer.count, &required
            )
        }
        if result == OURO_RENDER_CLIENT_LIMIT_EXCEEDED || result == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL {
            return .invalid
        }
        try Self.requireOK(result, operation: "active metadata copy")
        guard required == bytes.count else {
            return .invalid
        }
        return Self.decodeMetadataBytes(bytes)
    }

    static func decodeMetadataBytes(_ bytes: [UInt8]) -> GhosttyRenderMetadataField {
        guard !bytes.isEmpty else { return .cleared }
        guard let value = String(bytes: bytes, encoding: .utf8) else { return .invalid }
        return .value(value)
    }

    func resizeActive(
        stream: GhosttyRenderStream,
        stateSequence: UInt64,
        columns: UInt16,
        rows: UInt16,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) throws {
        _ = try Self.validateGrid(columns: columns, rows: rows, maximumCells: limits.maximumCells)
        guard cellWidthPixels > 0, cellHeightPixels > 0 else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Terminal cell dimensions must be non-zero.")
        }
        try onQueue {
            var identity = try Self.makeStream(stream)
            try Self.requireOK(
                ouro_render_client_active_resize(
                    client,
                    &identity,
                    stateSequence,
                    columns,
                    rows,
                    cellWidthPixels,
                    cellHeightPixels
                ),
                operation: "active resize"
            )
        }
    }

    func selectionBegin(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64,
        point: GhosttyRenderSelectionPoint
    ) throws -> GhosttyRenderSelectionOutcome {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var rawPoint = try Self.makeSelectionPoint(point)
            var outcome = Self.makeSelectionOutcome()
            try Self.requireOK(
                ouro_render_client_active_selection_begin(
                    client, &context, &rawPoint, &outcome),
                operation: "selection begin"
            )
            return try Self.decodeSelectionOutcome(outcome)
        }
    }

    func selectionUpdate(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64,
        point: GhosttyRenderSelectionPoint,
        geometry: GhosttyRenderSelectionGeometry,
        rectangle: Bool
    ) throws -> GhosttyRenderSelectionOutcome {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var rawPoint = try Self.makeSelectionPoint(point)
            var rawGeometry = try Self.makeSelectionGeometry(geometry)
            var outcome = Self.makeSelectionOutcome()
            try Self.requireOK(
                ouro_render_client_active_selection_update(
                    client,
                    &context,
                    &rawPoint,
                    &rawGeometry,
                    rectangle ? 1 : 0,
                    &outcome
                ),
                operation: "selection update"
            )
            return try Self.decodeSelectionOutcome(outcome)
        }
    }

    func selectionAutoscroll(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64,
        viewportColumn: UInt16,
        viewportRow: UInt32,
        surfaceX: Double,
        surfaceY: Double,
        geometry: GhosttyRenderSelectionGeometry,
        rectangle: Bool
    ) throws -> GhosttyRenderSelectionOutcome {
        guard surfaceX.isFinite, surfaceY.isFinite else {
            throw GhosttyRenderBridgeError.invalidPayload("Selection autoscroll point is not finite.")
        }
        return try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var rawGeometry = try Self.makeSelectionGeometry(geometry)
            var outcome = Self.makeSelectionOutcome()
            try Self.requireOK(
                ouro_render_client_active_selection_autoscroll(
                    client,
                    &context,
                    viewportColumn,
                    viewportRow,
                    surfaceX,
                    surfaceY,
                    &rawGeometry,
                    rectangle ? 1 : 0,
                    &outcome
                ),
                operation: "selection autoscroll"
            )
            return try Self.decodeSelectionOutcome(outcome)
        }
    }

    func selectionEnd(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64,
        point: GhosttyRenderSelectionPoint?
    ) throws -> GhosttyRenderSelectionOutcome {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var outcome = Self.makeSelectionOutcome()
            if var rawPoint = try point.map(Self.makeSelectionPoint) {
                try Self.requireOK(
                    ouro_render_client_active_selection_end(
                        client, &context, &rawPoint, &outcome),
                    operation: "selection end"
                )
            } else {
                try Self.requireOK(
                    ouro_render_client_active_selection_end(
                        client, &context, nil, &outcome),
                    operation: "selection end"
                )
            }
            return try Self.decodeSelectionOutcome(outcome)
        }
    }

    func selectionCancel(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64
    ) throws -> GhosttyRenderSelectionOutcome {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var outcome = Self.makeSelectionOutcome()
            try Self.requireOK(
                ouro_render_client_active_selection_cancel(client, &context, &outcome),
                operation: "selection cancel"
            )
            return try Self.decodeSelectionOutcome(outcome)
        }
    }

    func copySelection(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64
    ) throws -> String? {
        try onQueue { () -> String? in
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var required = 0
            let probe = ouro_render_client_active_selection_copy(
                client, &context, nil, 0, &required)
            if probe == OURO_RENDER_CLIENT_NO_VALUE { return nil }
            guard probe == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL || probe == OURO_RENDER_CLIENT_OK,
                  required <= 1_024 * 1_024 else {
                try Self.requireOK(probe, operation: "selection copy length")
                throw GhosttyRenderBridgeError.invalidPayload("Selection copy exceeds the 1 MiB cap.")
            }
            if required == 0 { return "" }
            let storage = try GhosttyFallibleBuffer<UInt8>(
                count: required,
                byteLimit: 1_024 * 1_024
            )
            var written = 0
            let result = ouro_render_client_active_selection_copy(
                client, &context, storage.pointer, storage.count, &written)
            try Self.requireOK(result, operation: "selection copy")
            guard written == required,
                  let pointer = storage.pointer,
                  let value = String(bytes: UnsafeBufferPointer(start: pointer, count: written), encoding: .utf8)
            else {
                throw GhosttyRenderBridgeError.invalidPayload(
                    "Selection copy returned a changing length or invalid UTF-8.")
            }
            return value
      }
    }

    /// Copies the full bounded formatter projection only for an explicit Find
    /// request. The returned String is owned by the caller and is not retained
    /// by the render bridge.
    func plainText(
      stream: GhosttyRenderStream,
      minimumStateSequence: UInt64
    ) throws -> String {
      try onQueue {
        var context = try Self.makeProjectionContext(
          stream: stream, minimumStateSequence: minimumStateSequence)
        var required = 0
        let probe = ouro_render_client_active_copy_plain_text(
          client, &context, nil, 0, &required)
        guard probe == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL || probe == OURO_RENDER_CLIENT_OK,
              required <= 8 * 1024 * 1024
        else {
          try Self.requireOK(probe, operation: "full scrollback text length")
          return ""
        }
        if required == 0 { return "" }
        let storage = try GhosttyFallibleBuffer<UInt8>(
          count: required,
          byteLimit: 8 * 1024 * 1024
        )
        var written = 0
        let result = ouro_render_client_active_copy_plain_text(
          client,
          &context,
          storage.pointer,
          storage.count,
          &written
        )
        try Self.requireOK(result, operation: "full scrollback text")
        guard written == required, let pointer = storage.pointer,
              let value = String(
                bytes: UnsafeBufferPointer(start: pointer, count: written),
                encoding: .utf8
              )
        else {
          throw GhosttyRenderBridgeError.invalidPayload(
            "Full scrollback text returned a changing length or invalid UTF-8.")
        }
        return value
      }
    }

    /// Captures text and its row coordinate space while holding the render
    /// bridge's serial FFI queue. Live PTY feeds cannot interleave between the
    /// formatter projection and scrollbar metadata.
    func findProjection(
      stream: GhosttyRenderStream,
      minimumStateSequence: UInt64
    ) throws -> GhosttyRenderFindProjection {
      try onQueue {
        GhosttyRenderFindProjection(
          text: try plainText(
            stream: stream,
            minimumStateSequence: minimumStateSequence
          ),
          scrollbar: try scrollbar(
            stream: stream,
            minimumStateSequence: minimumStateSequence
          )
        )
      }
    }

    /// Resolves an OSC 8 URI only for one visible cell and only on demand.
    /// The renderer never retains URI strings in its bounded GPU/CPU cache.
    func hyperlinkURI(
      stream: GhosttyRenderStream,
      minimumStateSequence: UInt64,
      column: UInt16,
      row: UInt32
    ) throws -> URL? {
      try onQueue { () -> URL? in
        var context = try Self.makeProjectionContext(
          stream: stream, minimumStateSequence: minimumStateSequence)
        var required = 0
        let probe = ouro_render_client_active_hyperlink_uri(
          client, &context, column, row, nil, 0, &required)
        if probe == OURO_RENDER_CLIENT_NO_VALUE { return nil }
        guard probe == OURO_RENDER_CLIENT_BUFFER_TOO_SMALL || probe == OURO_RENDER_CLIENT_OK,
              required > 0,
              required <= 4_096
        else {
          try Self.requireOK(probe, operation: "hyperlink URI length")
          return nil
        }
        let storage = try GhosttyFallibleBuffer<UInt8>(
          count: required,
          byteLimit: 4_096
        )
        var written = 0
        let result = ouro_render_client_active_hyperlink_uri(
          client,
          &context,
          column,
          row,
          storage.pointer,
          storage.count,
          &written
        )
        try Self.requireOK(result, operation: "hyperlink URI")
        guard written == required, let pointer = storage.pointer else {
          throw GhosttyRenderBridgeError.invalidPayload(
            "Hyperlink URI returned a changing length.")
        }
        guard let value = String(
          bytes: UnsafeBufferPointer(start: pointer, count: written),
          encoding: .utf8
        ) else {
          // Invalid OSC 8 bytes are not the same thing as an absent link. Fail
          // closed with an actionable bridge error so a malformed payload is
          // observable and can never fall through to another click action.
          throw GhosttyRenderBridgeError.invalidPayload(
            "Hyperlink URI is not valid UTF-8."
          )
        }
        return TerminalHyperlinkPolicy.url(value)
      }
    }

    func takeBells(
      stream: GhosttyRenderStream,
      minimumStateSequence: UInt64
    ) throws -> UInt32 {
      try onQueue {
        var context = try Self.makeProjectionContext(
          stream: stream, minimumStateSequence: minimumStateSequence)
        var count: UInt32 = 0
        try Self.requireOK(
          ouro_render_client_active_take_bells(client, &context, &count),
          operation: "bell drain"
        )
        return count
      }
    }

    func scrollViewport(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64,
        request: GhosttyRenderViewportScroll
    ) throws {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var raw = Self.makeViewportScroll(request)
            try Self.requireOK(
                ouro_render_client_active_viewport_scroll(client, &context, &raw),
                operation: "viewport scroll"
            )
        }
    }

    func scrollbar(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64
    ) throws -> GhosttyRenderScrollbar {
        try onQueue {
            var context = try Self.makeProjectionContext(
                stream: stream, minimumStateSequence: minimumStateSequence)
            var raw = OuroRenderClientScrollbar()
            raw.size = MemoryLayout<OuroRenderClientScrollbar>.size
            raw.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
            try Self.requireOK(
                ouro_render_client_active_scrollbar(client, &context, &raw),
                operation: "scrollbar"
            )
            guard raw.length <= raw.total, raw.offset <= raw.total - raw.length else {
                throw GhosttyRenderBridgeError.invalidPayload("Scrollbar range is out of bounds.")
            }
            return GhosttyRenderScrollbar(
                observedStateSequence: raw.observed_state_seq,
                total: raw.total,
                offset: raw.offset,
                length: raw.length
            )
        }
    }

    func beginCandidate(
        stream: GhosttyRenderStream,
        checkpointStateSequence: UInt64
    ) throws -> GhosttyRenderCandidate {
        try onQueue {
            var identity = try Self.makeStream(stream)
            var token: UInt64 = 0
            try Self.requireOK(
                ouro_render_client_candidate_begin(
                    client,
                    &identity,
                    checkpointStateSequence,
                    &token
                ),
                operation: "candidate begin"
            )
            guard token != 0 else {
                throw GhosttyRenderBridgeError.invalidPayload("Candidate begin returned an invalid zero token.")
            }
            return GhosttyRenderCandidate(owner: owner, rawValue: token)
        }
    }

    func restoreCandidate(
        _ candidate: GhosttyRenderCandidate,
        manifest: GhosttyRenderRecoveryManifest,
        checkpointStateSequence: UInt64,
        checkpoint: Data
    ) throws {
        try validate(candidate)
        try validateRecoveryManifest(manifest)
        guard checkpoint.count <= limits.snapshotBytes else {
            throw GhosttyRenderBridgeError.invalidPayload("Candidate checkpoint exceeds the configured snapshot ceiling.")
        }
        try onQueue {
            var value = rawManifest
            let result = checkpoint.withUnsafeBytes { payload in
                ouro_render_client_candidate_import_checkpoint(
                    client,
                    candidate.rawValue,
                    &value,
                    checkpointStateSequence,
                    payload.bindMemory(to: UInt8.self).baseAddress,
                    payload.count
                )
            }
            try Self.requireOK(result, operation: "candidate checkpoint import")
        }
    }

    func feedCandidate(
        _ candidate: GhosttyRenderCandidate,
        stateSequence: UInt64,
        bytes: Data
    ) throws {
        try validate(candidate)
        guard bytes.count <= limits.feedBytes else {
            throw GhosttyRenderBridgeError.invalidPayload("Candidate feed exceeds the configured byte ceiling.")
        }
        try onQueue {
            let result = bytes.withUnsafeBytes { payload in
                ouro_render_client_candidate_feed(
                    client,
                    candidate.rawValue,
                    stateSequence,
                    payload.bindMemory(to: UInt8.self).baseAddress,
                    payload.count
                )
            }
            try Self.requireOK(result, operation: "candidate feed")
        }
    }

    func resizeCandidate(
        _ candidate: GhosttyRenderCandidate,
        stateSequence: UInt64,
        columns: UInt16,
        rows: UInt16,
        cellWidthPixels: UInt32,
        cellHeightPixels: UInt32
    ) throws {
        try validate(candidate)
        _ = try Self.validateGrid(columns: columns, rows: rows, maximumCells: limits.maximumCells)
        guard cellWidthPixels > 0, cellHeightPixels > 0 else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Terminal cell dimensions must be non-zero.")
        }
        try onQueue {
            try Self.requireOK(
                ouro_render_client_candidate_resize(
                    client,
                    candidate.rawValue,
                    stateSequence,
                    columns,
                    rows,
                    cellWidthPixels,
                    cellHeightPixels
                ),
                operation: "candidate resize"
            )
        }
    }

    func commitCandidate(
        _ candidate: GhosttyRenderCandidate,
        attachedReadyStateSequence: UInt64
    ) throws {
        try validate(candidate)
        try onQueue {
            try Self.requireOK(
                ouro_render_client_candidate_commit(
                    client,
                    candidate.rawValue,
                    attachedReadyStateSequence
                ),
                operation: "candidate commit"
            )
        }
    }

    func abortCandidate(_ candidate: GhosttyRenderCandidate) throws {
        try validate(candidate)
        try onQueue {
            try Self.requireOK(
                ouro_render_client_candidate_abort(client, candidate.rawValue),
                operation: "candidate abort"
            )
        }
    }

    func forceFullFrame() throws {
        try onQueue {
            try Self.requireOK(
                ouro_render_client_force_full_frame(client),
                operation: "force full frame"
            )
        }
    }

    func cancelFrameRetry() throws {
        try onQueue {
            try Self.requireOK(
                ouro_render_client_cancel_frame_retry(client),
                operation: "frame retry cancel"
            )
        }
    }

    func acquireFrame() throws -> GhosttyRenderFrameLease {
        try onQueue {
            var metadata = OuroRenderClientBulkFrame()
            metadata.size = MemoryLayout<OuroRenderClientBulkFrame>.size
            metadata.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
            try Self.requireOK(
                ouro_render_client_acquire_frame(client, &metadata),
                operation: "frame acquire"
            )

            var mustRetry = true
            defer {
                if mustRetry {
                    _ = ouro_render_client_finish_frame_lease(
                        client,
                        metadata.generation,
                        OURO_RENDER_CLIENT_FRAME_RETRY
                    )
                }
            }

            try validateFrameCounts(metadata)
            let rows = try GhosttyFallibleBuffer<OuroRenderClientRow>(
                count: metadata.row_count,
                byteLimit: limits.cpuCacheBytes
            )
            let cells = try GhosttyFallibleBuffer<OuroRenderClientCell>(
                count: metadata.cell_count,
                byteLimit: limits.cpuCacheBytes
            )
            let graphemes = try GhosttyFallibleBuffer<UInt8>(
                count: metadata.grapheme_bytes,
                byteLimit: limits.cpuCacheBytes
            )
            var copied = OuroRenderClientBulkFrame()
            copied.size = MemoryLayout<OuroRenderClientBulkFrame>.size
            copied.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)

            let copyResult = ouro_render_client_copy_frame_bulk(
                client,
                metadata.generation,
                rows.pointer,
                rows.count,
                cells.pointer,
                cells.count,
                graphemes.pointer,
                graphemes.count,
                &copied
            )
            try Self.requireOK(copyResult, operation: "bulk frame copy")
            guard copied.generation == metadata.generation,
                  copied.row_count == metadata.row_count,
                  copied.cell_count == metadata.cell_count,
                  copied.grapheme_bytes == metadata.grapheme_bytes else {
                throw GhosttyRenderBridgeError.invalidPayload("Bulk frame counts changed inside an active lease.")
            }
            try validateFrameCounts(copied)
            let frame = try decodeFrame(
                copied,
                rows: rows,
                cells: cells,
                graphemes: graphemes
            )
            mustRetry = false
            return GhosttyRenderFrameLease(bridge: self, frame: frame)
        }
    }

    func memoryInfo() throws -> GhosttyRenderMemoryInfo {
        try onQueue {
            var raw = OuroRenderClientMemoryInfo()
            raw.size = MemoryLayout<OuroRenderClientMemoryInfo>.size
            raw.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
            try Self.requireOK(
                ouro_render_client_memory_info(client, &raw),
                operation: "memory info"
            )
            return GhosttyRenderMemoryInfo(
                cpuCacheLiveBytes: raw.cpu_cache_live_bytes,
                cpuCachePeakBytes: raw.cpu_cache_peak_bytes,
                cpuCacheLimitBytes: raw.cpu_cache_limit_bytes,
                projectionLiveBytes: raw.projection_live_bytes,
                projectionPeakBytes: raw.projection_peak_bytes,
                projectionLimitBytes: raw.projection_limit_bytes,
                projectionAllocationFailures: raw.projection_allocation_failures,
                activeEngineLiveBytes: raw.active_engine_live_bytes,
                activeEnginePeakBytes: raw.active_engine_peak_bytes,
                activeEngineLimitBytes: raw.active_engine_limit_bytes,
                activeEngineAllocationFailures: raw.active_engine_allocation_failures,
                candidatePresent: raw.candidate_present != 0,
                candidateEngineLiveBytes: raw.candidate_engine_live_bytes,
                candidateEnginePeakBytes: raw.candidate_engine_peak_bytes,
                candidateEngineLimitBytes: raw.candidate_engine_limit_bytes,
                candidateEngineAllocationFailures: raw.candidate_engine_allocation_failures,
                pageReservedBytes: raw.page_reserved_bytes,
                pagePeakReservedBytes: raw.page_peak_reserved_bytes,
                pageLimitBytes: raw.page_limit_bytes,
                pageDenialCount: raw.page_denial_count,
                pageChildFailureCount: raw.page_child_failure_count,
                activeTerminalCount: Int(raw.active_terminal_count),
                candidateTerminalCount: Int(raw.candidate_terminal_count),
                projectionCount: Int(raw.projection_count)
            )
        }
    }

    fileprivate func finishFrameLease(
        generation: UInt64,
        disposition: GhosttyRenderLeaseDisposition
    ) throws {
        try onQueue {
            let rawDisposition = disposition == .consumed
                ? OURO_RENDER_CLIENT_FRAME_CONSUMED
                : OURO_RENDER_CLIENT_FRAME_RETRY
            try Self.requireOK(
                ouro_render_client_finish_frame_lease(client, generation, rawDisposition),
                operation: "frame lease finish"
            )
        }
    }

    private func validate(_ candidate: GhosttyRenderCandidate) throws {
        guard candidate.owner == owner, candidate.rawValue != 0 else {
            throw GhosttyRenderBridgeError.invalidPayload("Candidate token belongs to another render client.")
        }
    }

    private func validateFrameCounts(_ frame: OuroRenderClientBulkFrame) throws {
        let grid = try Self.validateGrid(
            columns: frame.columns,
            rows: frame.rows,
            maximumCells: limits.maximumCells
        )
        let graphemeLimit = grid.multipliedReportingOverflow(
            by: limits.maximumGraphemeBytesPerCell
        )
        guard !graphemeLimit.overflow,
              frame.row_count >= 0, frame.row_count <= Int(frame.rows),
              frame.cell_count >= 0, frame.cell_count <= grid,
              frame.grapheme_bytes >= 0, frame.grapheme_bytes <= graphemeLimit.partialValue,
              frame.grapheme_bytes <= limits.cpuCacheBytes else {
            throw GhosttyRenderBridgeError.invalidPayload("Bulk frame exceeds the checked Swift allocation bounds.")
        }
        let rowBytes = frame.row_count.multipliedReportingOverflow(
            by: MemoryLayout<OuroRenderClientRow>.stride
        )
        let cellBytes = frame.cell_count.multipliedReportingOverflow(
            by: MemoryLayout<OuroRenderClientCell>.stride
        )
        let metadataBytes = rowBytes.partialValue.addingReportingOverflow(cellBytes.partialValue)
        let totalBytes = metadataBytes.partialValue.addingReportingOverflow(frame.grapheme_bytes)
        guard !rowBytes.overflow, !cellBytes.overflow, !metadataBytes.overflow, !totalBytes.overflow,
              totalBytes.partialValue <= limits.cpuCacheBytes else {
            throw GhosttyRenderBridgeError.invalidPayload("Bulk frame metadata byte count overflowed its allocation ceiling.")
        }
    }

    private func onQueue<T>(_ body: () throws -> T) throws -> T {
        if DispatchQueue.getSpecific(key: queueKey) == owner {
            dispatchPrecondition(condition: .onQueue(ffiQueue))
            return try body()
        }
        return try ffiQueue.sync {
            dispatchPrecondition(condition: .onQueue(ffiQueue))
            return try body()
        }
    }

    private static func validate(_ configuration: GhosttyRenderConfiguration) throws -> Limits {
        guard configuration.columns > 0, configuration.rows > 0,
              configuration.cellWidthPixels > 0, configuration.cellHeightPixels > 0,
              configuration.scrollbackMaximumBytes > 0,
              configuration.scrollbackMaximumLines > 0,
              configuration.snapshotMaximumBytes > 0,
              configuration.engineMemoryMaximumBytes > 0,
              configuration.projectionMemoryMaximumBytes > 0,
              configuration.sharedPageBudgetMaximumBytes > 0,
              (1...256).contains(configuration.maximumGraphemeBytes),
              configuration.maximumFeedBytes > 0,
              configuration.cpuCacheMaximumBytes > 0 else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Ghostty render configuration contains a zero or out-of-range bound.")
        }
        _ = try makeStream(configuration.initialStream)
        _ = try validateGrid(columns: configuration.columns, rows: configuration.rows, maximumCells: 131_072)
        return Limits(
            maximumCells: 131_072,
            maximumGraphemeBytesPerCell: configuration.maximumGraphemeBytes,
            feedBytes: configuration.maximumFeedBytes,
            snapshotBytes: configuration.snapshotMaximumBytes,
            cpuCacheBytes: configuration.cpuCacheMaximumBytes
        )
    }

    private static func validateGrid(
        columns: UInt16,
        rows: UInt16,
        maximumCells: Int
    ) throws -> Int {
        guard columns > 0, rows > 0 else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Terminal grid dimensions must be non-zero.")
        }
        let product = Int(columns).multipliedReportingOverflow(by: Int(rows))
        guard !product.overflow, product.partialValue <= maximumCells else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Terminal grid exceeds the 131,072-cell render ceiling.")
        }
        return product.partialValue
    }

    private static func makeConfig(
        _ configuration: GhosttyRenderConfiguration
    ) throws -> OuroRenderClientConfig {
        var value = OuroRenderClientConfig()
        value.size = MemoryLayout<OuroRenderClientConfig>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        value.initial_stream = try makeStream(configuration.initialStream)
        value.columns = configuration.columns
        value.rows = configuration.rows
        value.cell_width_px = configuration.cellWidthPixels
        value.cell_height_px = configuration.cellHeightPixels
        value.scrollback_max_bytes = configuration.scrollbackMaximumBytes
        value.scrollback_max_lines = configuration.scrollbackMaximumLines
        value.snapshot_max_bytes = configuration.snapshotMaximumBytes
        value.engine_memory_max_bytes = configuration.engineMemoryMaximumBytes
        value.projection_memory_max_bytes = configuration.projectionMemoryMaximumBytes
        value.shared_page_budget_max_bytes = configuration.sharedPageBudgetMaximumBytes
        value.max_grapheme_bytes = configuration.maximumGraphemeBytes
        value.max_feed_bytes = configuration.maximumFeedBytes
        value.cpu_cache_max_bytes = configuration.cpuCacheMaximumBytes
        value.initial_state_seq = configuration.initialStateSequence
        return value
    }

    private static func makeStream(_ stream: GhosttyRenderStream) throws -> OuroRenderStreamIdentity {
        let utf8 = stream.terminalID.utf8
        guard stream.brokerGeneration > 0, !utf8.isEmpty,
              utf8.count <= Int(OURO_RENDER_TERMINAL_ID_MAX_BYTES),
              !utf8.contains(0) else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Render stream identity is empty, oversized, or has no broker generation.")
        }
        var value = OuroRenderStreamIdentity()
        value.size = MemoryLayout<OuroRenderStreamIdentity>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        value.broker_generation = stream.brokerGeneration
        value.terminal_id_length = utf8.count
        withUnsafeMutableBytes(of: &value.terminal_id) { destination in
            var index = 0
            for byte in utf8 {
                destination[index] = byte
                index += 1
            }
        }
        return value
    }

    private static func makeProjectionContext(
        stream: GhosttyRenderStream,
        minimumStateSequence: UInt64
    ) throws -> OuroRenderClientProjectionContext {
        var value = OuroRenderClientProjectionContext()
        value.size = MemoryLayout<OuroRenderClientProjectionContext>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        value.stream = try makeStream(stream)
        value.minimum_state_seq = minimumStateSequence
        return value
    }

    private static func makeSelectionPoint(
        _ point: GhosttyRenderSelectionPoint
    ) throws -> OuroRenderClientSelectionPoint {
        guard point.surfaceX.isFinite, point.surfaceY.isFinite,
              point.surfaceX >= 0, point.surfaceY >= 0 else {
            throw GhosttyRenderBridgeError.invalidPayload("Selection point is negative or not finite.")
        }
        var value = OuroRenderClientSelectionPoint()
        value.size = MemoryLayout<OuroRenderClientSelectionPoint>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        value.column = point.column
        value.row = point.row
        value.surface_x = point.surfaceX
        value.surface_y = point.surfaceY
        value.has_time = point.timeNanoseconds == nil ? 0 : 1
        value.time_ns = point.timeNanoseconds ?? 0
        return value
    }

    private static func makeSelectionGeometry(
        _ geometry: GhosttyRenderSelectionGeometry
    ) throws -> OuroRenderClientSelectionGeometry {
        guard geometry.columns > 0,
              geometry.cellWidth.isFinite, geometry.cellWidth > 0,
              geometry.paddingLeft.isFinite, geometry.paddingLeft >= 0,
              geometry.screenHeight.isFinite, geometry.screenHeight > 0 else {
            throw GhosttyRenderBridgeError.invalidPayload("Selection geometry is invalid.")
        }
        var value = OuroRenderClientSelectionGeometry()
        value.size = MemoryLayout<OuroRenderClientSelectionGeometry>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        value.columns = geometry.columns
        value.cell_width = geometry.cellWidth
        value.padding_left = geometry.paddingLeft
        value.screen_height = geometry.screenHeight
        return value
    }

    private static func makeSelectionOutcome() -> OuroRenderClientSelectionOutcome {
        var value = OuroRenderClientSelectionOutcome()
        value.size = MemoryLayout<OuroRenderClientSelectionOutcome>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        return value
    }

    private static func decodeSelectionOutcome(
        _ value: OuroRenderClientSelectionOutcome
    ) throws -> GhosttyRenderSelectionOutcome {
        guard let autoscroll = GhosttyRenderSelectionAutoscroll(
            rawValue: Int32(value.autoscroll_direction.rawValue)
        ) else {
            throw GhosttyRenderBridgeError.invalidPayload(
                "Selection outcome contains an unknown autoscroll direction.")
        }
        return GhosttyRenderSelectionOutcome(
            observedStateSequence: value.observed_state_seq,
            hasSelection: value.selection_has_value != 0,
            autoscroll: autoscroll
        )
    }

    private static func makeViewportScroll(
        _ request: GhosttyRenderViewportScroll
    ) -> OuroRenderClientViewportScroll {
        var value = OuroRenderClientViewportScroll()
        value.size = MemoryLayout<OuroRenderClientViewportScroll>.size
        value.abi_version = UInt32(OURO_RENDER_CLIENT_ABI_VERSION)
        switch request {
        case .top:
            value.kind = OURO_RENDER_CLIENT_VIEWPORT_SCROLL_TOP
        case .bottom:
            value.kind = OURO_RENDER_CLIENT_VIEWPORT_SCROLL_BOTTOM
        case .delta(let delta):
            value.kind = OURO_RENDER_CLIENT_VIEWPORT_SCROLL_DELTA
            value.delta = delta
        case .row(let row):
            value.kind = OURO_RENDER_CLIENT_VIEWPORT_SCROLL_ROW
            value.row = row
        }
        return value
    }

    private static func decodeManifest(
        _ value: OuroRenderClientManifest
    ) throws -> GhosttyRenderRecoveryManifest {
        GhosttyRenderRecoveryManifest(
            terminalEngineABIVersion: value.terminal_engine_abi_version,
            snapshotFormatVersion: value.snapshot_format_version,
            ghosttySourceCommit: try fixedCString(value.ghostty_source_commit),
            snapshotMagic: try fixedCString(value.snapshot_magic),
            unicodeWidthPolicy: try fixedCString(value.unicode_width_policy),
            graphicsPolicy: try fixedCString(value.graphics_policy)
        )
    }

    private static func fixedCString<T>(_ storage: T) throws -> String {
        var copy = storage
        return try withUnsafeBytes(of: &copy) { bytes in
            guard let end = bytes.firstIndex(of: 0), end < bytes.count,
                  let string = String(bytes: bytes[..<end], encoding: .utf8) else {
                throw GhosttyRenderBridgeError.manifestMismatch("Render manifest contains a malformed fixed C string.")
            }
            return string
        }
    }

    private func decodeFrame(
        _ raw: OuroRenderClientBulkFrame,
        rows: GhosttyFallibleBuffer<OuroRenderClientRow>,
        cells: GhosttyFallibleBuffer<OuroRenderClientCell>,
        graphemes: GhosttyFallibleBuffer<UInt8>
    ) throws -> GhosttyRenderFrame {
        guard let dirty = GhosttyRenderDirty(rawValue: raw.dirty) else {
            throw GhosttyRenderBridgeError.invalidPayload("Render frame has an unknown damage kind.")
        }
        for index in 0..<rows.count {
            guard let row = rows.element(at: index) else {
                throw GhosttyRenderBridgeError.invalidPayload("Render row buffer is unexpectedly absent.")
            }
            let end = row.first_cell_index.addingReportingOverflow(row.cell_count)
            guard !end.overflow, end.partialValue <= cells.count, row.y < raw.rows else {
                throw GhosttyRenderBridgeError.invalidPayload("Render row points outside the bulk cell array.")
            }
            if row.selection_has_value != 0 {
                guard row.selection_start_x <= row.selection_end_x,
                      row.selection_end_x < raw.columns else {
                    throw GhosttyRenderBridgeError.invalidPayload("Render row selection is out of bounds.")
                }
            }
        }
        for index in 0..<cells.count {
            guard let cell = cells.element(at: index) else {
                throw GhosttyRenderBridgeError.invalidPayload("Render cell buffer is unexpectedly absent.")
            }
            let end = cell.grapheme_offset.addingReportingOverflow(cell.grapheme_bytes)
            guard !end.overflow, end.partialValue <= graphemes.count,
                  cell.x < raw.columns,
                  cell.grapheme_bytes <= limits.maximumGraphemeBytesPerCell,
                  cell.foreground.kind <= 2,
                  cell.background.kind <= 2,
                  cell.underline_color.kind <= 2,
                  cell.underline.rawValue <= OURO_RENDER_CLIENT_UNDERLINE_DASHED.rawValue else {
                throw GhosttyRenderBridgeError.invalidPayload("Render cell is malformed or points outside the bounded grapheme arena.")
            }
        }
        let cursor: GhosttyRenderCursor?
        if raw.cursor_has_value != 0 {
            guard raw.cursor_x < raw.columns, raw.cursor_y < raw.rows else {
                throw GhosttyRenderBridgeError.invalidPayload("Render cursor is outside the frame bounds.")
            }
            cursor = GhosttyRenderCursor(
                x: raw.cursor_x,
                y: raw.cursor_y,
                wideTail: raw.cursor_wide_tail != 0,
                visible: raw.cursor_visible != 0,
                blinking: raw.cursor_blinking != 0,
                passwordInput: raw.cursor_password_input != 0,
                style: raw.cursor_style,
                color: raw.cursor_color_has_value == 0 ? nil : Self.rgb(raw.cursor_color)
            )
        } else {
            cursor = nil
        }
        return GhosttyRenderFrame(
            stateSequence: raw.state_seq,
            generation: raw.generation,
            dirty: dirty,
            columns: raw.columns,
            rows: raw.rows,
            rowData: GhosttyRenderRows(storage: rows),
            cellData: GhosttyRenderCells(storage: cells),
            graphemes: GhosttyRenderGraphemeArena(storage: graphemes),
            cursor: cursor,
            background: Self.rgb(raw.background),
            foreground: Self.rgb(raw.foreground),
            palette: GhosttyRenderPalette(frame: raw)
        )
    }

    fileprivate static func rgb(_ value: OuroRenderClientRgb) -> GhosttyRenderRGB {
        GhosttyRenderRGB(red: value.r, green: value.g, blue: value.b)
    }

    fileprivate static func color(_ value: OuroRenderClientColor) -> GhosttyRenderColor {
        GhosttyRenderColor(
            kind: value.kind,
            paletteIndex: value.palette_index,
            rgb: rgb(value.rgb)
        )
    }

    private static func requireOK(
        _ result: OuroRenderClientResult,
        operation: String
    ) throws {
        guard result == OURO_RENDER_CLIENT_OK else {
            throw GhosttyRenderBridgeError.ffi(operation: operation, code: result.rawValue)
        }
    }
}
#endif
