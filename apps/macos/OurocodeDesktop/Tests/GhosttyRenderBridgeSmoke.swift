import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw GhosttyRenderBridgeError.invalidPayload("Smoke assertion failed: \(message)")
    }
}

private func waitMain(until predicate: () -> Bool, timeout: TimeInterval = 5) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return predicate()
}

private func viewportRows(_ frame: GhosttyRenderFrame) throws -> [String] {
    var grid = Array(
        repeating: Array(repeating: " ", count: Int(frame.columns)),
        count: Int(frame.rows)
    )
    for rowIndex in 0..<frame.rowData.count {
        guard let row = frame.rowData.row(at: rowIndex) else {
            throw GhosttyRenderBridgeError.invalidPayload("Smoke row disappeared")
        }
        let end = row.firstCellIndex + row.cellCount
        for cellIndex in row.firstCellIndex..<end {
            guard let cell = frame.cellData.cell(at: cellIndex),
                  let grapheme = frame.graphemes.string(in: cell.graphemeRange) else {
                throw GhosttyRenderBridgeError.invalidPayload("Smoke cell disappeared")
            }
            if cell.width > 0 {
                grid[Int(row.y)][Int(cell.x)] = grapheme
            }
        }
    }
    return grid.map { $0.joined().trimmingCharacters(in: .whitespaces) }
}

private func viewportCell(
    _ frame: GhosttyRenderFrame,
    containing grapheme: String
) -> (column: UInt16, row: UInt32)? {
    for rowIndex in 0..<frame.rowData.count {
        guard let row = frame.rowData.row(at: rowIndex) else { continue }
        let end = row.firstCellIndex + row.cellCount
        for cellIndex in row.firstCellIndex..<end {
            guard let cell = frame.cellData.cell(at: cellIndex),
                  frame.graphemes.string(in: cell.graphemeRange) == grapheme else { continue }
            return (cell.x, UInt32(row.y))
        }
    }
    return nil
}

@main
enum GhosttyRenderBridgeSmoke {
    static func main() {
        do {
            try run()
            print("PASS: static Ghostty bridge new/candidate restore/feed/commit/bulk/explicit+RAII retry/memory cardinality")
        } catch {
            FileHandle.standardError.write(Data("FAIL: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GhosttyRenderBridgeError.invalidConfiguration("usage: bridge-smoke OUROCODE_APP")
        }
        let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let infoURL = app.appendingPathComponent("Contents/Info.plist", isDirectory: false)
        guard let info = NSDictionary(contentsOf: infoURL) as? [String: Any] else {
            throw GhosttyRenderBridgeError.invalidConfiguration("Packaged app Info.plist is unreadable")
        }
        let deployment = try GhosttyBrokerDeployment.resolve(infoDictionary: info)
        let bridge = try GhosttyRenderBridge(
            configuration: GhosttyRenderConfiguration(
                initialStream: GhosttyRenderStream(
                    brokerGeneration: 1,
                    terminalID: "swift-bridge-bootstrap"
                ),
                columns: 16,
                rows: 4,
                cellWidthPixels: 8,
                cellHeightPixels: 16,
                initialStateSequence: 0,
                brokerDeployment: deployment
            )
        )
        do {
            try bridge.resizeActive(
                stream: GhosttyRenderStream(brokerGeneration: 1, terminalID: "swift-bridge-bootstrap"),
                stateSequence: 1,
                columns: UInt16.max,
                rows: UInt16.max,
                cellWidthPixels: 8,
                cellHeightPixels: 16
            )
            throw GhosttyRenderBridgeError.invalidPayload("Oversized grid unexpectedly reached the C ABI.")
        } catch GhosttyRenderBridgeError.invalidConfiguration {
            // Expected: checked Swift preflight rejects before mutating state_seq.
        }
        let helper = app
            .appendingPathComponent("Contents/Helpers", isDirectory: true)
            .appendingPathComponent(bridge.bundledHelperName)
        try require(FileManager.default.isExecutableFile(atPath: helper.path), "pin-namespaced helper is absent")
        try require(deployment.buildID != nil, "packaged helper has no executable build identity")
        try require(
            bridge.defaultSocketURL.lastPathComponent.contains(deployment.buildID!),
            "default socket is not executable-build-namespaced"
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("orb-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let socket = directory.appendingPathComponent(
            "g-\(bridge.pinNamespace).sock"
        )
        let process = Process()
        process.executableURL = helper
        process.arguments = [socket.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: directory)
        }
        try require(
            waitMain(until: { FileManager.default.fileExists(atPath: socket.path) }),
            "Ghostty broker socket did not appear"
        )

        let broker = BrokerClient(socketURL: socket)
        defer { broker.stop() }
        var helloResult: Result<BrokerHello, Error>?
        broker.start { helloResult = $0 }
        try require(waitMain(until: { helloResult != nil }), "broker hello timed out")
        let hello = try helloResult!.get()
        guard let brokerManifest = hello.manifest,
              let terminalABI = UInt32(exactly: brokerManifest.terminalABIVersion),
              let snapshotFormat = UInt32(exactly: brokerManifest.snapshotFormatVersion) else {
            throw GhosttyRenderBridgeError.manifestMismatch("Broker omitted its bounded recovery manifest.")
        }
        let exactBrokerManifest = GhosttyRenderRecoveryManifest(
            terminalEngineABIVersion: terminalABI,
            snapshotFormatVersion: snapshotFormat,
            ghosttySourceCommit: brokerManifest.engineSourceCommit,
            snapshotMagic: brokerManifest.snapshotMagic,
            unicodeWidthPolicy: brokerManifest.unicodeWidthPolicy,
            graphicsPolicy: brokerManifest.graphicsPolicy
        )
        try bridge.validateRecoveryManifest(exactBrokerManifest)

        var createdResult: Result<BrokerTerminalSummary, Error>?
        broker.create(
            createNonce: "render-bridge-smoke-\(UUID().uuidString)",
            program: "/bin/sh",
            args: ["-c", "printf 'CHECKPOINT\\r\\n'; exec /bin/cat"],
            currentDirectory: "/tmp",
            environment: ["TERM": "xterm-256color"],
            columns: 16,
            rows: 4
        ) { createdResult = $0 }
        try require(waitMain(until: { createdResult != nil }), "terminal creation timed out")
        let terminal = try createdResult!.get()

        var recoveryResult: Result<BrokerPreparedRecovery, Error>?
        broker.prepareAttachment(terminalID: terminal.id) { recoveryResult = $0 }
        try require(waitMain(until: { recoveryResult != nil }), "checkpoint recovery timed out")
        let recovery = try recoveryResult!.get()
        let target = GhosttyRenderStream(
            brokerGeneration: hello.generation,
            terminalID: terminal.id
        )

        let before = try bridge.memoryInfo()
        try require(
            before.activeTerminalCount == 1 && before.candidateTerminalCount == 0 && before.projectionCount == 1,
            "new client cardinality is not 1/0/1"
        )
        let candidate = try bridge.beginCandidate(
            stream: target,
            checkpointStateSequence: recovery.cutoverStateSequence
        )
        let awaitingCheckpoint = try bridge.memoryInfo()
        try require(
            awaitingCheckpoint.candidatePresent && awaitingCheckpoint.candidateTerminalCount == 0,
            "headless candidate allocated a terminal before checkpoint validation"
        )
        try bridge.restoreCandidate(
            candidate,
            manifest: exactBrokerManifest,
            checkpointStateSequence: recovery.cutoverStateSequence,
            checkpoint: recovery.checkpoint
        )
        let restored = try bridge.memoryInfo()
        try require(
            restored.candidatePresent && restored.candidateTerminalCount == 1 && restored.projectionCount == 1,
            "restored candidate cardinality is not 1/1/1"
        )
        let deltaSequence = recovery.cutoverStateSequence.addingReportingOverflow(1)
        try require(!deltaSequence.overflow, "checkpoint sequence cannot accept a delta")
        try bridge.feedCandidate(
            candidate,
            stateSequence: deltaSequence.partialValue,
            bytes: Data("SWIFT-BRIDGE\r\n".utf8)
        )
        try bridge.commitCandidate(
            candidate,
            attachedReadyStateSequence: deltaSequence.partialValue
        )
        let committed = try bridge.memoryInfo()
        try require(
            !committed.candidatePresent && committed.activeTerminalCount == 1
                && committed.candidateTerminalCount == 0 && committed.projectionCount == 1,
            "committed cardinality is not 1/0/1"
        )

        let resizedSequence = deltaSequence.partialValue.addingReportingOverflow(1)
        try require(!resizedSequence.overflow, "candidate delta sequence cannot accept resize")
        try bridge.resizeActive(
            stream: target,
            stateSequence: resizedSequence.partialValue,
            columns: 32,
            rows: 8,
            cellWidthPixels: 8,
            cellHeightPixels: 16
        )

        let first = try bridge.acquireFrame()
        try require(first.frame.columns == 32 && first.frame.rows == 8, "dynamic grid resize was rejected")
        try require(
            first.frame.graphemes.containsUTF8("SWIFT-BRIDGE"),
            "bulk frame does not contain candidate delta"
        )
        try first.finish(.retry)
        let retry = try bridge.acquireFrame()
        try require(retry.frame == first.frame, "RETRY did not reproduce the byte-identical decoded frame")
        try retry.finish(.consumed)

        let lettersSequence = resizedSequence.partialValue.addingReportingOverflow(1)
        try require(!lettersSequence.overflow, "resized sequence cannot accept letters")
        try bridge.feedActive(
            stream: target,
            stateSequence: lettersSequence.partialValue,
            bytes: Data("ABCDEFG abcdefg ".utf8)
        )
        let letters = try bridge.acquireFrame()
        let letterRows = try viewportRows(letters.frame)
        try require(
            letterRows.contains(where: { $0.contains("ABCDEFG abcdefg") }),
            "partial frame lost its alphabetic graphemes or columns"
        )
        try letters.finish(.consumed)

        let digitsSequence = lettersSequence.partialValue.addingReportingOverflow(1)
        try require(!digitsSequence.overflow, "letters sequence cannot accept digits")
        try bridge.feedActive(
            stream: target,
            stateSequence: digitsSequence.partialValue,
            bytes: Data("1234567 XYZ xyz\r\n".utf8)
        )
        let digits = try bridge.acquireFrame()
        let digitRows = try viewportRows(digits.frame)
        try require(
            digitRows.contains(where: {
                $0.contains("ABCDEFG abcdefg 1234567 XYZ xyz")
            }),
            "successive partial frames compressed or discarded earlier glyph columns"
        )
        try digits.finish(.consumed)

        let linkSequence = digitsSequence.partialValue.addingReportingOverflow(1)
        try require(!linkSequence.overflow, "digits sequence cannot accept OSC 8")
        try bridge.feedActive(
            stream: target,
            stateSequence: linkSequence.partialValue,
            bytes: Data(
                "\u{7}\u{7}\r\n\u{1B}]8;;https://example.com/turn\u{1B}\\L\u{1B}]8;;\u{1B}\\"
                    .utf8
            )
        )
        let linked = try bridge.acquireFrame()
        guard let linkedCell = viewportCell(linked.frame, containing: "L") else {
            throw GhosttyRenderBridgeError.invalidPayload("OSC 8 link cell disappeared")
        }
        try linked.finish(.consumed)
        let resolvedLink = try bridge.hyperlinkURI(
            stream: target,
            minimumStateSequence: linkSequence.partialValue,
            column: linkedCell.column,
            row: linkedCell.row
        )
        try require(
            resolvedLink?.absoluteString == "https://example.com/turn",
            "bounded OSC 8 lookup did not cross the Swift bridge"
        )
        let firstBellDrain = try bridge.takeBells(
            stream: target,
            minimumStateSequence: linkSequence.partialValue
        )
        try require(
            firstBellDrain == 2,
            "bell count did not cross the Swift bridge"
        )
        let secondBellDrain = try bridge.takeBells(
            stream: target,
            minimumStateSequence: linkSequence.partialValue
        )
        try require(
            secondBellDrain == 0,
            "bell drain replayed an earlier notification"
        )

        let invalidLinkSequence = linkSequence.partialValue.addingReportingOverflow(1)
        try require(!invalidLinkSequence.overflow, "OSC 8 sequence cannot accept invalid UTF-8")
        var invalidLink = Data("\r\n\u{1B}]8;;https://example.com/".utf8)
        invalidLink.append(0xff)
        invalidLink.append(Data("\u{1B}\\☃\u{1B}]8;;\u{1B}\\".utf8))
        try bridge.feedActive(
            stream: target,
            stateSequence: invalidLinkSequence.partialValue,
            bytes: invalidLink
        )
        let malformed = try bridge.acquireFrame()
        guard let malformedCell = viewportCell(malformed.frame, containing: "☃") else {
            throw GhosttyRenderBridgeError.invalidPayload("Malformed OSC 8 link cell disappeared")
        }
        try malformed.finish(.consumed)
        var invalidUTF8Rejected = false
        do {
            _ = try bridge.hyperlinkURI(
                stream: target,
                minimumStateSequence: invalidLinkSequence.partialValue,
                column: malformedCell.column,
                row: malformedCell.row
            )
        } catch GhosttyRenderBridgeError.invalidPayload {
            invalidUTF8Rejected = true
        }
        try require(invalidUTF8Rejected, "invalid UTF-8 OSC 8 payload looked like no link")

        let invalidMetadataSequence = invalidLinkSequence.partialValue.addingReportingOverflow(1)
        try require(!invalidMetadataSequence.overflow, "link sequence cannot accept metadata")
        var invalidMetadataBytes = Data([0x1b, 0x5d, 0x30, 0x3b, 0xff, 0x07])
        invalidMetadataBytes.append(Data("metadata-feed-survived".utf8))
        try require(
            GhosttyRenderBridge.decodeMetadataBytes([0xff]) == .invalid,
            "invalid UTF-8 metadata decoder did not fail closed"
        )
        _ = try bridge.feedActive(
            stream: target,
            stateSequence: invalidMetadataSequence.partialValue,
            bytes: invalidMetadataBytes
        )

        let semanticSequence = invalidMetadataSequence.partialValue.addingReportingOverflow(1)
        try require(!semanticSequence.overflow, "digits sequence cannot accept semantic colors")
        try bridge.feedActive(
            stream: target,
            stateSequence: semanticSequence.partialValue,
            bytes: Data(
                "\u{1B}]10;#123456\u{1B}\\"
                    .appending("\u{1B}]11;#234567\u{1B}\\")
                    .appending("\u{1B}]12;#345678\u{1B}\\")
                    .appending("\r\n\u{1B}[4;58;2;4;5;6mU\u{1B}[0m")
                    .utf8
            )
        )
        let semantic = try bridge.acquireFrame()
        try require(
            semantic.frame.foreground == GhosttyRenderRGB(red: 0x12, green: 0x34, blue: 0x56),
            "OSC 10 default foreground did not cross the Swift render ABI"
        )
        try require(
            semantic.frame.background == GhosttyRenderRGB(red: 0x23, green: 0x45, blue: 0x67),
            "OSC 11 default background did not cross the Swift render ABI"
        )
        try require(
            semantic.frame.cursor?.color == GhosttyRenderRGB(red: 0x34, green: 0x56, blue: 0x78),
            "OSC 12 cursor color did not cross the Swift render ABI"
        )
        var styledUnderline: GhosttyRenderCell?
        for index in 0..<semantic.frame.cellData.count {
            guard let cell = semantic.frame.cellData.cell(at: index),
                  semantic.frame.graphemes.string(in: cell.graphemeRange) == "U" else { continue }
            styledUnderline = cell
            break
        }
        try require(styledUnderline?.underline != 0, "SGR 4 underline style disappeared")
        try require(
            styledUnderline?.underlineColor == GhosttyRenderColor(
                kind: 2,
                paletteIndex: 0,
                rgb: GhosttyRenderRGB(red: 4, green: 5, blue: 6)
            ),
            "SGR 58 underline color did not cross the Swift render ABI"
        )
        try semantic.finish(.consumed)

        try bridge.forceFullFrame()
        var droppedLease: GhosttyRenderFrameLease? = try bridge.acquireFrame()
        let droppedFrame = droppedLease!.frame
        droppedLease = nil
        let automaticRetry = try bridge.acquireFrame()
        try require(
            automaticRetry.frame == droppedFrame,
            "Dropped RAII lease did not default to lossless RETRY"
        )
        try automaticRetry.finish(.consumed)

        var terminationAccepted = false
        broker.terminate(terminalID: terminal.id) { result in
            terminationAccepted = (try? result.get()) != nil
        }
        try require(waitMain(until: { terminationAccepted }), "terminal cleanup was not accepted")
    }
}
