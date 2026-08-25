#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit

  extension OuroTerminalAccessibilitySnapshot {
    static func make(frame: GhosttyRenderFrame) -> OuroTerminalAccessibilitySnapshot {
      var projection = OuroTerminalAccessibilityProjection(rowCount: Int(frame.rows))
      for rowIndex in 0..<frame.rowData.count {
        guard let row = frame.rowData.row(at: rowIndex) else { continue }
        var line = ""
        var selected = ""
        var hasSemanticInput = false
        let end = row.firstCellIndex + row.cellCount
        if row.firstCellIndex >= 0, end <= frame.cellData.count {
          for cellIndex in row.firstCellIndex..<end {
            guard let cell = frame.cellData.cell(at: cellIndex),
              cell.width != 0,
              let text = frame.graphemes.string(in: cell.graphemeRange)
            else { continue }
            line.append(text)
            if cell.flags & 1 != 0 { selected.append(text) }
            if cell.semantic == 1 { hasSemanticInput = true }
          }
        }
        while line.last == " " { line.removeLast() }
        projection.update(
          rowIndex: Int(row.y),
          semantic: row.semantic,
          line: line,
          selected: selected,
          hasSemanticInput: hasSemanticInput
        )
      }
      return projection.snapshot(cursorLine: frame.cursor.map { Int($0.y) })
    }
  }

  final class OuroTerminalAccessibilityController {
    private weak var view: OuroMetalTerminalView?
    private var pending: DispatchWorkItem?
    private var snapshot = OuroTerminalAccessibilitySnapshot.empty
    private var announcedCommandIndex = -1
    private var visible = true

    init(view: OuroMetalTerminalView) {
      self.view = view
      configure(view)
    }

    deinit {
      pending?.cancel()
    }

    func setVisible(_ value: Bool) {
      guard visible != value else { return }
      visible = value
      view?.setAccessibilityHidden(!value)
      view?.setAccessibilityElement(value)
      if value {
        publish(snapshot)
      } else {
        // A single Metal view is rebound across broker-owned PTYs. Never keep
        // another terminal's text ready to republish while the next selected
        // generation is crossing first-present.
        pending?.cancel()
        pending = nil
        snapshot = .empty
      }
    }

    func update(_ next: OuroTerminalAccessibilitySnapshot) {
      pending?.cancel()
      let work = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.snapshot = next
        if self.visible { self.publish(next) }
      }
      pending = work
      DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }

    /// First-present is already damage and generation gated by the surface
    /// coordinator, so it must replace the previous tab synchronously. Normal
    /// live output continues through the bounded 50 ms coalescer above.
    func replace(_ next: OuroTerminalAccessibilitySnapshot) {
      pending?.cancel()
      pending = nil
      snapshot = next
      if visible { publish(next) }
    }

    private func configure(_ view: OuroMetalTerminalView) {
      view.setAccessibilityElement(true)
      view.setAccessibilityRole(.textArea)
      view.setAccessibilityRoleDescription("terminal")
      view.setAccessibilityLabel("Interactive terminal")
      view.setAccessibilityHelp(
        "Output from the selected terminal. Keyboard input is sent only while this terminal is focused and attached."
      )
      view.setAccessibilityValue("")
      view.setAccessibilityCustomActions([
        NSAccessibilityCustomAction(name: "Send Return") { [weak view] in
          guard let view, view.inputEnabled else { return false }
          view.inputSink?.terminalView(view, performCommand: "insertNewline:")
          return true
        },
        NSAccessibilityCustomAction(name: "Read next command row") { [weak self] in
          self?.announceCommand(step: 1) ?? false
        },
        NSAccessibilityCustomAction(name: "Read previous command row") { [weak self] in
          self?.announceCommand(step: -1) ?? false
        },
      ])
    }

    private func publish(_ value: OuroTerminalAccessibilitySnapshot) {
      guard let view else { return }
      view.setAccessibilityValue(value.value)
      view.setAccessibilitySelectedText(value.selectedText)
      if let cursorLine = value.cursorLine {
        view.setAccessibilityInsertionPointLineNumber(cursorLine)
      }
      view.setAccessibilityHelp(
        value.truncated
          ? "Selected terminal output. The accessibility snapshot is bounded and was truncated. \(value.commandRows.count) command rows are available."
          : "Selected terminal output. \(value.commandRows.count) command rows are available. Keyboard input is sent only while this terminal is focused and attached."
      )
      NSAccessibility.post(element: view, notification: .valueChanged)
    }

    private func announceCommand(step: Int) -> Bool {
      guard let view, !snapshot.commandRows.isEmpty else { return false }
      if announcedCommandIndex == -1, step < 0 {
        announcedCommandIndex = 0
      }
      announcedCommandIndex = (announcedCommandIndex + step) % snapshot.commandRows.count
      if announcedCommandIndex < 0 { announcedCommandIndex += snapshot.commandRows.count }
      NSAccessibility.post(
        element: view,
        notification: .announcementRequested,
        userInfo: [
          .announcement: snapshot.commandRows[announcedCommandIndex],
          .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ]
      )
      return true
    }
  }
#endif
