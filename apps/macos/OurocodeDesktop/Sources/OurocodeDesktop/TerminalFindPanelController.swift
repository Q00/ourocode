import AppKit

final class TerminalFindPanelController: NSWindowController, NSSearchFieldDelegate, NSWindowDelegate {
  typealias Search = (String, @escaping (Result<TerminalFindResult, Error>) -> Void) -> Void

  var onSearch: Search?
  var onReveal: ((TerminalFindMatch) -> Void)?

  private let searchField = NSSearchField()
  private let resultLabel = NSTextField(labelWithString: "")
  private let previousButton = NSButton(title: "", target: nil, action: nil)
  private let nextButton = NSButton(title: "", target: nil, action: nil)
  private var searchWorkItem: DispatchWorkItem?
  private var searchGeneration: UInt64 = 0
  private var result = TerminalFindResult(matches: [], truncated: false)
  private var selectedMatch = -1

  init() {
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 470, height: 74),
      styleMask: [.titled, .closable, .utilityWindow],
      backing: .buffered,
      defer: false
    )
    panel.title = "Find in Terminal"
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    super.init(window: panel)
    panel.delegate = self
    configure()
  }

  required init?(coder: NSCoder) { nil }

  func present(relativeTo parent: NSWindow?) {
    guard let panel = window else { return }
    if let parent, panel.parent !== parent {
      panel.parent?.removeChildWindow(panel)
      parent.addChildWindow(panel, ordered: .above)
      let parentFrame = parent.frame
      panel.setFrameOrigin(
        NSPoint(
          x: parentFrame.maxX - panel.frame.width - 24,
          y: parentFrame.maxY - panel.frame.height - 52
        )
      )
    }
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(searchField)
    searchField.selectText(nil)
  }

  /// Find rows are identities within one terminal projection. Invalidate
  /// pending callbacks and clear retained rows before the selected tab moves.
  func reset() {
    searchWorkItem?.cancel()
    searchWorkItem = nil
    searchGeneration &+= 1
    searchField.stringValue = ""
    result = TerminalFindResult(matches: [], truncated: false)
    selectedMatch = -1
    updatePresentation()
  }

  func revealNext() {
    reveal(step: 1)
  }

  func revealPrevious() {
    reveal(step: -1)
  }

  func controlTextDidChange(_ obj: Notification) {
    scheduleSearch()
  }

  func windowWillClose(_ notification: Notification) {
    reset()
  }

  private func configure() {
    guard let content = window?.contentView else { return }
    content.wantsLayer = true
    content.layer?.backgroundColor = OuroTheme.elevated.cgColor
    searchField.placeholderString = "Find in scrollback"
    searchField.sendsSearchStringImmediately = true
    searchField.delegate = self
    searchField.setAccessibilityLabel(MacCommandAccessibility.findSearchFieldLabel)

    resultLabel.font = OuroTheme.uiFont(size: 12)
    resultLabel.textColor = OuroTheme.muted
    resultLabel.alignment = .right
    resultLabel.setAccessibilityLabel(MacCommandAccessibility.findResultsLabel)
    configureButton(
      previousButton,
      symbol: "chevron.up",
      label: MacCommandAccessibility.previousMatchLabel,
      action: #selector(previous(_:))
    )
    configureButton(
      nextButton,
      symbol: "chevron.down",
      label: MacCommandAccessibility.nextMatchLabel,
      action: #selector(next(_:))
    )

    let row = NSStackView(views: [searchField, resultLabel, previousButton, nextButton])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
      row.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
      row.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),
      resultLabel.widthAnchor.constraint(equalToConstant: 72),
      previousButton.widthAnchor.constraint(equalToConstant: 28),
      previousButton.heightAnchor.constraint(equalToConstant: 26),
      nextButton.widthAnchor.constraint(equalToConstant: 28),
      nextButton.heightAnchor.constraint(equalToConstant: 26),
    ])
    updatePresentation()
  }

  private func configureButton(_ button: NSButton, symbol: String, label: String, action: Selector) {
    button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
    button.imagePosition = .imageOnly
    button.bezelStyle = .texturedRounded
    button.target = self
    button.action = action
    button.setAccessibilityLabel(label)
  }

  private func scheduleSearch() {
    searchWorkItem?.cancel()
    searchGeneration &+= 1
    let generation = searchGeneration
    let query = searchField.stringValue
    guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      result = TerminalFindResult(matches: [], truncated: false)
      selectedMatch = -1
      updatePresentation()
      return
    }
    resultLabel.stringValue = "Searching…"
    let work = DispatchWorkItem { [weak self] in
      guard let self, generation == self.searchGeneration else { return }
      self.onSearch?(query) { [weak self] outcome in
        DispatchQueue.main.async {
          guard let self, generation == self.searchGeneration else { return }
          switch outcome {
          case .success(let value):
            self.result = value
            self.selectedMatch = value.matches.isEmpty ? -1 : 0
            self.updatePresentation()
            if let first = value.matches.first { self.onReveal?(first) }
          case .failure:
            self.result = TerminalFindResult(matches: [], truncated: false)
            self.selectedMatch = -1
            self.resultLabel.stringValue = "Unavailable"
            self.updateButtons()
          }
        }
      }
    }
    searchWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(120), execute: work)
  }

  @objc private func previous(_ sender: Any?) { revealPrevious() }
  @objc private func next(_ sender: Any?) { revealNext() }

  private func reveal(step: Int) {
    guard !result.matches.isEmpty else { return }
    selectedMatch = (selectedMatch + step) % result.matches.count
    if selectedMatch < 0 { selectedMatch += result.matches.count }
    updatePresentation()
    onReveal?(result.matches[selectedMatch])
  }

  private func updatePresentation() {
    if result.matches.isEmpty {
      resultLabel.stringValue = searchField.stringValue.isEmpty ? "" : "No matches"
    } else {
      let suffix = result.truncated ? "+" : ""
      resultLabel.stringValue = "\(selectedMatch + 1) / \(result.matches.count)\(suffix)"
    }
    resultLabel.setAccessibilityValue(resultLabel.stringValue)
    updateButtons()
  }

  private func updateButtons() {
    let enabled = !result.matches.isEmpty
    previousButton.isEnabled = enabled
    nextButton.isEnabled = enabled
  }
}
