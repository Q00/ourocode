import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

private func computerUseContractChecks() {
  let parsed = CUAInstallationLocator.parsePermissions(
    "accessibility:    true\nscreen_recording: false\n"
  )
  require(parsed.accessibility, "CUA Accessibility grant was not parsed")
  require(!parsed.screenRecording, "CUA Screen Recording grant was guessed")

  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("ourocode-cua-locator-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: root) }
  let binary = root.appendingPathComponent(".local/bin/cua-rs")
  do {
    try FileManager.default.createDirectory(
      at: binary.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try Data("#!/bin/sh\n".utf8).write(to: binary)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
  } catch {
    require(false, "CUA locator fixture setup failed: \(error)")
    return
  }
  require(
    CUAInstallationLocator.firstExecutable(named: "cua-rs", homeDirectory: root) == binary,
    "CUA locator ignored the user-local pinned binary"
  )
  require(
    CUAInstallationLocator.installCommand.contains("CUA_VERSION=v0.9.1"),
    "CUA install action stopped pinning the reviewed release"
  )
}
@main
enum TerminalChromeAffordanceFixture {
  static func main() {
    _ = NSApplication.shared
    computerUseContractChecks()
    require(
      TerminalTabOverflowVisibility.resolve(
        viewportOrigin: 0, viewportWidth: 300, contentWidth: 600
      ) == .init(leading: false, trailing: true),
      "leading edge cue appeared at the first tab"
    )
    require(
      TerminalTabOverflowVisibility.resolve(
        viewportOrigin: 150, viewportWidth: 300, contentWidth: 600
      ) == .init(leading: true, trailing: true),
      "middle tab overflow did not expose both edge cues"
    )
    require(
      TerminalTabOverflowVisibility.resolve(
        viewportOrigin: 300, viewportWidth: 300, contentWidth: 600
      ) == .init(leading: true, trailing: false),
      "trailing edge cue remained at the final tab"
    )
    require(
      TerminalTabWidthPolicy.width(
        preferredWidth: 180, availableWidth: 360, visibleCount: 3
      ) == 120,
      "compact window did not shrink tabs to the available width"
    )
    require(
      TerminalTabWidthPolicy.width(
        preferredWidth: 140, availableWidth: 900, visibleCount: 3
      ) == 140,
      "wide window stretched tabs beyond their readable preferred width"
    )
    require(
      TerminalTabWidthPolicy.width(
        preferredWidth: 140, availableWidth: 240, visibleCount: 5
      ) == TerminalTabWidthPolicy.minimumWidth,
      "very narrow window shrank tabs below the usable hit target"
    )

    let cue = TerminalTabOverflowCueView(edge: .leading)
    require(cue.hitTest(NSPoint(x: 1, y: 1)) == nil, "tab edge cue intercepted pointer input")
    require(!cue.isAccessibilityElement(), "tab edge cue entered the accessibility tree")
    print("PASS: MCP/tab overflow chrome stays legible, non-interactive, and AX quiet")
  }
}
