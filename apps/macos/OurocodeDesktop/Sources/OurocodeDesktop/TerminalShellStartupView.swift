import AppKit

/// Replaces prompt-looking startup output until the integrated zsh proves it
/// is interactive. The surface is intentionally plain: one status, one
/// explanation, and one reversible escape hatch.
final class TerminalShellStartupView: NSView {
  enum State { case starting, delayed }

  private let titleLabel = NSTextField(labelWithString: "")
  private let detailLabel = NSTextField(wrappingLabelWithString: "")
  private let cleanShellButton = NSButton(title: "Open clean shell", target: nil, action: nil)
  private(set) var identity: TerminalShellStartupIdentity?
  private(set) var state: State?
  var onOpenCleanShell: ((TerminalShellStartupIdentity) -> Void)?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityRole(.group)
    setAccessibilityLabel("Shell startup")

    titleLabel.font = OuroTheme.uiFont(size: 18, weight: .semibold)
    titleLabel.textColor = OuroTheme.text
    titleLabel.alignment = .center
    titleLabel.maximumNumberOfLines = 2

    detailLabel.font = OuroTheme.uiFont(size: 13.5)
    detailLabel.textColor = OuroTheme.muted
    detailLabel.alignment = .center
    detailLabel.maximumNumberOfLines = 3

    cleanShellButton.bezelStyle = .rounded
    cleanShellButton.controlSize = .large
    cleanShellButton.target = self
    cleanShellButton.action = #selector(openCleanShell(_:))
    cleanShellButton.setAccessibilityHelp(
      "Opens a new zsh tab without startup files. The current tab stays open."
    )

    let stack = NSStackView(views: [titleLabel, detailLabel, cleanShellButton])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 10
    stack.setCustomSpacing(18, after: detailLabel)
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
      stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -32),
      detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
    ])
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshBackground()
  }

  func present(identity: TerminalShellStartupIdentity, state: State) {
    if self.identity == identity, self.state == .delayed, state == .starting {
      return
    }
    self.identity = identity
    self.state = state
    switch state {
    case .starting:
      titleLabel.stringValue = "Starting your shell"
      detailLabel.stringValue = "Finishing zsh setup. Your terminal will be ready when the prompt is fully loaded."
      cleanShellButton.isHidden = true
      setAccessibilityHelp(detailLabel.stringValue)
    case .delayed:
      titleLabel.stringValue = "Your shell is still starting"
      detailLabel.stringValue = "You can keep waiting, or open a new shell without startup files. This tab will stay open."
      cleanShellButton.isHidden = false
      setAccessibilityHelp("\(detailLabel.stringValue) Open clean shell is available.")
    }
    refreshBackground()
    isHidden = false
    NSAccessibility.post(element: self, notification: .layoutChanged)
  }

  func dismiss(ifCurrent expected: TerminalShellStartupIdentity? = nil) {
    if let expected, identity != expected { return }
    isHidden = true
    identity = nil
    state = nil
  }

  func focusRecoveryAction(ifCurrent expected: TerminalShellStartupIdentity) {
    guard identity == expected, !isHidden, !cleanShellButton.isHidden else { return }
    window?.makeFirstResponder(cleanShellButton)
  }

  private func refreshBackground() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = OuroTheme.canvas.cgColor
    }
  }

  @objc private func openCleanShell(_ sender: Any?) {
    guard let identity else { return }
    onOpenCleanShell?(identity)
  }
}
