import Foundation

@main
enum TerminalShellMetadataPolicyFixture {
    static func main() {
        require(
            TerminalShellMetadataPolicy.directory("file://localhost/private/tmp")
                == URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL.path,
            "localhost file URI did not decode"
        )
        require(
            TerminalShellMetadataPolicy.directory("file://remote/private/tmp") == nil,
            "remote file URI was accepted"
        )
        require(
            TerminalShellMetadataPolicy.directory("/private/tmp")
                == URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL.path,
            "absolute path did not pass"
        )
        require(
            TerminalShellMetadataPolicy.directory("file://localhost/private/a%20b")
                == URL(fileURLWithPath: "/private/a b", isDirectory: true).standardizedFileURL.path,
            "percent-encoded path did not decode"
        )
        require(
            TerminalShellMetadataPolicy.title(" Build Agent ") == "Build Agent",
            "shell title was not normalized"
        )
        require(
            TerminalShellMetadataPolicy.title("bad\u{7f}title") == nil,
            "control-bearing title was accepted"
        )
        print("PASS: Ghostty shell metadata accepts only bounded local cwd/title values")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
