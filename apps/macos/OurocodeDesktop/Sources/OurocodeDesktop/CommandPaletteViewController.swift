import AppKit

private final class CommandPaletteSearchField: NSSearchField {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if stringValue.isEmpty { onCancel?() }
        else { stringValue = ""; sendAction(action, to: target) }
    }
}

private final class CommandPaletteTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onCancel: (() -> Void)?
    var onPrimaryClick: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 {
            onReturn?()
            return
        }
        if event.keyCode == 53 {
            onCancel?()
            return
        }
        super.keyDown(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        guard event.clickCount == 1, clickedRow >= 0 else { return }
        onPrimaryClick?()
    }
}

final class CommandPaletteViewController: NSViewController,
    NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate
{
    private let searchField = CommandPaletteSearchField()
    private let tableView = CommandPaletteTableView()
    private let emptyLabel = NSTextField(labelWithString: "No matching commands")
    private var snapshot: [CommandDescriptor] = []
    private var results: [CommandDescriptor] = []
    private weak var effectView: NSVisualEffectView?
    private var accessibilityObserver: NSObjectProtocol?
    var onActivate: ((CommandID) -> Void)?
    var onCancel: (() -> Void)?

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override func loadView() {
        let root = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 620, height: 430))
        effectView = root
        applyAccessibilityAppearance()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessibilityAppearance()
        }

        searchField.placeholderString = "Search commands, tabs, and sessions"
        searchField.font = OuroTheme.uiFont(size: 17, weight: .regular)
        // The native focus ring is the keyboard user's persistent cue in this
        // floating panel. Keep it visible under every display appearance.
        searchField.focusRingType = .default
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.onCancel = { [weak self] in self?.onCancel?() }
        searchField.setAccessibilityLabel("Command Palette search")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 54
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.onReturn = { [weak self] in self?.activateSelection(nil) }
        tableView.onCancel = { [weak self] in self?.onCancel?() }
        tableView.onPrimaryClick = { [weak self] in self?.activateSelection(nil) }
        tableView.setAccessibilityLabel("Command Palette results")

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = OuroTheme.uiFont(size: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(divider)
        root.addSubview(scroll)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            searchField.heightAnchor.constraint(equalToConstant: 34),
            divider.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 14),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            emptyLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 620, height: 430)
    }

    private func applyAccessibilityAppearance() {
        guard let root = effectView else { return }
        let accessibility = OuroTheme.accessibility
        root.state = .active
        root.material = accessibility.reduceTransparency || accessibility.increaseContrast
            ? .windowBackground
            : .popover
        root.blendingMode = accessibility.reduceTransparency ? .withinWindow : .behindWindow
        root.wantsLayer = true
        root.layer?.borderColor = NSColor.separatorColor.cgColor
        root.layer?.borderWidth = accessibility.increaseContrast ? 1 : 0
    }

    func present(snapshot: [CommandDescriptor]) {
        _ = view
        self.snapshot = snapshot
        searchField.stringValue = ""
        applySearch()
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) { applySearch() }

    @objc private func searchChanged(_ sender: Any?) { applySearch() }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(nil)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("command-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let command = results[row]
        cell.imageView?.image = NSImage(
            systemSymbolName: command.symbolName,
            accessibilityDescription: nil
        )
        cell.textField?.stringValue = command.title
        (cell.viewWithTag(8_101) as? NSTextField)?.stringValue = command.subtitle ?? command.section.rawValue
        (cell.viewWithTag(8_102) as? NSTextField)?.stringValue = command.shortcut ?? ""
        cell.setAccessibilityLabel(command.title)
        cell.setAccessibilityHelp(command.subtitle ?? command.section.rawValue)
        return cell
    }

    private func applySearch() {
        results = CommandPaletteSearch.results(for: searchField.stringValue, in: snapshot)
        tableView.reloadData()
        emptyLabel.isHidden = !results.isEmpty
        if results.isEmpty { tableView.deselectAll(nil) }
        else { tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    private func moveSelection(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = max(0, tableView.selectedRow)
        let row = min(results.count - 1, max(0, current + delta))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func activateSelection(_ sender: Any?) {
        let row = tableView.selectedRow
        guard results.indices.contains(row) else { NSSound.beep(); return }
        onActivate?(results[row].id)
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: "")
        title.font = OuroTheme.uiFont(size: 13.5, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        title.translatesAutoresizingMaskIntoConstraints = false
        let subtitle = NSTextField(labelWithString: "")
        subtitle.tag = 8_101
        subtitle.font = OuroTheme.uiFont(size: 11.5)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingMiddle
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        let shortcut = NSTextField(labelWithString: "")
        shortcut.tag = 8_102
        shortcut.font = OuroTheme.monoFont(size: 11)
        shortcut.textColor = .tertiaryLabelColor
        shortcut.alignment = .right
        shortcut.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = icon
        cell.textField = title
        cell.addSubview(icon)
        cell.addSubview(title)
        cell.addSubview(subtitle)
        cell.addSubview(shortcut)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            title.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: shortcut.leadingAnchor, constant: -10),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            shortcut.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -12),
            shortcut.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            shortcut.widthAnchor.constraint(lessThanOrEqualToConstant: 90),
        ])
        return cell
    }
}

final class CommandPaletteCoordinator: NSObject, NSWindowDelegate {
    private let registry: CommandRegistry
    private let viewController = CommandPaletteViewController()
    private let panel: NSPanel
    private weak var previousWindow: NSWindow?
    private weak var previousResponder: NSResponder?

    init(registry: CommandRegistry) {
        self.registry = registry
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 430),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        panel.title = "Command Palette"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.contentViewController = viewController
        panel.delegate = self
        viewController.onCancel = { [weak self] in self?.close() }
        viewController.onActivate = { [weak self] id in self?.activate(id) }
    }

    func toggle(relativeTo owner: NSWindow?) {
        if panel.isVisible { close(); return }
        previousWindow = NSApp.keyWindow
        previousResponder = NSApp.keyWindow?.firstResponder
        if let owner {
            let origin = NSPoint(
                x: owner.frame.midX - panel.frame.width / 2,
                y: owner.frame.maxY - panel.frame.height - 86
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
        viewController.present(snapshot: registry.snapshot())
    }

    func close() {
        panel.orderOut(nil)
        restoreFocus()
    }

    func windowWillClose(_ notification: Notification) { restoreFocus() }

    private func activate(_ id: CommandID) {
        panel.orderOut(nil)
        switch registry.perform(id) {
        case .executed:
            break
        case .unavailable(let reason):
            NSSound.beep()
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: reason, .priority: NSAccessibilityPriorityLevel.high.rawValue]
            )
        }
    }

    private func restoreFocus() {
        guard let previousWindow, previousWindow.isVisible else { return }
        previousWindow.makeKeyAndOrderFront(nil)
        if let previousResponder { previousWindow.makeFirstResponder(previousResponder) }
    }
}
