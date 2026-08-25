import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

private final class TwoRowDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { 2 }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    let cell = TerminalTabPickerCellView()
    let label = NSTextField(labelWithString: "Terminal \(row + 1)")
    label.frame = NSRect(x: 8, y: 4, width: 180, height: 20)
    label.setAccessibilityElement(false)
    cell.addSubview(label)
    return cell
  }
}

@main
enum TerminalTabPickerActivationFixture {
  static func main() {
    _ = NSApplication.shared
    let dataSource = TwoRowDataSource()
    let table = TerminalTabPickerTableView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tab")))
    table.dataSource = dataSource
    table.delegate = dataSource
    table.reloadData()

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
      styleMask: [.borderless],
      backing: .buffered,
      defer: false
    )
    let scrollView = NSScrollView(frame: window.contentView!.bounds)
    scrollView.documentView = table
    window.contentView = scrollView
    table.frame = NSRect(x: 0, y: 0, width: 300, height: 96)
    table.rowHeight = 40
    table.reloadData()
    table.layoutSubtreeIfNeeded()
    let rowPoint = NSPoint(x: 40, y: table.rect(ofRow: 0).midY)
    require(table.row(at: rowPoint) == 0, "runtime fixture did not target a visible table row")
    let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true)
    require(cell is TerminalTabPickerCellView, "runtime fixture did not materialize its picker cell")
    require(cell?.hitTest(NSPoint(x: 20, y: 10)) == nil, "picker cell intercepted its label click")
    require(table.hitTest(rowPoint) === table, "table row hit path was intercepted by a cell label")
    let scrollPoint = table.convert(rowPoint, to: scrollView)
    require(scrollView.hitTest(scrollPoint) === table, "NSScrollView hit path did not resolve to the table")

    var tableActivations = 0
    table.onActivateSelection = { tableActivations += 1 }
    table.suppressSelectionActivation = true
    table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    table.activateSelectionChangeIfNeeded()
    table.suppressSelectionActivation = false
    require(tableActivations == 0, "programmatic selection activated a tab")
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    table.activateSelectionChangeIfNeeded()
    require(tableActivations == 1, "AX-style row selection did not activate selected tab")

    require(
      TerminalTabPickerTableView.pointerReleaseActivates(
        hitRow: 1,
        releaseRow: 1,
        startScreen: NSPoint(x: 80, y: 120),
        endScreen: NSPoint(x: 82, y: 121)
      ),
      "coordinate click on an already-selected row was not activated"
    )
    require(
      !TerminalTabPickerTableView.pointerReleaseActivates(
        hitRow: 1,
        releaseRow: 1,
        startScreen: NSPoint(x: 80, y: 120),
        endScreen: NSPoint(x: 90, y: 120)
      ),
      "row drag crossed activation hysteresis and still activated"
    )
    require(
      !TerminalTabPickerTableView.pointerReleaseActivates(
        hitRow: 1,
        releaseRow: 0,
        startScreen: NSPoint(x: 80, y: 120),
        endScreen: NSPoint(x: 80, y: 120)
      ),
      "pointer release on a different row activated the original row"
    )

    let accessibilityCell = TerminalTabPickerCellView()
    var accessibilityActivations = 0
    accessibilityCell.onAccessibilityPress = { accessibilityActivations += 1 }
    require(accessibilityCell.accessibilityPerformPress(), "AX press was not accepted")
    require(accessibilityActivations == 1, "AX press did not activate represented tab exactly once")

    print("PASS: tab picker activates pointer/Return/AX once and rejects row drags")
  }
}
