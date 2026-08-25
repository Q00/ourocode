import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum LiveTerminalSessionFixture {
    static func main() {
        let active = LiveTerminalSession(
            id: UUID(), title: "Codex · ourocode", path: "/Users/me/ourocode",
            selected: true, running: true, foregroundProcess: true, binding: nil
        )
        require(active.status == "active", "foreground agent was not live")
        require(active.detail.contains("Agent running"), "active terminal hid its agent activity")
        let idle = LiveTerminalSession(
            id: UUID(), title: "Claude · docs", path: "/Users/me/docs",
            selected: false, running: true, foregroundProcess: false, binding: nil
        )
        require(idle.status == "ready", "idle live terminal looked ended")
        print("PASS: live Claude/Codex terminal sessions project active state and selectable identity")
    }
}
