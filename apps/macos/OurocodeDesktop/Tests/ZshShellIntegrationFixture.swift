import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum ZshShellIntegrationFixture {
    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ourocode-zsh-integration-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let log = root.appendingPathComponent("startup.log")
        let startupCapture = root.appendingPathComponent("instant-prompt-capture.log")
        let slowStartup = home.appendingPathComponent("nested-startup.zsh.inc")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A real account rc may source a protected or slow SDK fragment. Keep
        // this fixture deterministic while preserving the important property:
        // startup must be allowed to finish without the host injecting an
        // interrupt into the line discipline.
        try Data("sleep 0.45\nexport OUROCODE_SLOW_STARTUP_COMPLETED=1\n".utf8)
            .write(to: slowStartup)

        for filename in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
            var content = "print -r -- \(filename) >> $OUROCODE_TEST_LOG\n"
            if filename == ".zshrc" {
                content += #"""
                if [[ -o interactive ]]; then
                  # Model the part of Powerlevel10k instant prompt that captures
                  # stdout while zsh initialization and the first precmd run.
                  typeset -gi _OUROCODE_TEST_SAVED_STDOUT
                  exec {_OUROCODE_TEST_SAVED_STDOUT}>&1
                  exec 1>>"$OUROCODE_TEST_STARTUP_CAPTURE" 2>&1
                  _ourocode_test_restore_output() {
                    exec 1>&$_OUROCODE_TEST_SAVED_STDOUT 2>&1 {_OUROCODE_TEST_SAVED_STDOUT}>&-
                    precmd_functions=(${precmd_functions:#_ourocode_test_restore_output})
                    builtin unfunction _ourocode_test_restore_output
                  }
                  typeset -ag precmd_functions
                  precmd_functions+=(_ourocode_test_restore_output)
                fi

                builtin source "$OUROCODE_TEST_SLOW_STARTUP"

                """#
            }
            try Data(content.utf8).write(to: home.appendingPathComponent(filename))
        }

        let installation = try ZshShellIntegration.install(
            inherited: ["ZDOTDIR": home.path, "OUROCODE_TEST_LOG": log.path],
            homeDirectory: home,
            applicationSupportDirectory: support
        )
        require(installation.environment["ZDOTDIR"] == installation.wrapperDirectory.path,
                "zsh did not receive the integration ZDOTDIR")
        require(installation.environment["OUROCODE_ORIGINAL_ZDOTDIR"] == home.path,
                "the user's ZDOTDIR was not preserved")
        let zshrc = try String(
            contentsOf: installation.wrapperDirectory.appendingPathComponent(".zshrc"),
            encoding: .utf8
        )
        let zshenv = try String(
            contentsOf: installation.wrapperDirectory.appendingPathComponent(".zshenv"),
            encoding: .utf8
        )
        require(zshenv.contains("_ourocode_deferred_init"),
                "shell integration was not registered before .zshrc")
        require(zshenv.contains("sysopen -o cloexec"),
                "shell integration did not reserve a close-on-exec TTY descriptor")
        require(zshenv.contains("133;A") && zshenv.contains("133;B") && zshenv.contains("133;C"),
                "OSC 133 hooks were not installed")
        require(zshenv.contains("${_ourocode_pwd_uri//[#]/%23}"),
                "OSC 7 hash escaping can be reinterpreted by EXTENDED_GLOB")
        require(!zshrc.contains("PROMPT="),
                "shell integration must not race prompt themes during startup")

        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = ["-q", "/dev/null", "/bin/zsh", "-d", "-l", "-i"]
        var environment = installation.environment
        environment["HOME"] = home.path
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["TERM"] = "xterm-256color"
        environment["OUROCODE_TEST_STARTUP_CAPTURE"] = startupCapture.path
        environment["OUROCODE_TEST_SLOW_STARTUP"] = slowStartup.path
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        // Give the interactive editor a chance to enter line-init between
        // commands; closing a scripted PTY immediately can deliver EOF before
        // ZLE and would not exercise the A -> B -> C -> D contract at all.
        Thread.sleep(forTimeInterval: 0.25)
        input.fileHandleForWriting.write(Data("print -r -- ready\n".utf8))
        Thread.sleep(forTimeInterval: 0.15)
        input.fileHandleForWriting.write(Data("false\n".utf8))
        Thread.sleep(forTimeInterval: 0.15)
        input.fileHandleForWriting.write(Data("exit 0\n".utf8))
        Thread.sleep(forTimeInterval: 0.15)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        require(process.terminationStatus == 0, "wrapped zsh did not exit cleanly")

        let lines = try String(contentsOf: log, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        for filename in [".zshenv", ".zprofile", ".zshrc", ".zlogin", ".zlogout"] {
            require(lines.filter { $0 == filename }.count == 1,
                    "\(filename) was not sourced exactly once")
        }
        let transcript = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        require(transcript.contains("ready"), "wrapped zsh did not reach the command")
        require(!transcript.contains("interrupt"),
                "slow startup was interrupted before the shell reached ZLE")
        require(!transcript.contains("Console output during zsh initialization detected"),
                "OSC control traffic triggered an instant-prompt startup warning")
        require((try? Data(contentsOf: startupCapture).isEmpty) == true,
                "OSC control traffic leaked into instant-prompt stdout capture")
        let prompt = transcript.range(of: "\u{1B}]133;A\u{07}")
        let inputMarker = prompt.flatMap { transcript.range(of: "\u{1B}]133;B\u{07}", range: $0.upperBound..<transcript.endIndex) }
        let command = inputMarker.flatMap { transcript.range(of: "\u{1B}]133;C\u{07}", range: $0.upperBound..<transcript.endIndex) }
        let completion = command.flatMap { transcript.range(of: "\u{1B}]133;D;1\u{07}", range: $0.upperBound..<transcript.endIndex) }
        if prompt == nil || inputMarker == nil || command == nil || completion == nil {
            let markers = transcript.split(separator: "\u{1B}").compactMap { fragment -> String? in
                guard fragment.hasPrefix("]133;"),
                      let end = fragment.firstIndex(of: "\u{07}") else { return nil }
                return String(fragment[..<end])
            }
            FileHandle.standardError.write(Data("observed OSC 133 markers: \(markers)\n".utf8))
        }
        require(prompt != nil && inputMarker != nil && command != nil && completion != nil,
                "interactive zsh did not emit ordered prompt, input, command, and completion semantics")
        print("PASS: zsh startup stays single-sourced and OSC 133 bypasses instant-prompt capture")
    }
}
