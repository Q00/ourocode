import Foundation

// Build and run against an explicitly launched, disposable broker:
//
// swiftc -O Sources/OurocodeDesktop/NormalizedTerminalInput.swift \
//   Sources/OurocodeDesktop/BrokerFlowControl.swift \
//   Sources/OurocodeDesktop/SessionMessageContract.swift \
//   Sources/OurocodeDesktop/SessionMessageStateStore.swift \
//   Sources/OurocodeDesktop/SessionMessageGatewayClient.swift \
//   Sources/OurocodeDesktop/BrokerClient.swift \
//   Tests/BrokerFanoutMemoryFixture.swift -o /tmp/ourocode-fanout-memory
// target/release/ouro-broker-v4-ghostty /tmp/ourocode-memory.sock
// /tmp/ourocode-fanout-memory /tmp/ourocode-memory.sock 32 30
//
// During READY, sample only the printed fixture PID and the explicitly
// launched broker PID with scripts/perf/macos_process_sample.py. The 32
// `/bin/cat` children deliberately isolate PTY/broker cost from the much larger
// and workload-dependent memory owned by real Codex or Claude processes.

private func waitMain(until predicate: () -> Bool, timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

@main
enum BrokerFanoutMemoryFixture {
    static func main() {
        guard CommandLine.arguments.count == 4,
              let terminalCount = Int(CommandLine.arguments[2]),
              (1...32).contains(terminalCount),
              let holdSeconds = TimeInterval(CommandLine.arguments[3]),
              holdSeconds >= 0 else {
            fail("usage: fixture SOCKET TERMINAL_COUNT HOLD_SECONDS")
        }

        let client = BrokerClient(
            socketURL: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        var connected = false
        var connectionFailure: Error?
        var terminals: [BrokerTerminalSummary] = []

        client.start { result in
            switch result {
            case .success:
                connected = true
            case .failure(let error):
                connectionFailure = error
            }
        }
        guard waitMain(
            until: { connected || connectionFailure != nil },
            timeout: 5
        ), connected else {
            fail("broker connection failed: \(String(describing: connectionFailure))")
        }

        for index in 0..<terminalCount {
            var result: Result<BrokerTerminalSummary, Error>?
            client.create(
                createNonce: "memory-fixture-\(ProcessInfo.processInfo.processIdentifier)-\(index)",
                program: "/bin/cat",
                args: [],
                currentDirectory: "/tmp",
                environment: ["TERM": "xterm-256color"],
                columns: 80,
                rows: 24
            ) { result = $0 }
            guard waitMain(until: { result != nil }, timeout: 5) else {
                fail("terminal \(index) create timed out")
            }
            do {
                terminals.append(try result!.get())
            } catch {
                fail("terminal \(index) create failed: \(error)")
            }
        }

        print("READY terminals=\(terminals.count) fixture_pid=\(ProcessInfo.processInfo.processIdentifier)")
        FileHandle.standardOutput.synchronizeFile()
        _ = waitMain(until: { false }, timeout: holdSeconds)

        for terminal in terminals {
            client.terminate(terminalID: terminal.id) { _ in }
        }
        _ = waitMain(until: { false }, timeout: 0.25)
        client.stop()
        print("DONE terminals=\(terminals.count)")
    }
}
