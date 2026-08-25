#if OUROCODE_GHOSTTY_RENDERER
import COuroRender
import Foundation

enum TerminalSplitLayoutFFIResult: Equatable {
    case invalidArgument
    case bufferTooSmall
    case notFound
    case limitExceeded
    case busy
    case cannotCloseLastLeaf
    case staleSnapshot
    case internalError
    case unknown(UInt32)

    fileprivate init?(rawValue: UInt32) {
        switch rawValue {
        case 0:
            return nil
        case 1:
            self = .invalidArgument
        case 2:
            self = .bufferTooSmall
        case 3:
            self = .notFound
        case 4:
            self = .limitExceeded
        case 5:
            self = .busy
        case 6:
            self = .cannotCloseLastLeaf
        case 7:
            self = .staleSnapshot
        case 8:
            self = .internalError
        default:
            self = .unknown(rawValue)
        }
    }
}

enum TerminalSplitLayoutBridgeError: Error, Equatable {
    case invalidConfiguration(String)
    case invalidTerminalID(String)
    case invalidABIOutput(String)
    case ffi(operation: String, result: TerminalSplitLayoutFFIResult)
}

extension TerminalSplitLayoutBridgeError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message), let .invalidTerminalID(message),
             let .invalidABIOutput(message):
            return message
        case let .ffi(operation, result):
            return "Split layout \(operation) failed with \(result)."
        }
    }
}

struct TerminalSplitLayoutConfiguration: Equatable {
    /// The first production release deliberately caps visible renderer owners
    /// at four even though the Rust persistence format can represent more.
    static let maximumProductionLeaves = 4
    static let maximumDepth = Int(OURO_SPLIT_LAYOUT_MAX_DEPTH)
    static let normal = TerminalSplitLayoutConfiguration(uncheckedMaxLeaves: 4, maxDepth: 8)

    let maxLeaves: Int
    let maxDepth: Int

    init(maxLeaves: Int, maxDepth: Int) throws {
        guard (1...Self.maximumProductionLeaves).contains(maxLeaves) else {
            throw TerminalSplitLayoutBridgeError.invalidConfiguration(
                "A production split layout must contain between 1 and 4 leaves."
            )
        }
        guard (1...Self.maximumDepth).contains(maxDepth) else {
            throw TerminalSplitLayoutBridgeError.invalidConfiguration(
                "Split layout depth must be between 1 and \(Self.maximumDepth)."
            )
        }
        self.maxLeaves = maxLeaves
        self.maxDepth = maxDepth
    }

    private init(uncheckedMaxLeaves: Int, maxDepth: Int) {
        self.maxLeaves = uncheckedMaxLeaves
        self.maxDepth = maxDepth
    }
}

enum TerminalSplitAxis: Equatable {
    case leftRight
    case topBottom

    fileprivate var ffiValue: OuroSplitAxis {
        switch self {
        case .leftRight:
            return OURO_SPLIT_AXIS_LEFT_RIGHT
        case .topBottom:
            return OURO_SPLIT_AXIS_TOP_BOTTOM
        }
    }
}

enum TerminalSplitPlacement: Equatable {
    case before
    case after

    fileprivate var ffiValue: OuroSplitPlacement {
        switch self {
        case .before:
            return OURO_SPLIT_PLACEMENT_BEFORE
        case .after:
            return OURO_SPLIT_PLACEMENT_AFTER
        }
    }
}

enum TerminalSplitFocusDirection: Equatable {
    case left
    case right
    case up
    case down

    fileprivate var ffiValue: OuroSplitFocusDirection {
        switch self {
        case .left:
            return OURO_SPLIT_FOCUS_LEFT
        case .right:
            return OURO_SPLIT_FOCUS_RIGHT
        case .up:
            return OURO_SPLIT_FOCUS_UP
        case .down:
            return OURO_SPLIT_FOCUS_DOWN
        }
    }
}

enum TerminalSplitResizeCause: Equatable {
    case dividerCommit
    case keyboard
    case equalize
}

struct TerminalSplitLeafGeometry: Equatable {
    let nodeID: UInt64
    let terminalID: String
    let x: UInt32
    let y: UInt32
    let width: UInt32
    let height: UInt32
}

struct TerminalSplitLayoutSnapshot: Equatable {
    let revision: UInt64
    let focusedTerminalID: String
    let leaves: [TerminalSplitLeafGeometry]
}

struct TerminalSplitFocusChange: Equatable {
    let moved: Bool
    let focusedTerminalID: String
}

struct TerminalSplitPresentationUpdate: Equatable {
    let dividerNodeID: UInt64
    let ratioBasisPoints: UInt16
}

struct TerminalSplitResizeIntent: Equatable {
    let cause: TerminalSplitResizeCause
    let layoutRevision: UInt64
    let affectedTerminalIDs: [String]
}

/// Main-thread UI projection state backed by the Rust split tree.
///
/// This owner intentionally owns no PTY, renderer, broker attachment, process,
/// or scrollback. Its opaque pointer is released exactly once by `deinit`.
@MainActor
final class TerminalSplitLayoutBridge {
    private static let abiVersion = UInt32(OURO_SPLIT_LAYOUT_ABI_VERSION)
    private static let terminalIDMaximumBytes = Int(OURO_SPLIT_TERMINAL_ID_MAX_BYTES)
    private static let layoutUnits = UInt64(OURO_SPLIT_LAYOUT_UNITS)
    private static let maximumSnapshotAttempts = 3

    private let configuration: TerminalSplitLayoutConfiguration
    private var layout: OpaquePointer?

    init(
        initialTerminalID: String,
        configuration: TerminalSplitLayoutConfiguration = .normal
    ) throws {
        self.configuration = configuration
        var rawConfiguration = OuroSplitLayoutConfig(
            size: MemoryLayout<OuroSplitLayoutConfig>.size,
            abi_version: Self.abiVersion,
            max_leaves: UInt32(configuration.maxLeaves),
            max_depth: UInt32(configuration.maxDepth)
        )
        var initialTerminal = try Self.terminalRecord(for: initialTerminalID)
        var created: OpaquePointer?
        let result = ouro_split_layout_new(&rawConfiguration, &initialTerminal, &created)
        try Self.requireSuccess(result, operation: "create")
        guard let created else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Split layout creation succeeded without returning an owner."
            )
        }
        layout = created
    }

    deinit {
        if let owned = layout {
            layout = nil
            ouro_split_layout_free(owned)
        }
    }

    func snapshot() throws -> TerminalSplitLayoutSnapshot {
        let owned = try requireLayout()
        for _ in 0..<Self.maximumSnapshotAttempts {
            if let value = try snapshotAttempt(layout: owned) {
                return value
            }
        }
        throw TerminalSplitLayoutBridgeError.ffi(
            operation: "snapshot",
            result: .staleSnapshot
        )
    }

    func focus(terminalID: String) throws {
        let owned = try requireLayout()
        var terminal = try Self.terminalRecord(for: terminalID)
        try Self.requireSuccess(
            ouro_split_layout_focus(owned, &terminal),
            operation: "focus"
        )
    }

    func moveFocus(_ direction: TerminalSplitFocusDirection) throws -> TerminalSplitFocusChange {
        let owned = try requireLayout()
        var output = Self.blankFocusResult()
        try Self.requireSuccess(
            ouro_split_layout_focus_direction(owned, direction.ffiValue, &output),
            operation: "directional focus"
        )
        let moved = try Self.strictBoolean(output.moved, field: "directional focus moved")
        return TerminalSplitFocusChange(
            moved: moved,
            focusedTerminalID: try Self.terminalID(from: output.focused_terminal)
        )
    }

    func canSplitFocused() throws -> Bool {
        let owned = try requireLayout()
        var value: UInt8 = 0
        try Self.requireSuccess(
            ouro_split_layout_can_split_focused(owned, &value),
            operation: "split availability"
        )
        return try Self.strictBoolean(value, field: "split availability")
    }

    @discardableResult
    func splitFocused(
        axis: TerminalSplitAxis,
        newTerminalID: String,
        placement: TerminalSplitPlacement = .after
    ) throws -> UInt64 {
        let owned = try requireLayout()
        var terminal = try Self.terminalRecord(for: newTerminalID)
        var dividerNodeID: UInt64 = 0
        try Self.requireSuccess(
            ouro_split_layout_split_focused(
                owned,
                axis.ffiValue,
                &terminal,
                placement.ffiValue,
                &dividerNodeID
            ),
            operation: "split focused terminal"
        )
        guard dividerNodeID != 0 else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "A successful split returned an invalid divider node ID."
            )
        }
        return dividerNodeID
    }

    func close(terminalID: String) throws {
        let owned = try requireLayout()
        var terminal = try Self.terminalRecord(for: terminalID)
        try Self.requireSuccess(
            ouro_split_layout_close(owned, &terminal),
            operation: "close terminal leaf"
        )
    }

    func beginDividerDrag(dividerNodeID: UInt64) throws -> TerminalSplitPresentationUpdate {
        let owned = try requireLayout()
        guard dividerNodeID != 0 else {
            throw TerminalSplitLayoutBridgeError.invalidConfiguration(
                "Divider node ID must be nonzero."
            )
        }
        var output = Self.blankPresentationUpdate()
        try Self.requireSuccess(
            ouro_split_layout_begin_divider_drag(owned, dividerNodeID, &output),
            operation: "begin divider drag"
        )
        return try Self.presentationUpdate(from: output)
    }

    func updateDividerDrag(
        positionFromStart: UInt32,
        availableSpan: UInt32
    ) throws -> TerminalSplitPresentationUpdate {
        let owned = try requireLayout()
        guard availableSpan != 0 else {
            throw TerminalSplitLayoutBridgeError.invalidConfiguration(
                "Divider drag span must be nonzero."
            )
        }
        var output = Self.blankPresentationUpdate()
        try Self.requireSuccess(
            ouro_split_layout_update_divider_drag(
                owned,
                positionFromStart,
                availableSpan,
                &output
            ),
            operation: "preview divider drag"
        )
        return try Self.presentationUpdate(from: output)
    }

    func commitDividerDrag() throws -> TerminalSplitResizeIntent? {
        let owned = try requireLayout()
        return try resizeIntent(operation: "commit divider drag") { terminals, capacity, output in
            ouro_split_layout_commit_divider_drag(owned, terminals, capacity, output)
        }
    }

    func cancelDividerDrag() throws -> TerminalSplitPresentationUpdate {
        let owned = try requireLayout()
        var output = Self.blankPresentationUpdate()
        try Self.requireSuccess(
            ouro_split_layout_cancel_divider_drag(owned, &output),
            operation: "cancel divider drag"
        )
        return try Self.presentationUpdate(from: output)
    }

    func resizeDividerFromKeyboard(
        dividerNodeID: UInt64,
        deltaBasisPoints: Int16
    ) throws -> TerminalSplitResizeIntent? {
        let owned = try requireLayout()
        guard dividerNodeID != 0 else {
            throw TerminalSplitLayoutBridgeError.invalidConfiguration(
                "Divider node ID must be nonzero."
            )
        }
        return try resizeIntent(operation: "keyboard divider resize") {
            terminals, capacity, output in
            ouro_split_layout_resize_divider_keyboard(
                owned,
                dividerNodeID,
                deltaBasisPoints,
                terminals,
                capacity,
                output
            )
        }
    }

    /// Equalizes every recursive divider with one FFI mutation and one
    /// coalescible resize intent. The four-pane production cap bounds both
    /// the stack buffer and downstream PTY resize fanout.
    func equalize() throws -> TerminalSplitResizeIntent? {
        let owned = try requireLayout()
        return try resizeIntent(operation: "equalize split layout") {
            terminals, capacity, output in
            ouro_split_layout_equalize(owned, terminals, capacity, output)
        }
    }

    private func requireLayout() throws -> OpaquePointer {
        guard let layout else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split layout owner is unavailable."
            )
        }
        return layout
    }

    /// Returns nil only when the expected revision became stale, in which case
    /// the caller must restart both passes from a fresh snapshot.
    private func snapshotAttempt(layout: OpaquePointer) throws -> TerminalSplitLayoutSnapshot? {
        var header = Self.blankSnapshot()
        try Self.requireSuccess(
            ouro_split_layout_snapshot(layout, &header),
            operation: "snapshot header"
        )
        let focusedTerminalID = try Self.terminalID(from: header.focused_terminal)
        let leafCount = try boundedCount(header.leaf_count, field: "snapshot leaf count")

        var requiredCount = 0
        let query = ouro_split_layout_copy_leaf_geometries(
            layout,
            header.revision,
            nil,
            0,
            &requiredCount
        )
        switch Self.classify(query) {
        case nil:
            guard requiredCount == 0 else {
                throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                    "Geometry count query succeeded with a nonzero required count."
                )
            }
        case .bufferTooSmall:
            break
        case .staleSnapshot:
            return nil
        case let failure?:
            throw TerminalSplitLayoutBridgeError.ffi(
                operation: "query snapshot geometry count",
                result: failure
            )
        }
        guard requiredCount == leafCount, requiredCount > 0 else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Snapshot header and geometry count disagree."
            )
        }

        var records = Array(repeating: Self.blankLeafGeometry(), count: requiredCount)
        var copiedCount = 0
        let copy = records.withUnsafeMutableBufferPointer { buffer in
            ouro_split_layout_copy_leaf_geometries(
                layout,
                header.revision,
                buffer.baseAddress,
                buffer.count,
                &copiedCount
            )
        }
        if Self.classify(copy) == .staleSnapshot {
            return nil
        }
        try Self.requireSuccess(copy, operation: "copy snapshot geometries")
        guard copiedCount == requiredCount else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Snapshot geometry copy returned a different record count."
            )
        }

        let leaves = try records.map(Self.leafGeometry(from:))
        guard Set(leaves.map(\.nodeID)).count == leaves.count,
              Set(leaves.map(\.terminalID)).count == leaves.count else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Snapshot contains duplicate leaf node or terminal IDs."
            )
        }
        guard leaves.contains(where: { $0.terminalID == focusedTerminalID }) else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Snapshot focus does not identify one of its leaves."
            )
        }
        return TerminalSplitLayoutSnapshot(
            revision: header.revision,
            focusedTerminalID: focusedTerminalID,
            leaves: leaves
        )
    }

    private typealias ResizeCall = (
        UnsafeMutablePointer<OuroSplitTerminalId>?,
        Int,
        UnsafeMutablePointer<OuroSplitResizeIntent>?
    ) -> OuroSplitLayoutResult

    private func resizeIntent(
        operation: String,
        call: ResizeCall
    ) throws -> TerminalSplitResizeIntent? {
        var header = Self.blankSnapshot()
        try Self.requireSuccess(
            ouro_split_layout_snapshot(try requireLayout(), &header),
            operation: "\(operation) preflight"
        )
        var capacity = try boundedCount(header.leaf_count, field: "resize buffer leaf count")

        for attempt in 0..<2 {
            var records = Array(repeating: Self.blankTerminalRecord(), count: capacity)
            var output = Self.blankResizeIntent()
            let result = records.withUnsafeMutableBufferPointer { buffer in
                call(buffer.baseAddress, buffer.count, &output)
            }
            if Self.classify(result) == .bufferTooSmall, attempt == 0 {
                let required = try boundedCount(
                    output.affected_count,
                    field: "resize required terminal count"
                )
                guard required > capacity else {
                    throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                        "Resize preflight reported BUFFER_TOO_SMALL without a larger bound."
                    )
                }
                capacity = required
                continue
            }
            try Self.requireSuccess(result, operation: operation)
            return try Self.resizeIntent(from: output, records: records)
        }
        throw TerminalSplitLayoutBridgeError.ffi(operation: operation, result: .bufferTooSmall)
    }

    private func boundedCount(_ value: Int, field: String) throws -> Int {
        guard (1...configuration.maxLeaves).contains(value) else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "\(field) exceeds the configured production bound."
            )
        }
        return value
    }

    private static func terminalRecord(for value: String) throws -> OuroSplitTerminalId {
        let bytes = Array(value.utf8)
        guard !value.isEmpty, value.contains(where: { !$0.isWhitespace }) else {
            throw TerminalSplitLayoutBridgeError.invalidTerminalID(
                "Terminal ID must contain a non-whitespace character."
            )
        }
        guard bytes.count <= terminalIDMaximumBytes else {
            throw TerminalSplitLayoutBridgeError.invalidTerminalID(
                "Terminal ID exceeds the \(terminalIDMaximumBytes)-byte UTF-8 bound."
            )
        }
        guard !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw TerminalSplitLayoutBridgeError.invalidTerminalID(
                "Terminal ID cannot contain control characters."
            )
        }
        var record = blankTerminalRecord()
        record.length = bytes.count
        withUnsafeMutableBytes(of: &record.bytes) { destination in
            destination.copyBytes(from: bytes)
        }
        return record
    }

    private static func terminalID(from record: OuroSplitTerminalId) throws -> String {
        guard record.size >= MemoryLayout<OuroSplitTerminalId>.size,
              record.abi_version == abiVersion,
              (1...terminalIDMaximumBytes).contains(record.length) else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned an invalid terminal ID record header."
            )
        }
        let bytes = withUnsafeBytes(of: record.bytes) { raw in
            Array(raw.prefix(record.length))
        }
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned a terminal ID that is not strict UTF-8."
            )
        }
        do {
            _ = try terminalRecord(for: value)
        } catch {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned a terminal ID outside the production contract."
            )
        }
        return value
    }

    private static func leafGeometry(
        from record: OuroSplitLeafGeometry
    ) throws -> TerminalSplitLeafGeometry {
        guard record.size >= MemoryLayout<OuroSplitLeafGeometry>.size,
              record.abi_version == abiVersion,
              record.node_id != 0,
              record.width != 0,
              record.height != 0,
              UInt64(record.x) + UInt64(record.width) <= layoutUnits,
              UInt64(record.y) + UInt64(record.height) <= layoutUnits else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned invalid normalized leaf geometry."
            )
        }
        return TerminalSplitLeafGeometry(
            nodeID: record.node_id,
            terminalID: try terminalID(from: record.terminal_id),
            x: record.x,
            y: record.y,
            width: record.width,
            height: record.height
        )
    }

    private static func presentationUpdate(
        from record: OuroSplitPresentationUpdate
    ) throws -> TerminalSplitPresentationUpdate {
        guard record.size >= MemoryLayout<OuroSplitPresentationUpdate>.size,
              record.abi_version == abiVersion,
              record.divider_node_id != 0,
              (1_000...9_000).contains(record.ratio_basis_points) else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned an invalid divider presentation update."
            )
        }
        return TerminalSplitPresentationUpdate(
            dividerNodeID: record.divider_node_id,
            ratioBasisPoints: record.ratio_basis_points
        )
    }

    private static func resizeIntent(
        from record: OuroSplitResizeIntent,
        records: [OuroSplitTerminalId]
    ) throws -> TerminalSplitResizeIntent? {
        guard record.size >= MemoryLayout<OuroSplitResizeIntent>.size,
              record.abi_version == abiVersion else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned an invalid resize intent header."
            )
        }
        let hasValue = try strictBoolean(record.has_value, field: "resize intent presence")
        guard hasValue else {
            guard record.affected_count == 0 else {
                throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                    "An empty resize intent returned affected terminals."
                )
            }
            return nil
        }
        guard record.affected_count > 0, record.affected_count <= records.count else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Resize intent terminal count exceeds its caller-owned buffer."
            )
        }
        let cause: TerminalSplitResizeCause
        switch record.cause.rawValue {
        case 0:
            cause = .dividerCommit
        case 1:
            cause = .keyboard
        case 2:
            cause = .equalize
        default:
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned an unknown resize cause."
            )
        }
        let terminalIDs = try records.prefix(record.affected_count).map(terminalID(from:))
        guard Set(terminalIDs).count == terminalIDs.count else {
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "Resize intent contains duplicate terminal IDs."
            )
        }
        return TerminalSplitResizeIntent(
            cause: cause,
            layoutRevision: record.layout_revision,
            affectedTerminalIDs: terminalIDs
        )
    }

    private static func strictBoolean(_ value: UInt8, field: String) throws -> Bool {
        switch value {
        case 0:
            return false
        case 1:
            return true
        default:
            throw TerminalSplitLayoutBridgeError.invalidABIOutput(
                "The split ABI returned a non-boolean \(field)."
            )
        }
    }

    private static func classify(
        _ result: OuroSplitLayoutResult
    ) -> TerminalSplitLayoutFFIResult? {
        TerminalSplitLayoutFFIResult(rawValue: result.rawValue)
    }

    private static func requireSuccess(
        _ result: OuroSplitLayoutResult,
        operation: String
    ) throws {
        if let failure = classify(result) {
            throw TerminalSplitLayoutBridgeError.ffi(operation: operation, result: failure)
        }
    }

    private static func blankTerminalRecord() -> OuroSplitTerminalId {
        var record = OuroSplitTerminalId()
        record.size = MemoryLayout<OuroSplitTerminalId>.size
        record.abi_version = abiVersion
        return record
    }

    private static func blankSnapshot() -> OuroSplitLayoutSnapshot {
        OuroSplitLayoutSnapshot(
            size: MemoryLayout<OuroSplitLayoutSnapshot>.size,
            abi_version: abiVersion,
            revision: 0,
            leaf_count: 0,
            focused_terminal: blankTerminalRecord()
        )
    }

    private static func blankLeafGeometry() -> OuroSplitLeafGeometry {
        OuroSplitLeafGeometry(
            size: MemoryLayout<OuroSplitLeafGeometry>.size,
            abi_version: abiVersion,
            node_id: 0,
            x: 0,
            y: 0,
            width: 0,
            height: 0,
            terminal_id: blankTerminalRecord()
        )
    }

    private static func blankFocusResult() -> OuroSplitFocusResult {
        OuroSplitFocusResult(
            size: MemoryLayout<OuroSplitFocusResult>.size,
            abi_version: abiVersion,
            moved: 0,
            focused_terminal: blankTerminalRecord()
        )
    }

    private static func blankPresentationUpdate() -> OuroSplitPresentationUpdate {
        OuroSplitPresentationUpdate(
            size: MemoryLayout<OuroSplitPresentationUpdate>.size,
            abi_version: abiVersion,
            divider_node_id: 0,
            ratio_basis_points: 0
        )
    }

    private static func blankResizeIntent() -> OuroSplitResizeIntent {
        OuroSplitResizeIntent(
            size: MemoryLayout<OuroSplitResizeIntent>.size,
            abi_version: abiVersion,
            has_value: 0,
            cause: OURO_SPLIT_RESIZE_DIVIDER_COMMIT,
            layout_revision: 0,
            affected_count: 0
        )
    }
}
#endif
