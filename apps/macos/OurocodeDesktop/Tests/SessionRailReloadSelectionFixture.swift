import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class FixtureNode: NSObject {
    let id: String
    let children: [FixtureNode]

    init(_ id: String, children: [FixtureNode] = []) {
        self.id = id
        self.children = children
    }
}

private final class ReloadHarness: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    var roots: [FixtureNode] = []
    var selectedID: String?
    var isRebuildingTree = false
    var clearCount = 0

    override init() {
        super.init()
        outline.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("fixture")))
        outline.outlineTableColumn = outline.tableColumns[0]
        outline.dataSource = self
        outline.delegate = self
        outline.reloadData()
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? FixtureNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FixtureNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let node = item as? FixtureNode { return node.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let cell = NSTableCellView()
        let label = NSTextField(labelWithString: (item as? FixtureNode)?.id ?? "")
        cell.addSubview(label)
        cell.textField = label
        return cell
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isRebuildingTree else { return }
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? FixtureNode else {
            selectedID = nil
            clearCount += 1
            return
        }
        selectedID = node.id
    }

    func find(_ id: String) -> FixtureNode? {
        func search(_ nodes: [FixtureNode]) -> FixtureNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(roots)
    }

    func seedSelection() {
        roots = [FixtureNode("execution:one", children: [FixtureNode("session:one:child")])]
        outline.reloadData()
        outline.expandItem(roots[0])
        let row = outline.row(forItem: roots[0].children[0])
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        require(selectedID == "session:one:child", "fixture failed to select the initial session")
    }

    func rebuildWithFreshObjects() {
        let stableSelectedID = selectedID
        isRebuildingTree = true
        defer { isRebuildingTree = false }
        roots = [FixtureNode("execution:one", children: [FixtureNode("session:one:child")])]
        outline.reloadData()
        outline.expandItem(roots[0])
        guard let stableSelectedID, let node = find(stableSelectedID) else { return }
        let row = outline.row(forItem: node)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedID = node.id
    }
}

@main
private enum SessionRailReloadSelectionFixture {
    static func main() {
        _ = NSApplication.shared
        let harness = ReloadHarness()
        harness.seedSelection()
        harness.rebuildWithFreshObjects()
        require(harness.selectedID == "session:one:child", "stable session ID was lost during reload")
        require(harness.outline.selectedRow >= 0, "session row was not restored after reload")
        require(harness.clearCount == 0, "reload emitted a destructive clear callback")

        harness.outline.deselectAll(nil)
        require(harness.selectedID == nil, "genuine deselection did not clear the session")
        require(harness.clearCount == 1, "genuine deselection was not observed exactly once")

        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: false,
                isSessionWorkspaceVisible: true,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: false
            ) == .restoreSemanticSelection,
            "a delayed wrong-row notification could replace an open session workspace"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: true,
                isReloadSettling: false,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: false
            ) == .ignore,
            "a synchronous reload notification could clear stable selection"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: true,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: false
            ) == .restoreSemanticSelection,
            "a delayed reload notification could clear keyboard selection"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: true,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: true
            ) == .apply,
            "a genuine Arrow selection was skipped during reload settling"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: true,
                isSessionWorkspaceVisible: true,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: true
            ) == .apply,
            "a genuine row action could not leave the current session workspace"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: false,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: false
            ) == .restoreSemanticSelection,
            "a post-settle projection callback could clear keyboard selection"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: false,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: true,
                hasExplicitUserIntent: true
            ) == .apply,
            "genuine pointer or keyboard selection stopped working"
        )
        require(
            SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
                isRebuildingTree: false,
                isReloadSettling: false,
                isSessionWorkspaceVisible: false,
                hasRetainedSemanticSelection: false,
                hasExplicitUserIntent: false
            ) == .apply,
            "mode transition could not clear its intentionally empty selection"
        )

        require(
            !SessionRailDetailFocusRestoration.shouldRestore(
                detailOwnedFocusAtDismissal: false,
                focusIsUnclaimedOrStillInDetail: false,
                requestGeneration: 7,
                currentGeneration: 7,
                detailIsVisible: false
            ),
            "background reload stole focus after the user moved to the terminal"
        )
        require(
            SessionRailDetailFocusRestoration.shouldRestore(
                detailOwnedFocusAtDismissal: true,
                focusIsUnclaimedOrStillInDetail: true,
                requestGeneration: 8,
                currentGeneration: 8,
                detailIsVisible: false
            ),
            "explicit detail dismissal did not restore its previous responder"
        )
        require(
            !SessionRailDetailFocusRestoration.shouldRestore(
                detailOwnedFocusAtDismissal: true,
                focusIsUnclaimedOrStillInDetail: false,
                requestGeneration: 8,
                currentGeneration: 8,
                detailIsVisible: false
            ),
            "queued restoration overrode a newer terminal focus"
        )
        require(
            !SessionRailDetailFocusRestoration.shouldRestore(
                detailOwnedFocusAtDismissal: true,
                focusIsUnclaimedOrStillInDetail: true,
                requestGeneration: 8,
                currentGeneration: 9,
                detailIsVisible: false
            ),
            "stale detail dismissal restored focus across generations"
        )
        print("PASS: NSOutlineView reload preserves stable session selection and still clears genuine deselection")
    }
}
