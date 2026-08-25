import AppKit

/// User-facing terminal preferences. Values are deliberately small and
/// primitive so a settings window never retains a terminal, broker, or render
/// projection. The terminal host observes changes and applies them to the one
/// selected Metal surface.
enum TerminalPreferences {
  static let didChangeNotification = Notification.Name("OurocodeTerminalPreferencesDidChange")

  private static let audibleBellKey = "terminal.audibleBell"
  private static let visualBellKey = "terminal.visualBell"

  static var audibleBell: Bool {
    get {
      guard UserDefaults.standard.object(forKey: audibleBellKey) != nil else { return false }
      return UserDefaults.standard.bool(forKey: audibleBellKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: audibleBellKey)
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }

  static var visualBell: Bool {
    get {
      guard UserDefaults.standard.object(forKey: visualBellKey) != nil else { return true }
      return UserDefaults.standard.bool(forKey: visualBellKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: visualBellKey)
      NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
  }
}

final class TerminalSettingsWindowController: NSWindowController {
  private weak var terminal: TerminalHostViewController?
  private let migrationController: SharedMCPMigrationSettingsViewController
  private let computerUseController = ComputerUseSettingsViewController()
  private var preferenceObserver: NSObjectProtocol?
  private let fontSizeLabel = NSTextField(labelWithString: "16 pt")
  private let fontSizeSlider = NSSlider(value: Double(OuroTheme.terminalFontSize), minValue: 12, maxValue: 48, target: nil, action: nil)
  private let visualBell = NSButton(checkboxWithTitle: "Flash the terminal when a bell arrives", target: nil, action: nil)
  private let audibleBell = NSButton(checkboxWithTitle: "Play the system sound for a bell", target: nil, action: nil)

  init(
    terminal: TerminalHostViewController,
    sharedOuroborosService: SharedOuroborosServiceRuntime
  ) {
    self.terminal = terminal
    migrationController = SharedMCPMigrationSettingsViewController(
      runtime: sharedOuroborosService
    )
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 740),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "Settings"
    window.titleVisibility = .visible
    window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 700, height: 660)
    super.init(window: window)
    configure()
    preferenceObserver = NotificationCenter.default.addObserver(
      forName: TerminalPreferences.didChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.syncFontSizeFromPreferences()
    }
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let preferenceObserver {
      NotificationCenter.default.removeObserver(preferenceObserver)
    }
  }

  func present() {
    guard let window else { return }
    syncFontSizeFromPreferences()
    migrationController.activate()
    computerUseController.activate()
    window.center()
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func configure() {
    guard let content = window?.contentView else { return }
    content.wantsLayer = true
    content.layer?.backgroundColor = OuroTheme.canvas.cgColor

    let title = NSTextField(labelWithString: "Terminal")
    title.font = OuroTheme.uiFont(size: 22, weight: .semibold)
    title.textColor = OuroTheme.text

    let subtitle = NSTextField(labelWithString: "Text and bell preferences apply to every terminal.")
    subtitle.font = OuroTheme.uiFont(size: 13)
    subtitle.textColor = OuroTheme.muted

    let typeLabel = NSTextField(labelWithString: "Text size")
    typeLabel.font = OuroTheme.uiFont(size: 13, weight: .medium)
    typeLabel.textColor = OuroTheme.text
    fontSizeSlider.target = self
    fontSizeSlider.action = #selector(fontSizeChanged(_:))
    fontSizeSlider.isContinuous = true
    fontSizeSlider.setAccessibilityLabel(MacCommandAccessibility.settingsFontSizeLabel)
    fontSizeLabel.alignment = .right
    fontSizeLabel.textColor = OuroTheme.muted
    fontSizeLabel.font = OuroTheme.uiFont(size: 12)
    fontSizeLabel.setAccessibilityLabel(MacCommandAccessibility.settingsCurrentFontSizeLabel)

    let reset = NSButton(title: "Reset", target: self, action: #selector(resetFontSize(_:)))
    reset.bezelStyle = .rounded
    reset.setAccessibilityLabel(MacCommandAccessibility.settingsResetFontSizeLabel)

    visualBell.target = self
    visualBell.action = #selector(visualBellChanged(_:))
    visualBell.state = TerminalPreferences.visualBell ? .on : .off
    visualBell.setAccessibilityLabel(MacCommandAccessibility.settingsVisualBellLabel)
    audibleBell.target = self
    audibleBell.action = #selector(audibleBellChanged(_:))
    audibleBell.state = TerminalPreferences.audibleBell ? .on : .off
    audibleBell.setAccessibilityLabel(MacCommandAccessibility.settingsAudibleBellLabel)

    let bellHeader = NSTextField(labelWithString: "Notifications")
    bellHeader.font = OuroTheme.uiFont(size: 13, weight: .medium)
    bellHeader.textColor = OuroTheme.text

    let sizeRow = NSStackView(views: [typeLabel, fontSizeSlider, fontSizeLabel, reset])
    sizeRow.orientation = .horizontal
    sizeRow.alignment = .centerY
    sizeRow.spacing = 10
    sizeRow.setHuggingPriority(.required, for: .horizontal)
    fontSizeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
    typeLabel.widthAnchor.constraint(equalToConstant: 72).isActive = true
    fontSizeLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true

    let separator = HairlineView()
    separator.translatesAutoresizingMaskIntoConstraints = false
    let migrationSeparator = HairlineView()
    let computerUseSeparator = HairlineView()
    computerUseSeparator.translatesAutoresizingMaskIntoConstraints = false
    let computerUseView = computerUseController.view
    computerUseView.translatesAutoresizingMaskIntoConstraints = false
    migrationSeparator.translatesAutoresizingMaskIntoConstraints = false
    let migrationView = migrationController.view
    migrationView.translatesAutoresizingMaskIntoConstraints = false
    let stack = NSStackView(views: [
      title,
      subtitle,
      sizeRow,
      separator,
      bellHeader,
      visualBell,
      audibleBell,
      computerUseSeparator,
      computerUseView,
      migrationSeparator,
      migrationView,
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false

    let document = NSView()
    document.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = document
    scroll.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(scroll)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: content.topAnchor),
      scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 32),
      stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -32),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 28),
      stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -28),
      sizeRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      separator.widthAnchor.constraint(equalTo: stack.widthAnchor),
      separator.heightAnchor.constraint(equalToConstant: 1),
      migrationSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
      computerUseSeparator.widthAnchor.constraint(equalTo: stack.widthAnchor),
      computerUseSeparator.heightAnchor.constraint(equalToConstant: 1),
      computerUseView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      computerUseView.heightAnchor.constraint(equalToConstant: 190),
      migrationSeparator.heightAnchor.constraint(equalToConstant: 1),
      migrationView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      migrationView.heightAnchor.constraint(equalToConstant: 370),
    ])
    fontSizeSlider.doubleValue = Double(OuroTheme.terminalFontSize)
    updateFontSizeLabel()
  }

  @objc private func fontSizeChanged(_ sender: NSSlider) {
    let value = CGFloat(sender.doubleValue.rounded())
    sender.doubleValue = Double(value)
    terminal?.setTerminalFontSize(value)
    updateFontSizeLabel()
  }

  @objc private func resetFontSize(_ sender: Any?) {
    terminal?.resetTerminalFontSize(nil)
    fontSizeSlider.doubleValue = Double(OuroTheme.terminalFontSize)
    updateFontSizeLabel()
  }

  @objc private func visualBellChanged(_ sender: NSButton) {
    TerminalPreferences.visualBell = sender.state == .on
  }

  @objc private func audibleBellChanged(_ sender: NSButton) {
    TerminalPreferences.audibleBell = sender.state == .on
  }

  private func updateFontSizeLabel() {
    fontSizeLabel.stringValue = "\(Int(OuroTheme.terminalFontSize.rounded())) pt"
    fontSizeLabel.setAccessibilityValue(fontSizeLabel.stringValue)
  }

  private func syncFontSizeFromPreferences() {
    guard fontSizeSlider.window != nil else { return }
    fontSizeSlider.doubleValue = Double(OuroTheme.terminalFontSize)
    updateFontSizeLabel()
  }
}
