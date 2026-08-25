import Foundation

// Cross-language smoke against the real `ouro-broker-v4` helper. Build with
// Compile with NormalizedTerminalInput.swift and BrokerClient.swift, then pass
// a socket path whose broker is already running.

private func waitMain(until predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !predicate(), Date() < deadline {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    return predicate()
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum BrokerClientV4RealSmoke {
    static func main() {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(Data("usage: real-smoke SOCKET\n".utf8))
            exit(64)
        }
        let socket = URL(fileURLWithPath: CommandLine.arguments[1])
        let client = BrokerClient(socketURL: socket)
        var hello: BrokerHello?
        var created: BrokerTerminalSummary?
        var prepared: BrokerPreparedRecovery?
        var attachment: BrokerAttachment?
        var output = Data()
        var inputAccepted = false
        var detachReceipt: BrokerDetachReceipt?
        var detachedInputRejected = false
        var listedAfterDetach = false
        var reattachPrepared: BrokerPreparedRecovery?
        var reattached: BrokerAttachment?
        var terminated = false
        var abortTerminal: BrokerTerminalSummary?
        var discarded: BrokerPreparedRecovery?
        var recoveredAfterAbort: BrokerPreparedRecovery?
        var abortAttachment: BrokerAttachment?

        client.onExit = { _, _ in terminated = true }
        client.start { hello = try? $0.get() }
        check(waitMain(until: { hello != nil }), "real v4 hello failed")
        check(hello?.manifest?.snapshotMagic == "OUROCODE-ANSI-REPLAY", "fixture manifest was not explicit")

        client.create(
            createNonce: "real-smoke-\(UUID().uuidString)",
            program: "/bin/sh",
            args: ["-c", "printf 'REAL-V4\\r\\n'; exec /bin/cat"],
            currentDirectory: "/tmp",
            environment: ["TERM": "xterm-256color"],
            columns: 80,
            rows: 24
        ) { created = try? $0.get() }
        check(waitMain(until: { created != nil }), "real v4 create failed")

        client.prepareAttachment(terminalID: created!.id) { prepared = try? $0.get() }
        check(waitMain(until: { prepared != nil }), "real v4 checkpoint/digest verification failed")
        output.append(prepared!.checkpoint)

        client.commitAttachment(prepared!, onEvent: { event in
            if case let .ptyBytes(_, data) = event { output.append(data) }
        }) { result in
            attachment = try? result.get()
            attachment?.consumeCatchUpEvents { events in
                for event in events {
                    if case let .ptyBytes(_, data) = event { output.append(data) }
                }
            }
        }
        check(waitMain(until: { attachment != nil }), "real v4 attached_ready failed")
        check(
            waitMain(until: { String(decoding: output, as: UTF8.self).contains("REAL-V4") }),
            "real terminal output was absent after checkpoint/catch-up"
        )

        client.input(Data("PING-V4\n".utf8), using: attachment!) {
            inputAccepted = (try? $0.get()) != nil
        }
        check(waitMain(until: { inputAccepted }), "real attached lease input failed")
        check(
            waitMain(until: { String(decoding: output, as: UTF8.self).contains("PING-V4") }),
            "real input did not return through ordered output"
        )

        client.detach(attachment!) { detachReceipt = try? $0.get() }
        check(waitMain(until: { detachReceipt != nil }), "real v4 detach barrier failed")
        client.input(Data("STALE\n".utf8), using: attachment!) {
            if case .failure = $0 { detachedInputRejected = true }
        }
        check(waitMain(until: { detachedInputRejected }), "detached lease retained local input authority")
        client.list { result in
            listedAfterDetach = (try? result.get())?.contains(where: {
                $0.id == created!.id && $0.running
            }) == true
        }
        check(waitMain(until: { listedAfterDetach }), "detach terminated the broker-owned PTY")
        client.prepareAttachment(
            terminalID: created!.id,
            afterStateSequence: detachReceipt!.stateSequence
        ) { reattachPrepared = try? $0.get() }
        check(waitMain(until: { reattachPrepared != nil }), "reattach after detach did not recover")
        client.commitAttachment(reattachPrepared!, onEvent: { _ in }) {
            reattached = try? $0.get()
        }
        check(waitMain(until: { reattached != nil }), "reattach after detach did not regain authority")
        attachment = reattached

        client.create(
            createNonce: "real-abort-\(UUID().uuidString)",
            program: "/bin/sh",
            args: ["-c", "exec /bin/cat"],
            currentDirectory: "/tmp",
            environment: ["TERM": "xterm-256color"],
            columns: 80,
            rows: 24
        ) { abortTerminal = try? $0.get() }
        check(waitMain(until: { abortTerminal != nil }), "real abort terminal create failed")
        client.prepareAttachment(terminalID: abortTerminal!.id) { discarded = try? $0.get() }
        check(waitMain(until: { discarded != nil }), "real discard recovery prepare failed")
        client.abortRecovery(discarded!, reason: "real smoke renderer refusal")
        client.prepareAttachment(terminalID: abortTerminal!.id) { recoveredAfterAbort = try? $0.get() }
        check(
            waitMain(until: { recoveredAfterAbort != nil }),
            "real recovery_abort did not release pin/admission for a new prepare"
        )
        client.commitAttachment(recoveredAfterAbort!, onEvent: { _ in }) {
            abortAttachment = try? $0.get()
        }
        check(waitMain(until: { abortAttachment != nil }), "real reattach after abort failed")
        client.terminate(terminalID: abortTerminal!.id) { _ in }

        client.terminate(terminalID: created!.id) { _ in }
        check(waitMain(until: { terminated }), "real broker did not publish exit")
        client.stop()
        print("PASS: real Rust v4 hello/create/digest/commit/detach/reattach/abort/input/output/exit")
    }
}
