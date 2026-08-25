import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum MCPSourceEnablementFixture {
    static func main() {
        let suite = "ourocode-mcp-enablement-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { exit(2) }
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = MCPSourceEnablementStore(defaults: defaults)
        let ids = ["ouroboros", "computer-use"]
        require(store.enabledSourceIDs(allSourceIDs: ids) == Set(ids), "first launch did not enable all sources")
        store.setEnabled(false, sourceID: "computer-use", allSourceIDs: ids)
        require(store.enabledSourceIDs(allSourceIDs: ids) == ["ouroboros"], "disabled source was not persisted")
        store.setEnabled(true, sourceID: "computer-use", allSourceIDs: ids)
        require(store.enabledSourceIDs(allSourceIDs: ids) == Set(ids), "re-enabled source was not persisted")
        require(MCPSourceTogglePolicy.statusLabel(enabled: false, runtimeStatus: "connected") == "Off",
                "disabled source did not present Off")
        require(MCPSourceTogglePolicy.detail(enabled: false, runtimeDetail: "live") == "Disabled · enable to connect",
                "disabled source detail was ambiguous")
        print("PASS: MCP source enablement defaults on, persists toggles, and presents disabled state")
    }
}
