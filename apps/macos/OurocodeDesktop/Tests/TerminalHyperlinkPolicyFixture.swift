import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    fputs("FAIL: \(message)\n", stderr)
    exit(1)
  }
}

@main
private enum TerminalHyperlinkPolicyFixture {
  static func main() {
    require(
      TerminalHyperlinkPolicy.url("https://example.com/path?q=1")?.absoluteString
        == "https://example.com/path?q=1",
      "HTTPS hyperlink was rejected"
    )
    require(TerminalHyperlinkPolicy.url("http://localhost:3000") != nil, "HTTP localhost was rejected")
    require(TerminalHyperlinkPolicy.url("file:///tmp/secret") == nil, "file URL was accepted")
    require(TerminalHyperlinkPolicy.url("javascript:alert(1)") == nil, "script URL was accepted")
    require(TerminalHyperlinkPolicy.url("https://user:pass@example.com") == nil, "credential URL was accepted")
    require(TerminalHyperlinkPolicy.url("https://example.com/\nnext") == nil, "control character was accepted")
    require(
      TerminalHyperlinkPolicy.url("https://example.com/" + String(repeating: "x", count: 4_096)) == nil,
      "oversized URI was accepted"
    )
    print("PASS: command-click hyperlink policy accepts only bounded credential-free HTTP(S) URLs")
  }
}
