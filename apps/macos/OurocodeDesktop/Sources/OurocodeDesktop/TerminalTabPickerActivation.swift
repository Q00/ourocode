import AppKit

/// NSTableView's action is distinct from selection change: pointer and AX
/// activation switch tabs, while keyboard arrows remain free to preview a row
/// until Return is pressed.
final class TerminalTabPickerTableView: NSTableView {
  private struct PointerCandidate {
    let row: Int
    let startScreen: NSPoint
  }

  var onActivateSelection: (() -> Void)?
  var suppressSelectionActivation = false
  private var keyboardSelectionInProgress = false
  private var pointerSelectionInProgress = false
  private var pointerCandidate: PointerCandidate?
  var selectionChangeShouldActivate: Bool {
    selectedRow >= 0 && !suppressSelectionActivation
      && !keyboardSelectionInProgress && !pointerSelectionInProgress
  }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureActivation()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureActivation()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard bounds.contains(point), row(at: point) >= 0 else {
      return super.hitTest(point)
    }
    return self
  }

  override func keyDown(with event: NSEvent) {
    let returnKey = event.keyCode == 36 || event.keyCode == 76
    if returnKey && event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
      activateSelection(nil)
      return
    }
    keyboardSelectionInProgress = true
    defer { keyboardSelectionInProgress = false }
    super.keyDown(with: event)
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let hitRow = row(at: point)
    guard hitRow >= 0, let window else {
      pointerCandidate = nil
      pointerSelectionInProgress = false
      super.mouseDown(with: event)
      return
    }
    pointerCandidate = PointerCandidate(
      row: hitRow,
      startScreen: window.convertPoint(toScreen: event.locationInWindow)
    )
    pointerSelectionInProgress = true
    suppressSelectionActivation = true
    selectRowIndexes(IndexSet(integer: hitRow), byExtendingSelection: false)
    suppressSelectionActivation = false
    window.makeFirstResponder(self)
  }

  override func mouseDragged(with event: NSEvent) {
    // Keep the original row selected while tracking. mouseUp decides whether
    // the gesture remained a click; row drags never activate a tab.
  }

  override func mouseUp(with event: NSEvent) {
    defer {
      pointerCandidate = nil
      pointerSelectionInProgress = false
    }
    guard let candidate = pointerCandidate, let window else { return }
    let releasePoint = convert(event.locationInWindow, from: nil)
    let releaseRow = row(at: releasePoint)
    let endScreen = window.convertPoint(toScreen: event.locationInWindow)
    guard Self.pointerReleaseActivates(
      hitRow: candidate.row,
      releaseRow: releaseRow,
      startScreen: candidate.startScreen,
      endScreen: endScreen
    ) else { return }
    activateSelection(nil)
  }

  override func selectRowIndexes(_ indexes: IndexSet, byExtendingSelection extend: Bool) {
    super.selectRowIndexes(indexes, byExtendingSelection: extend)
  }

  func activateSelectionChangeIfNeeded() {
    guard selectionChangeShouldActivate else { return }
    activateSelection(nil)
  }

  @objc private func activateSelection(_ sender: Any?) {
    guard selectedRow >= 0 else { return }
    onActivateSelection?()
  }

  static func pointerReleaseActivates(
    hitRow: Int,
    releaseRow: Int,
    startScreen: NSPoint,
    endScreen: NSPoint
  ) -> Bool {
    guard hitRow >= 0, releaseRow == hitRow else { return false }
    let deltaX = endScreen.x - startScreen.x
    let deltaY = endScreen.y - startScreen.y
    return hypot(deltaX, deltaY) <= 4
  }

  private func configureActivation() {
    target = nil
    action = nil
  }
}

/// AppKit exposes table cells separately to assistive technology. A row can be
/// selected without invoking NSTableView.action, so the cell owns an explicit
/// press action that activates the represented tab exactly once.
final class TerminalTabPickerCellView: NSTableCellView {
  var onAccessibilityPress: (() -> Void)?

  // Sighted pointer activation belongs to the table's row tracker. Keeping
  // the cell out of hit testing also prevents its non-editable labels from
  // swallowing coordinate clicks; the cell remains an AX press target.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func accessibilityPerformPress() -> Bool {
    guard let onAccessibilityPress else { return false }
    onAccessibilityPress()
    return true
  }
}
