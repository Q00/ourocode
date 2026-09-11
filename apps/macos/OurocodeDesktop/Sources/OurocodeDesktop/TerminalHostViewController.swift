import AppKit
import SwiftTerm

private final class TerminalTextSizeHUDView: NSView {
    // Feedback must never steal pointer selection or terminal focus, including
    // during its short visible interval.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class TerminalTabButton: NSButton {
    private var pointerInside = false
    private var closePressed = false
    private var closePressInside = false
    private var pointerTrackingArea: NSTrackingArea?
    var onRequestClose: (() -> Void)?
    var onRequestRename: (() -> Void)?
    var onRequestMoveLeft: (() -> Void)?
    var onRequestMoveRight: (() -> Void)?
    var compactWidthConstraint: NSLayoutConstraint?
    var compactHeightConstraint: NSLayoutConstraint?
    var preferredWidth: CGFloat = TerminalTabWidthPolicy.minimumWidth

    /// Stable semantic identity for accessibility focus. `tag` is only the
    /// current array index and becomes stale as soon as a preceding tab closes.
    var representedTabID: UUID?

    private var closeRect: NSRect {
        NSRect(x: bounds.maxX - 27, y: bounds.midY - 9, width: 18, height: 18)
    }

    override var state: NSControl.StateValue {
        didSet {
            updateContentTint()
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet {
            updateContentTint()
            needsDisplay = true
        }
    }

    private func updateContentTint() {
        if !isEnabled {
            contentTintColor = .tertiaryLabelColor
            font = OuroTheme.uiFont(size: 13.5, weight: .regular)
        } else {
            contentTintColor = state == .on ? .labelColor : OuroTheme.tabText
            font = OuroTheme.uiFont(size: 13.5, weight: state == .on ? .semibold : .regular)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        pointerTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        pointerInside = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerInside = false
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if closeRect.contains(point), pointerInside, isEnabled {
            closePressed = true
            closePressInside = true
            needsDisplay = true
            return
        }
        if event.clickCount == 2, isEnabled {
            onRequestRename?()
            return
        }
        super.mouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard isEnabled else { return nil }
        let menu = NSMenu(title: "Terminal Tab")
        let rename = menu.addItem(
            withTitle: "Rename Tab…",
            action: #selector(requestRename(_:)),
            keyEquivalent: ""
        )
        rename.target = self
        let moveLeft = menu.addItem(
            withTitle: "Move Tab Left",
            action: #selector(requestMoveLeft(_:)),
            keyEquivalent: ""
        )
        moveLeft.target = self
        moveLeft.isEnabled = onRequestMoveLeft != nil
        let moveRight = menu.addItem(
            withTitle: "Move Tab Right",
            action: #selector(requestMoveRight(_:)),
            keyEquivalent: ""
        )
        moveRight.target = self
        moveRight.isEnabled = onRequestMoveRight != nil
        menu.addItem(.separator())
        let close = menu.addItem(
            withTitle: "Close Tab",
            action: #selector(requestClose(_:)),
            keyEquivalent: ""
        )
        close.target = self
        return menu
    }

    @objc private func requestRename(_ sender: Any?) { onRequestRename?() }
    @objc private func requestMoveLeft(_ sender: Any?) { onRequestMoveLeft?() }
    @objc private func requestMoveRight(_ sender: Any?) { onRequestMoveRight?() }
    @objc private func requestClose(_ sender: Any?) { onRequestClose?() }

    override func mouseDragged(with event: NSEvent) {
        guard closePressed else {
            super.mouseDragged(with: event)
            return
        }
        closePressInside = closeRect.contains(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard closePressed else {
            super.mouseUp(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        closePressed = false
        closePressInside = false
        needsDisplay = true
        if closeRect.contains(point), isEnabled {
            onRequestClose?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = bounds.insetBy(dx: 2, dy: 3)
        let pillPath = NSBezierPath(roundedRect: pill, xRadius: 8, yRadius: 8)
        if state == .on {
            NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
            pillPath.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.72).setStroke()
            pillPath.lineWidth = 1
            pillPath.stroke()
        } else if pointerInside && isEnabled {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            pillPath.fill()
        }
        if isHighlighted && isEnabled && !closePressed {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            pillPath.fill()
        }
        super.draw(dirtyRect)
        if closePressed && closePressInside {
            NSColor.labelColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(ovalIn: closeRect.insetBy(dx: 1, dy: 1)).fill()
        }
        // Keep the title quiet and readable at rest. The close affordance
        // appears as soon as the pointer enters the tab, while Command-W stays
        // available as the permanent, familiar path.
        if pointerInside, isEnabled,
           let image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil) {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
            let configured = image.withSymbolConfiguration(configuration) ?? image
            NSColor.secondaryLabelColor.set()
            configured.draw(in: closeRect.insetBy(dx: 4, dy: 4))
        }
    }
}

private struct TerminalTabPickerItem {
    let index: Int
    let title: String
    let path: String
    let selected: Bool
}

private final class TerminalTabPickerViewController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate, NSSearchFieldDelegate
{
    private let searchField = NSSearchField()
    private let tableView = TerminalTabPickerTableView()
    private var items: [TerminalTabPickerItem] = []
    private var filteredItems: [TerminalTabPickerItem] = []
    private var refreshingSelection = false
    var onSelect: ((Int) -> Void)?

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 360))

        searchField.placeholderString = "Search tabs"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search all terminal tabs")
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("terminal-tab"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 48
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.onActivateSelection = { [weak self] in self?.chooseSelectedRow() }
        tableView.setAccessibilityLabel("All terminal tabs")

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(searchField)
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        preferredContentSize = NSSize(width: 340, height: 360)
    }

    func update(items: [TerminalTabPickerItem]) {
        _ = view
        self.items = items
        applyFilter()
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
    }

    func controlTextDidChange(_ notification: Notification) {
        applyFilter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        activateSearchResult()
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredItems.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard filteredItems.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("terminal-tab-cell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView)
            ?? makeCell(identifier: identifier)
        let item = filteredItems[row]
        cell.textField?.stringValue = item.title
        cell.textField?.toolTip = item.path
        cell.imageView?.image = item.selected
            ? NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Selected")
            : nil
        if let pathLabel = cell.viewWithTag(9_102) as? NSTextField {
            pathLabel.stringValue = (item.path as NSString).abbreviatingWithTildeInPath
            pathLabel.toolTip = item.path
        }
        cell.setAccessibilityLabel("Terminal \(item.index + 1): \(item.title)")
        cell.setAccessibilityHelp(item.selected ? "Selected terminal tab" : "Switch to this terminal tab")
        if let activationCell = cell as? TerminalTabPickerCellView {
            activationCell.onAccessibilityPress = { [weak self] in
                self?.onSelect?(item.index)
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let source = notification.object as? NSTableView,
              source === tableView,
              !refreshingSelection else { return }
        tableView.activateSelectionChangeIfNeeded()
    }

    private func chooseSelectedRow() {
        let row = tableView.selectedRow
        guard filteredItems.indices.contains(row) else { return }
        onSelect?(filteredItems[row].index)
    }

    private func activateSearchResult() {
        if tableView.selectedRow < 0, !filteredItems.isEmpty {
            refreshingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            refreshingSelection = false
        }
        chooseSelectedRow()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            filteredItems = items
        } else {
            filteredItems = items.filter {
                $0.title.localizedCaseInsensitiveContains(query)
                    || $0.path.localizedCaseInsensitiveContains(query)
                    || String($0.index + 1) == query
            }
        }
        tableView.reloadData()
        refreshingSelection = true
        tableView.suppressSelectionActivation = true
        defer {
            tableView.suppressSelectionActivation = false
            refreshingSelection = false
        }
        if let row = filteredItems.firstIndex(where: \.selected) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func makeCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = TerminalTabPickerCellView()
        cell.identifier = identifier
        let selectedImage = NSImageView()
        selectedImage.setAccessibilityElement(false)
        selectedImage.translatesAutoresizingMaskIntoConstraints = false
        selectedImage.setContentHuggingPriority(.required, for: .horizontal)
        cell.imageView = selectedImage
        let label = NSTextField(labelWithString: "")
        label.setAccessibilityElement(false)
        label.font = OuroTheme.uiFont(size: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        let pathLabel = NSTextField(labelWithString: "")
        pathLabel.setAccessibilityElement(false)
        pathLabel.tag = 9_102
        pathLabel.font = OuroTheme.uiFont(size: 11.5)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = label
        cell.addSubview(selectedImage)
        cell.addSubview(label)
        cell.addSubview(pathLabel)
        NSLayoutConstraint.activate([
            selectedImage.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            selectedImage.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            selectedImage.widthAnchor.constraint(equalToConstant: 14),
            selectedImage.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: selectedImage.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
            pathLabel.leadingAnchor.constraint(equalTo: label.leadingAnchor),
            pathLabel.trailingAnchor.constraint(equalTo: label.trailingAnchor),
            pathLabel.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 1),
            pathLabel.bottomAnchor.constraint(lessThanOrEqualTo: cell.bottomAnchor, constant: -5),
        ])
        return cell
    }
}

private final class LocalTerminalTab {
    let id = UUID()
    let createNonce: String
    let displaySequence: UInt64
    var title: String
    var path: String
    /// Populated only when Ouroboros supplies the broker terminal identity.
    /// Until then the shell title remains the truthful tab label.
    var sessionBinding: TerminalSessionBinding?
    var titleWasSetByShell = false
    var titleWasSetByUser = false
    var pendingInitialCommand: String?
    let shellLaunchMode: TerminalShellLaunchMode
    var brokerTerminalID: String?
    var attachment: BrokerAttachment?
    var cursor: UInt64 = 0
    var running = false
    var foregroundProcess = false
    var creating = false
    var createRejected = false
    var creationFallbackTabID: UUID?
    var attaching = false
    var closing = false
    var removalDisposition: TerminalViewDisposition?
    var attachmentCancellationRequested = false
    var detachingForRemoval = false
    var terminating = false
    var creationOutcomeUnknown = false
    var createReconciliationInFlight = false
    var hasRenderedState = false
    /// Set only for a fresh zsh launched after our OSC 133 integration proxy
    /// was installed successfully. Restored and explicit-shell tabs must not
    /// wait for semantics they may never emit.
    var requiresSemanticPromptReadiness = false
    /// Once this fresh shell emitted a complete prompt/input boundary, later
    /// tab switches may trust that startup completed and must not re-gate on
    /// whether the old prompt remains inside the current viewport.
    var semanticPromptReadinessObserved = false
    var layoutEpoch: UInt64 = 0
    var typographyProjection = TerminalTypographyProjectionState()
    #if OUROCODE_GHOSTTY_RENDERER
    /// RFC 0008 step-2 model seam. This one-leaf workspace mirrors only the
    /// exact broker terminal identity and owns no broker, PTY, or renderer
    /// authority. The existing host state machine remains authoritative until
    /// multi-pane projection is implemented.
    private(set) var workspaceTab: TerminalWorkspaceTab?
    private(set) var workspaceModelError: TerminalWorkspaceTabError?
    #endif

    init(
        displaySequence: UInt64,
        title: String,
        path: String,
        pendingInitialCommand: String?,
        shellLaunchMode: TerminalShellLaunchMode = .configured,
        brokerTerminal: BrokerTerminalSummary? = nil
    ) {
        self.displaySequence = displaySequence
        createNonce = brokerTerminal?.createNonce ?? UUID().uuidString
        self.title = title
        self.path = path
        self.pendingInitialCommand = pendingInitialCommand
        self.shellLaunchMode = shellLaunchMode
        brokerTerminalID = brokerTerminal?.id
        cursor = brokerTerminal?.cursor ?? 0
        layoutEpoch = brokerTerminal?.layoutEpoch ?? 0
        running = brokerTerminal?.running ?? false
        foregroundProcess = brokerTerminal?.foregroundProcess ?? false
    }

    var removalRequested: Bool { removalDisposition != nil }

    #if OUROCODE_GHOSTTY_RENDERER
    @MainActor
    func installOneLeafWorkspace(occupiedTerminalIDs: Set<String>) {
        guard workspaceTab == nil, let brokerTerminalID else { return }
        do {
            workspaceTab = try TerminalWorkspaceTab(
                terminalID: brokerTerminalID,
                displaySequence: displaySequence,
                title: title,
                occupiedTerminalIDs: occupiedTerminalIDs,
                tabID: id
            )
            workspaceModelError = nil
        } catch let error as TerminalWorkspaceTabError {
            // Do not perturb the proven single-surface host path. A duplicate
            // or invalid model identity fails closed inside this sidecar and
            // remains diagnosable without acquiring any runtime authority.
            workspaceModelError = error
        } catch {
            workspaceModelError = .layoutIdentityMismatch
        }
    }

    @MainActor
    func synchronizeWorkspaceTitle() {
        workspaceTab?.title = title
    }
    #endif
}

private struct ClosedTerminalViewRecord: Equatable {
    let terminalID: String
    let displaySequence: UInt64
    let title: String
    let path: String
    let cursor: UInt64
    let fontPointSize: CGFloat

}

final class TerminalHostViewController: NSViewController, NSMenuItemValidation, CommandProvider {
    private static let maximumTabs = 32

    var onToggleSources: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenCommandPalette: (() -> Void)?
    /// The terminal broker is the sole source of this authority state. The
    /// Sessions rail must never derive it from MCP catalog data.
    var onSessionMessageCapabilityStateChange: ((SessionMessageCapabilityStateV1) -> Void)?
    /// Publishes the exact MCP attempt bound to the pane that currently owns
    /// terminal focus. This never transfers PTY input or steering authority.
    var onFocusedSessionPaneChange: ((SessionPaneSteeringFocus?) -> Void)?
    /// Live broker-owned terminal sessions, including Claude/Codex processes
    /// running inside ordinary shell tabs. The sessions rail uses this as its
    /// primary terminal-like projection; Ouroboros history is secondary.
    var onLiveTerminalSessionsChange: (([LiveTerminalSession]) -> Void)?


    private let tabStrip = NSStackView()
    private let tabTailSpacer = NSView()
    private let tabScrollView = NSScrollView()
    private let leadingTabOverflowCue = TerminalTabOverflowCueView(edge: .leading)
    private let trailingTabOverflowCue = TerminalTabOverflowCueView(edge: .trailing)
    private let chromeControls = NSStackView()
    private let sourcesButton = NSButton(title: "", target: nil, action: nil)
    private let addButton = NSButton(title: "", target: nil, action: nil)
    private let allTabsButton = NSButton(title: "", target: nil, action: nil)
    private let commandPaletteButton = NSButton(title: "", target: nil, action: nil)
    private let chrome = NSVisualEffectView()
    private let terminalContainer = NSView()
    private let sessionWorkspaceBackdrop = NSView()
    private weak var sessionWorkspaceContent: MCPDetailOverlayView?
    private var terminalContainerWasHiddenBeforeSessionWorkspace = false
    private var shellStartupWasHiddenBeforeSessionWorkspace = true
    private let shellStartupView = TerminalShellStartupView()
    private let textSizeHUD = TerminalTextSizeHUDView()
    private let textSizeHUDLabel = NSTextField(labelWithString: "")
    private var textSizeHUDHideWorkItem: DispatchWorkItem?
    private var textSizeHUDGeneration: UInt64 = 0
    private let compatibilityLabel = NSTextField(labelWithString: "Compatibility · broker v3")
    private var tabs: [LocalTerminalTab] = []
    /// Existing broker terminals retain their own typography. `OuroTheme`
    /// remains the default for newly created sessions only.
    private var terminalFontSizes: [String: CGFloat] = [:]
    private var focusedTypographyTerminalID: String?
    /// Same-process convenience only. The broker remains authoritative, so an
    /// app relaunch reconstructs these views from `list` instead of this stack.
    private var closedViews: [ClosedTerminalViewRecord] = []
    /// Coalesce repeated MCP clicks while the broker verifies and adopts a
    /// durable PTY that has no local view yet. Every waiter is resolved exactly
    /// once; no click is allowed to manufacture a shell or bypass `list`.
    private struct PendingSessionActivationWaiter {
        let requestIsCurrent: () -> Bool
        let completion: (TerminalSessionActivationResult) -> Void
    }
    private var pendingSessionActivations: [
        String: [PendingSessionActivationWaiter]
    ] = [:]
    /// Monotonic projection epoch for MCP-owned attempt-to-PTY bindings.
    /// Broker list callbacks must revalidate this epoch before selecting or
    /// adopting a terminal.
    private var advertisedSessionBindings: [TerminalSessionBinding] = []
    private var advertisedSessionBindingsRevision: UInt64 = 0
    private var publishedFocusedSessionPane: SessionPaneSteeringFocus?
    private var nextTabDisplaySequence: UInt64 = 1
    private var selectedIndex = 0
    private var appeared = false
    private var keyMonitor: Any?
    private var tabButtons: [TerminalTabButton] = []
    private var tabButtonIndices: [Int] = []
    private var tabProjectionGeneration: UInt64 = 0
    private var allTabsPopover: NSPopover?
    private var findPanelController: TerminalFindPanelController?
    private var tabClipBoundsObserver: NSObjectProtocol?
    // Broker incarnation gates both Ghostty attachment and the optional
    // Ouroboros session-to-terminal projection, including compatibility mode.
    private var brokerGeneration: UInt64?
    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private let broker = BrokerClient(
        socketURL: GhosttyRenderDeployment.socketURL,
        orderedV4HelperName: GhosttyRenderDeployment.helperName
    )
    private var surfaceCoordinator: TerminalSurfaceCoordinator?
    #else
    private let broker = BrokerClient()
    #endif
    private var brokerReady = false
    private var sessionMessageGateway: SessionMessageGatewayClientV1?
    private var restoredInitialState = false
    /// Ourocode owns one retained app-side projection. Tabs are broker-owned
    /// metadata only; a hidden tab never retains a terminal renderer.
    private var mirrorTerminal: AccessibleTerminalView?
    private weak var mirrorTab: LocalTerminalTab?
    private var candidateTerminal: AccessibleTerminalView?
    private weak var desiredMirrorTab: LocalTerminalTab?
    /// Explicit tab selection owns focus until the selected terminal has been
    /// attached and made first responder. Metadata/title rebuilds must not
    /// restore focus to a reused tab button during that handoff.
    private var pendingTerminalFocusTabID: UUID?
    private var transitionGeneration: UInt64 = 0
    private var surfaceBindingGeneration: UInt64 = 0
    private var transitionInFlight = false
    private var preparingTerminalID: String?
    private var inputLocked = true
    private var pendingResizeWorkItem: DispatchWorkItem?
    #if OUROCODE_GHOSTTY_METAL_SURFACE
    /// A first Metal frame is presentation only. This gate stays closed until
    /// Ghostty reports both OSC 133 prompt and input semantics for this exact
    /// tab/generation, preventing instant-prompt startup from accepting input.
    private var semanticPromptReadiness = TerminalSemanticPromptReadiness()
    private var shellStartupWatchdog: DispatchWorkItem?
    /// Additional split leaves for the selected workspace. Tab switching
    /// tears these runtimes down and restores only broker-authoritative IDs;
    /// hidden tabs never retain a renderer.
    private var additionalPaneRuntimes: [String: TerminalPaneRuntime] = [:]
    /// Strong owner when an already-presented pane becomes the tab's retained
    /// primary surface. It remains distinct from `additionalPaneRuntimes` so
    /// tab switching can detach it through the ordinary primary FIFO barrier.
    private var promotedPrimaryPaneRuntime: TerminalPaneRuntime?
    /// Strong owner for the one renderer/attachment candidate that exists
    /// before workspace CAS publishes it. NSView owns only the pane's view;
    /// broker callbacks intentionally capture the runtime weakly, so without
    /// this slot the authority object can disappear after prepareAttachment
    /// while its broker PTY remains alive.
    private var stagedPaneRuntime: TerminalPaneRuntime?
    private var workspacePaneContainers: [String: NSView] = [:]
    private var splitOperationInFlight = false
    private weak var additionalPaneOwnerTab: LocalTerminalTab?
    private weak var pendingPaneSwitchTab: LocalTerminalTab?
    private var additionalPaneTeardownInFlight = false
    private var additionalPaneRestoreInFlight = false
    #endif

    let commandProviderID = CommandProviderID(rawValue: "terminal")!
    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private struct GhosttyResizeRequest: Equatable {
        let tabID: UUID
        let projectionAuthority: TerminalTypographyProjectionAuthority
        let baselineLayoutEpoch: UInt64
        let columns: Int
        let rows: Int
        let cellWidthPixels: Int
        let cellHeightPixels: Int
        let backingScale: CGFloat
        /// Cell geometry can remain identical across adjacent point sizes
        /// after CoreText's pixel rounding. Keep the requested font in the
        /// transaction identity so ⌘+ / ⌘− still rebuilds the atlas in that
        /// case instead of being discarded as a no-op resize.
        let fontPointSize: CGFloat

        var projectionIdentity: TerminalTypographyProjectionIdentity {
            TerminalTypographyProjectionIdentity(
                columns: columns,
                rows: rows,
                cellWidthPixels: cellWidthPixels,
                cellHeightPixels: cellHeightPixels,
                backingScale: backingScale,
                fontPointSize: fontPointSize
            )
        }

        func hasSameGeometry(as other: GhosttyResizeRequest) -> Bool {
            tabID == other.tabID
                && projectionAuthority == other.projectionAuthority
                && columns == other.columns
                && rows == other.rows
                && cellWidthPixels == other.cellWidthPixels
                && cellHeightPixels == other.cellHeightPixels
                && backingScale == other.backingScale
                && fontPointSize == other.fontPointSize
        }
    }
    private final class GhosttyResizeTransaction {
        var request: GhosttyResizeRequest
        var brokerAccepted = false
        var pointerGateReady = false
        var targetLayoutEpoch: UInt64?

        init(request: GhosttyResizeRequest) {
            self.request = request
        }
    }
    private var pendingGhosttyResize: GhosttyResizeRequest?
    private var activeGhosttyResize: GhosttyResizeTransaction?
    #endif

    deinit {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        shellStartupWatchdog?.cancel()
        #endif
        if let tabClipBoundsObserver {
            NotificationCenter.default.removeObserver(tabClipBoundsObserver)
        }
    }

    override func loadView() {
        let root = TerminalAppearanceTrackingView()
        root.onAppearanceChange = { [weak self] in self?.updateThemeLayers() }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        root.onBackingPropertiesChange = { [weak self] in self?.scheduleGhosttyResize() }
        #endif
        root.wantsLayer = true
        root.layer?.backgroundColor = OuroTheme.canvas.cgColor
        view = root

        chrome.wantsLayer = true
        chrome.state = .active
        chrome.blendingMode = .withinWindow
        chrome.translatesAutoresizingMaskIntoConstraints = false

        tabStrip.orientation = .horizontal
        tabStrip.alignment = .centerY
        tabStrip.spacing = 0
        tabStrip.distribution = .fill
        tabStrip.setAccessibilityLabel("Terminal tabs")
        tabStrip.setAccessibilityRole(.radioGroup)
        tabStrip.translatesAutoresizingMaskIntoConstraints = true

        tabScrollView.documentView = tabStrip
        tabScrollView.hasHorizontalScroller = false
        tabScrollView.hasVerticalScroller = false
        tabScrollView.autohidesScrollers = true
        tabScrollView.scrollerStyle = .overlay
        tabScrollView.drawsBackground = false
        tabScrollView.borderType = .noBorder
        tabScrollView.horizontalScrollElasticity = .automatic
        tabScrollView.translatesAutoresizingMaskIntoConstraints = false
        tabScrollView.contentView.postsBoundsChangedNotifications = true
        tabClipBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: tabScrollView.contentView,
            queue: .main
        ) { [weak self] _ in self?.updateTabOverflowCues() }

        configureSymbolButton(addButton, symbol: "plus", label: "New terminal tab")
        configureSymbolButton(allTabsButton, symbol: "list.bullet", label: "Show all terminal tabs")
        configureSymbolButton(sourcesButton, symbol: "sidebar.left", label: "Show Connections")
        configureSymbolButton(
            commandPaletteButton,
            symbol: "rectangle.and.text.magnifyingglass",
            label: "Command Palette"
        )
        sourcesButton.setButtonType(.momentaryPushIn)
        for button in [
            sourcesButton,
            addButton,
            allTabsButton,
            commandPaletteButton,
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        sourcesButton.target = self
        sourcesButton.action = #selector(toggleSources(_:))
        addButton.target = self
        addButton.action = #selector(addTab(_:))
        allTabsButton.target = self
        allTabsButton.action = #selector(showAllTabs(_:))
        commandPaletteButton.target = self
        commandPaletteButton.action = #selector(openCommandPalette(_:))
        commandPaletteButton.toolTip = "Command Palette · ⌘P"
        commandPaletteButton.setAccessibilityHelp("Search commands, terminal tabs, and Ouroboros sessions.")


        let divider = HairlineView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        terminalContainer.translatesAutoresizingMaskIntoConstraints = false
        terminalContainer.wantsLayer = true
        terminalContainer.layer?.masksToBounds = true
        sessionWorkspaceBackdrop.translatesAutoresizingMaskIntoConstraints = false
        sessionWorkspaceBackdrop.wantsLayer = true
        sessionWorkspaceBackdrop.isHidden = true
        sessionWorkspaceBackdrop.setAccessibilityElement(true)
        sessionWorkspaceBackdrop.setAccessibilityRole(.group)
        sessionWorkspaceBackdrop.setAccessibilityLabel("Session workspace")
        shellStartupView.onOpenCleanShell = { [weak self] identity in
            self?.openCleanShell(from: identity)
        }

        // Immediate, bounded feedback makes keyboard zoom discoverable without
        // adding permanent chrome. One retained HUD is reused for every zoom
        // event; it never allocates per tab or per key repeat.
        textSizeHUD.wantsLayer = true
        textSizeHUD.layer?.cornerRadius = 10
        textSizeHUD.layer?.masksToBounds = true
        textSizeHUD.layer?.borderWidth = 1
        textSizeHUD.isHidden = true
        textSizeHUD.setAccessibilityElement(false)
        textSizeHUD.translatesAutoresizingMaskIntoConstraints = false

        textSizeHUDLabel.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        textSizeHUDLabel.textColor = .labelColor
        textSizeHUDLabel.alignment = .center
        textSizeHUDLabel.setAccessibilityElement(false)
        textSizeHUDLabel.translatesAutoresizingMaskIntoConstraints = false
        textSizeHUD.addSubview(textSizeHUDLabel)

        compatibilityLabel.font = OuroTheme.uiFont(size: 10, weight: .medium)
        compatibilityLabel.textColor = .systemOrange
        compatibilityLabel.lineBreakMode = .byTruncatingTail
        compatibilityLabel.isHidden = true
        compatibilityLabel.setAccessibilityLabel("Terminal status")
        compatibilityLabel.translatesAutoresizingMaskIntoConstraints = false

        chromeControls.orientation = .horizontal
        chromeControls.alignment = .centerY
        chromeControls.spacing = 4
        chromeControls.addArrangedSubview(commandPaletteButton)
        chromeControls.addArrangedSubview(addButton)
        chromeControls.translatesAutoresizingMaskIntoConstraints = false

        chrome.addSubview(sourcesButton)
        chrome.addSubview(chromeControls)
        chrome.addSubview(divider)
        root.addSubview(chrome)
        root.addSubview(terminalContainer)
        root.addSubview(shellStartupView)
        root.addSubview(textSizeHUD)
        root.addSubview(sessionWorkspaceBackdrop)

        NSLayoutConstraint.activate([
            chrome.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor),
            chrome.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            chrome.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            chrome.heightAnchor.constraint(equalToConstant: 40),

            sourcesButton.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 8),
            sourcesButton.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            sourcesButton.widthAnchor.constraint(equalToConstant: 32),
            sourcesButton.heightAnchor.constraint(equalToConstant: 30),
            chromeControls.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -8),
            chromeControls.centerYAnchor.constraint(equalTo: chrome.centerYAnchor),
            compatibilityLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            commandPaletteButton.widthAnchor.constraint(equalToConstant: 32),
            commandPaletteButton.heightAnchor.constraint(equalToConstant: 30),
            addButton.widthAnchor.constraint(equalToConstant: 30),
            addButton.heightAnchor.constraint(equalToConstant: 30),

            divider.leadingAnchor.constraint(equalTo: chrome.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: chrome.trailingAnchor),
            divider.bottomAnchor.constraint(equalTo: chrome.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            terminalContainer.topAnchor.constraint(equalTo: chrome.bottomAnchor),
            terminalContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            terminalContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            terminalContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            shellStartupView.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            shellStartupView.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            shellStartupView.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            shellStartupView.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            sessionWorkspaceBackdrop.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            sessionWorkspaceBackdrop.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            sessionWorkspaceBackdrop.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            sessionWorkspaceBackdrop.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor),

            textSizeHUD.centerXAnchor.constraint(equalTo: terminalContainer.centerXAnchor),
            textSizeHUD.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor, constant: -24),
            textSizeHUD.heightAnchor.constraint(equalToConstant: 38),
            textSizeHUD.widthAnchor.constraint(greaterThanOrEqualToConstant: 86),
            textSizeHUDLabel.leadingAnchor.constraint(equalTo: textSizeHUD.leadingAnchor, constant: 14),
            textSizeHUDLabel.trailingAnchor.constraint(equalTo: textSizeHUD.trailingAnchor, constant: -14),
            textSizeHUDLabel.centerYAnchor.constraint(equalTo: textSizeHUD.centerYAnchor),
        ])

        updateThemeLayers()

        connectBroker()
    }

    private func updateThemeLayers() {
        let accessibility = OuroTheme.accessibility
        chrome.state = .active
        chrome.material = accessibility.reduceTransparency || accessibility.increaseContrast
            ? .windowBackground
            : .headerView
        chrome.blendingMode = .withinWindow
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            view.layer?.backgroundColor = OuroTheme.canvas.cgColor
            chrome.layer?.backgroundColor = accessibility.reduceTransparency
                ? OuroTheme.railCanvas.cgColor
                : NSColor.clear.cgColor
            terminalContainer.layer?.backgroundColor = OuroTheme.canvas.cgColor
            shellStartupView.layer?.backgroundColor = OuroTheme.canvas.cgColor
            sessionWorkspaceBackdrop.layer?.backgroundColor = OuroTheme.canvas.cgColor
            textSizeHUD.layer?.backgroundColor = OuroTheme.railCanvas.cgColor
            textSizeHUD.layer?.borderColor = OuroTheme.border.cgColor
        }
    }

    /// Presents a headless Ouroboros run as a real work surface instead of a
    /// small popover. PTY-backed attempts never use this path; they continue to
    /// attach through `activateSessionLeaf` and the broker's exact identity.
    func presentSessionWorkspace(_ content: MCPDetailOverlayView) {
        precondition(Thread.isMainThread)
        if sessionWorkspaceContent !== content {
            sessionWorkspaceContent?.removeFromSuperview()
        }
        if sessionWorkspaceContent == nil {
            terminalContainerWasHiddenBeforeSessionWorkspace = terminalContainer.isHidden
            shellStartupWasHiddenBeforeSessionWorkspace = shellStartupView.isHidden
        }
        sessionWorkspaceContent = content
        content.removeFromSuperview()
        content.configureSessionWorkspace()
        sessionWorkspaceBackdrop.addSubview(content)
        let fillAvailableWidth = content.widthAnchor.constraint(
            equalTo: sessionWorkspaceBackdrop.widthAnchor,
            constant: -56
        )
        fillAvailableWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: sessionWorkspaceBackdrop.topAnchor, constant: 28),
            content.bottomAnchor.constraint(equalTo: sessionWorkspaceBackdrop.bottomAnchor, constant: -28),
            content.centerXAnchor.constraint(equalTo: sessionWorkspaceBackdrop.centerXAnchor),
            fillAvailableWidth,
            content.widthAnchor.constraint(lessThanOrEqualToConstant: 960),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: sessionWorkspaceBackdrop.leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(lessThanOrEqualTo: sessionWorkspaceBackdrop.trailingAnchor, constant: -28),
        ])
        sessionWorkspaceBackdrop.isHidden = false
        terminalContainer.isHidden = true
        shellStartupView.isHidden = true
        terminalContainer.setAccessibilityHidden(true)
        shellStartupView.setAccessibilityHidden(true)
        sessionWorkspaceBackdrop.superview?.addSubview(sessionWorkspaceBackdrop, positioned: .above, relativeTo: nil)
        sessionWorkspaceBackdrop.window?.makeFirstResponder(content)
        NSAccessibility.post(element: sessionWorkspaceBackdrop, notification: .layoutChanged)
    }

    func dismissSessionWorkspace(_ content: MCPDetailOverlayView) {
        precondition(Thread.isMainThread)
        guard sessionWorkspaceContent === content else { return }
        content.removeFromSuperview()
        sessionWorkspaceContent = nil
        sessionWorkspaceBackdrop.isHidden = true
        terminalContainer.isHidden = terminalContainerWasHiddenBeforeSessionWorkspace
        shellStartupView.isHidden = shellStartupWasHiddenBeforeSessionWorkspace
        terminalContainer.setAccessibilityHidden(false)
        shellStartupView.setAccessibilityHidden(false)
        NSAccessibility.post(element: terminalContainer, notification: .layoutChanged)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
        guard !appeared else { return }
        appeared = true
        showTab(at: selectedIndex)
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        // PTYs are broker-owned. Window/app teardown only closes the UDS client;
        // it must never be interpreted as an explicit terminal close.
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateResponsiveTabWidths()
        layoutTabStripDocument()
        updateAllTabsVisibility()
        scrollSelectedTabToVisible()
        updateTabOverflowCues()
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        projectSelectedWorkspaceIfNeeded()
        scheduleGhosttyResize()
        #endif
    }

    @objc func addTab(_ sender: Any?) {
        guard tabs.count < Self.maximumTabs else { return }
        let origin = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil
        let inheritedPath = origin?.path
        appendTab(
            initialCommand: nil,
            shellLaunchMode: .accountZsh,
            initialPath: inheritedPath
        )
        tabs.last?.creationFallbackTabID = origin?.id
        showTab(at: tabs.count - 1)
    }

    /// Create one real broker PTY and recursively split the focused leaf.
    /// Menu/shortcut callers intentionally enter through this method so the
    /// broker create, attachment, renderer, and workspace CAS remain one
    /// fail-closed vertical slice.
    #if OUROCODE_GHOSTTY_METAL_SURFACE
    @MainActor
    func splitFocusedPane(axis: TerminalSplitAxis) {
        if isAtPaneLimit {
            presentPaneLimitReached()
            return
        }
        guard !splitOperationInFlight,
              !additionalPaneRestoreInFlight,
              !additionalPaneTeardownInFlight,
              brokerReady,
              tabs.indices.contains(selectedIndex),
              terminalContainer.bounds.width > 32,
              terminalContainer.bounds.height > 32 else { return }
        let tab = tabs[selectedIndex]
        guard let workspace = tab.workspaceTab,
              let primaryAttachment = tab.attachment,
              let brokerGeneration,
              workspace.paneCount < TerminalSplitLayoutConfiguration.maximumProductionLeaves,
              additionalPaneRuntimes.count == workspace.paneCount - 1,
              (try? workspace.canSplitFocused()) == true else { return }
        splitOperationInFlight = true
        let expectedRevision: UInt64
        do {
            expectedRevision = try workspace.snapshot().layoutRevision
        } catch {
            splitOperationInFlight = false
            presentError(error, in: tab)
            return
        }
        let shell = LaunchConfiguration.shell
        var environment = LaunchConfiguration.terminalEnvironment(
            shell: shell,
            accountLoginShell: LaunchConfiguration.shellOverride == nil
        )
        if LaunchConfiguration.shellOverride == nil,
           URL(fileURLWithPath: shell).lastPathComponent == "zsh",
           let applicationSupport = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first,
           let installation = try? ZshShellIntegration.install(
               inherited: environment,
               homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
               applicationSupportDirectory: applicationSupport
           ) {
            environment = installation.environment
        }
        let arguments = LaunchConfiguration.shellOverride == nil ? ["-l", "-i"] : []
        let geometry = splitCreationDimensions(axis: axis, workspace: workspace)
        let createNonce = UUID().uuidString
        broker.create(
            createNonce: createNonce,
            program: shell,
            args: arguments,
            currentDirectory: TerminalTabLaunchDirectory.resolve(
                inheritedPath: tab.path,
                fallbackPath: LaunchConfiguration.projectDirectory
            ),
            environment: environment,
            columns: geometry.columns,
            rows: geometry.rows
        ) { [weak self, weak tab] result in
            guard let self, let tab,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            switch result {
            case .success(let terminal):
                self.attachSplitTerminal(
                    terminal,
                    to: tab,
                    workspace: workspace,
                    axis: axis,
                    expectedRevision: expectedRevision,
                    brokerGeneration: brokerGeneration,
                    primaryAttachment: primaryAttachment
                )
            case .failure(let error):
                self.splitOperationInFlight = false
                self.presentError(error, in: tab)
            }
        }
    }
    #endif

    @objc func splitPaneRight(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        splitFocusedPane(axis: .leftRight)
        #else
        NSSound.beep()
        #endif
    }

    @objc func splitPaneDown(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        splitFocusedPane(axis: .topBottom)
        #else
        NSSound.beep()
        #endif
    }

    @objc func closeFocusedPane(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard !splitOperationInFlight,
              !additionalPaneRestoreInFlight,
              !additionalPaneTeardownInFlight,
              tabs.indices.contains(selectedIndex) else { return }
        let tab = tabs[selectedIndex]
        guard let workspace = tab.workspaceTab,
              let snapshot = try? workspace.snapshot(),
              snapshot.leaves.count > 1
        else { NSSound.beep(); return }
        if snapshot.focusedTerminalID == tab.brokerTerminalID {
            promoteSurvivorAndClosePrimary(
                tab: tab,
                workspace: workspace,
                snapshot: snapshot
            )
            return
        }
        let removedTerminalID = snapshot.focusedTerminalID
        guard let runtime = additionalPaneRuntimes[removedTerminalID] else {
            NSSound.beep()
            return
        }
        splitOperationInFlight = true
        do {
            let nextFocus = try workspace.closePane(
                terminalID: snapshot.focusedTerminalID,
                expectedRevision: snapshot.layoutRevision
            )
            workspacePaneContainers.removeValue(forKey: runtime.terminalID)
            additionalPaneRuntimes.removeValue(forKey: runtime.terminalID)
            terminalFontSizes.removeValue(forKey: runtime.terminalID)
            if additionalPaneRuntimes.isEmpty {
                additionalPaneOwnerTab = nil
                restoreSingleSurfaceProjectionIfNeeded(tab: tab, reactivateInput: false)
            } else {
                projectSelectedWorkspaceIfNeeded()
            }
            runtime.detach(broker: broker) { [weak self, weak tab] result in
                guard let self, let tab else { return }
                switch result {
                case .failure(let error):
                    self.splitOperationInFlight = false
                    runtime.invalidate()
                    self.broker.reconnectAfterAuthorityFailure(error)
                    self.presentError(error, in: tab)
                    self.activateWorkspacePane(nextFocus, tab: tab, workspace: workspace)
                    self.scheduleGhosttyResize()
                case .success:
                    guard let postCloseSnapshot = try? workspace.snapshot() else {
                        self.splitOperationInFlight = false
                        self.inputLocked = true
                        self.presentError(
                            TerminalWorkspaceTabError.layoutIdentityMismatch,
                            in: tab
                        )
                        return
                    }
                    let survivors = Set(postCloseSnapshot.leaves.map(\.terminalID))
                    guard let terminationTarget = TerminalPaneTerminationPolicy.terminationTarget(
                        removedTerminalID: removedTerminalID,
                        survivingTerminalIDs: survivors,
                        detachReceiptReceived: true,
                        layoutRemovalCommitted: !survivors.contains(removedTerminalID)
                    ) else {
                        self.splitOperationInFlight = false
                        self.inputLocked = true
                        self.presentError(BrokerClientError.staleAttachment, in: tab)
                        return
                    }
                    self.broker.terminate(terminalID: terminationTarget) { [weak self, weak tab] terminateResult in
                        guard let self, let tab else { return }
                        self.splitOperationInFlight = false
                        if case .failure(let error) = terminateResult {
                            self.broker.reconnectAfterAuthorityFailure(error)
                            self.presentError(error, in: tab)
                        }
                        self.activateWorkspacePane(nextFocus, tab: tab, workspace: workspace)
                        self.scheduleGhosttyResize()
                    }
                }
            }
        } catch {
            splitOperationInFlight = false
            presentError(error, in: tab)
        }
        #endif
    }

    #if OUROCODE_GHOSTTY_METAL_SURFACE
    /// Close and reap the retained primary pane while promoting one survivor.
    /// The old input lease crosses its FIFO detach barrier before the layout,
    /// tab identity, or retained surface changes. The already-presented
    /// survivor is then promoted under one main-actor CAS.
    private func promoteSurvivorAndClosePrimary(
        tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab,
        snapshot: TerminalWorkspaceTabSnapshot
    ) {
        guard let oldPrimaryID = tab.brokerTerminalID,
              let oldAttachment = tab.attachment,
              let plan = TerminalPrimaryPanePromotionPolicy.plan(
                  orderedTerminalIDs: snapshot.leaves.map(\.terminalID),
                  focusedTerminalID: snapshot.focusedTerminalID,
                  primaryTerminalID: oldPrimaryID,
                  layoutRevision: snapshot.layoutRevision
              ) else { NSSound.beep(); return }
        let promotedID = plan.promotedTerminalID
        guard let runtime = additionalPaneRuntimes[promotedID],
              let runtimeAttachment = runtime.attachment else {
            NSSound.beep()
            return
        }
        let currentToken: PaneProjectionToken
        do {
            currentToken = try workspace.projectionToken(
                for: promotedID,
                attachment: runtimeAttachment,
                surfaceInstanceID: runtime.surfaceInstanceID,
                runtimeGeneration: runtime.runtimeGeneration
            )
            try runtime.bindProjectionToken(currentToken)
            _ = try runtime.preparePrimaryPromotion(
                currentProjectionToken: currentToken
            )
        } catch {
            presentError(error, in: tab)
            return
        }

        splitOperationInFlight = true
        inputLocked = true
        let oldPromotedRuntime = promotedPrimaryPaneRuntime
        detachAfterInputBarrier(oldAttachment) { [weak self, weak tab, weak runtime] result in
            guard let self, let tab, let runtime else { return }
            switch result {
            case .failure(let error):
                self.splitOperationInFlight = false
                self.inputLocked = true
                self.broker.reconnectAfterAuthorityFailure(error)
                self.presentError(error, in: tab)
            case .success:
                let currentRevision = (try? workspace.snapshot().layoutRevision)
                    ?? UInt64.max
                guard self.tabs.indices.contains(self.selectedIndex),
                      self.tabs[self.selectedIndex] === tab,
                      self.desiredMirrorTab === tab,
                      self.additionalPaneRuntimes[promotedID] === runtime,
                      let currentRuntimeAttachment = runtime.attachment,
                      TerminalPrimaryPanePromotionPolicy.acceptsDetachedCommit(
                          plan,
                          currentPrimaryTerminalID: tab.brokerTerminalID,
                          currentLayoutRevision: currentRevision,
                          oldAttachmentMatches: Self.sameInputAuthority(
                              tab.attachment,
                              oldAttachment
                          ),
                          promotedAttachmentMatches: Self.sameInputAuthority(
                              currentRuntimeAttachment,
                              runtimeAttachment
                          ),
                          detachReceiptReceived: true
                      )
                else {
                    if Self.sameInputAuthority(tab.attachment, oldAttachment) {
                        tab.attachment = nil
                    }
                    self.splitOperationInFlight = false
                    self.inputLocked = true
                    self.advanceMirrorSwitch()
                    return
                }
                do {
                    let nextFocus = try workspace.closePane(
                        terminalID: oldPrimaryID,
                        expectedRevision: snapshot.layoutRevision
                    )
                    guard nextFocus == promotedID else {
                        throw TerminalWorkspaceTabError.layoutIdentityMismatch
                    }
                    try runtime.commitPrimaryPromotion(
                        currentProjectionToken: currentToken,
                        attachment: runtimeAttachment
                    )

                    if let oldPromotedRuntime {
                        do {
                            try oldPromotedRuntime.invalidateAfterExternalPrimaryDetach(
                                oldAttachment
                            )
                        } catch {
                            // The exact old lease already crossed the broker
                            // detach receipt. Local invalidation is safe and
                            // must not abort publication of the verified
                            // survivor after the layout CAS.
                            oldPromotedRuntime.invalidate()
                        }
                    } else {
                        self.surfaceCoordinator?.revokeInputLocally()
                        self.surfaceCoordinator?.setAccessibilityVisible(false)
                        self.surfaceCoordinator?.view.isHidden = true
                    }
                    self.workspacePaneContainers.removeValue(forKey: oldPrimaryID)?
                        .removeFromSuperview()
                    self.additionalPaneRuntimes.removeValue(forKey: promotedID)
                    self.promotedPrimaryPaneRuntime = runtime
                    self.surfaceCoordinator = runtime.coordinator
                    self.additionalPaneOwnerTab = self.additionalPaneRuntimes.isEmpty ? nil : tab

                    tab.attachment = runtimeAttachment
                    tab.brokerTerminalID = promotedID
                    tab.cursor = max(tab.cursor, runtimeAttachment.terminal.stateSequence)
                    tab.layoutEpoch = runtimeAttachment.terminal.layoutEpoch
                    tab.running = runtimeAttachment.terminal.running
                    tab.foregroundProcess = runtimeAttachment.terminal.foregroundProcess
                    self.mirrorTab = tab
                    self.focusedTypographyTerminalID = promotedID
                    self.semanticPromptReadiness.recordDirectActivation(
                        tabID: tab.id,
                        generation: self.transitionGeneration
                    )
                    runtime.onFailure = { [weak self, weak runtime] error in
                        guard let self, let runtime,
                              self.promotedPrimaryPaneRuntime === runtime else { return }
                        self.inputLocked = true
                        runtime.coordinator.setAccessibilityVisible(false)
                        self.broker.reconnectAfterAuthorityFailure(error)
                    }
                    runtime.onInputFailure = { [weak self, weak runtime] error in
                        guard let self, let runtime,
                              self.promotedPrimaryPaneRuntime === runtime else { return }
                        self.inputLocked = true
                        self.broker.reconnectAfterAuthorityFailure(error)
                    }

                    guard let postCloseSnapshot = try? workspace.snapshot() else {
                        self.splitOperationInFlight = false
                        self.inputLocked = true
                        self.presentError(
                            TerminalWorkspaceTabError.layoutIdentityMismatch,
                            in: tab
                        )
                        return
                    }
                    let survivors = Set(postCloseSnapshot.leaves.map(\.terminalID))
                    guard let terminationTarget = TerminalPaneTerminationPolicy.terminationTarget(
                        removedTerminalID: oldPrimaryID,
                        survivingTerminalIDs: survivors,
                        detachReceiptReceived: true,
                        layoutRemovalCommitted: !survivors.contains(oldPrimaryID)
                    ), terminationTarget != tab.brokerTerminalID else {
                        self.splitOperationInFlight = false
                        self.inputLocked = true
                        self.presentError(BrokerClientError.staleAttachment, in: tab)
                        return
                    }
                    self.broker.terminate(terminalID: terminationTarget) {
                        [weak self, weak runtime, weak tab] terminationResult in
                        guard let self, let runtime, let tab,
                              self.promotedPrimaryPaneRuntime === runtime,
                              self.tabs.contains(where: { $0 === tab }),
                              tab.brokerTerminalID == promotedID
                        else { return }
                        self.splitOperationInFlight = false
                        if case .failure(let error) = terminationResult {
                            self.broker.reconnectAfterAuthorityFailure(error)
                            self.presentError(error, in: tab)
                        }
                        if self.additionalPaneRuntimes.isEmpty {
                            self.restoreSingleSurfaceProjectionIfNeeded(
                                tab: tab,
                                reactivateInput: false
                            )
                        } else {
                            self.projectSelectedWorkspaceIfNeeded()
                        }
                        runtime.present(
                            focused: true,
                            broker: self.broker,
                            presentationGeneration: workspace.projectionGeneration
                        ) { [weak self, weak runtime, weak tab] activation in
                            guard let self, let runtime, let tab,
                                  self.promotedPrimaryPaneRuntime === runtime,
                                  self.tabs.indices.contains(self.selectedIndex),
                                  self.tabs[self.selectedIndex] === tab,
                                  Self.sameInputAuthority(tab.attachment, runtimeAttachment)
                            else { return }
                            switch activation {
                            case .success:
                                self.inputLocked = false
                                if self.additionalPaneRuntimes.isEmpty {
                                    runtime.coordinator.install(in: self.terminalContainer)
                                    runtime.coordinator.view.isHidden = false
                                    runtime.coordinator.setAccessibilityVisible(true)
                                } else {
                                    self.projectSelectedWorkspaceIfNeeded()
                                }
                                self.view.window?.makeFirstResponder(runtime.coordinator.view)
                                self.scheduleGhosttyResize()
                            case .failure(let error):
                                self.inputLocked = true
                                self.broker.reconnectAfterAuthorityFailure(error)
                                self.presentError(error, in: tab)
                            }
                        }
                    }
                } catch {
                    // The old attachment is known detached. Never resurrect a
                    // stale lease or partially publish the survivor.
                    if Self.sameInputAuthority(tab.attachment, oldAttachment) {
                        tab.attachment = nil
                    }
                    self.splitOperationInFlight = false
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                    self.presentError(error, in: tab)
                }
            }
        }
    }
    #endif

    @objc func focusPaneLeft(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        moveFocusedPane(.left)
        #else
        NSSound.beep()
        #endif
    }
    @objc func focusPaneRight(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        moveFocusedPane(.right)
        #else
        NSSound.beep()
        #endif
    }
    @objc func focusPaneUp(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        moveFocusedPane(.up)
        #else
        NSSound.beep()
        #endif
    }
    @objc func focusPaneDown(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        moveFocusedPane(.down)
        #else
        NSSound.beep()
        #endif
    }

    @objc func equalizePanes(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard !splitOperationInFlight,
              tabs.indices.contains(selectedIndex),
              let workspace = tabs[selectedIndex].workspaceTab,
              let snapshot = try? workspace.snapshot(),
              snapshot.leaves.count > 1 else { return }
        do {
            _ = try workspace.equalize(expectedRevision: snapshot.layoutRevision)
            projectSelectedWorkspaceIfNeeded()
            scheduleGhosttyResize()
        } catch {
            presentError(error, in: tabs[selectedIndex])
        }
        #endif
    }

    @objc func toggleMaximizeFocusedPane(_ sender: Any?) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard !splitOperationInFlight,
              tabs.indices.contains(selectedIndex),
              let workspace = tabs[selectedIndex].workspaceTab,
              let snapshot = try? workspace.snapshot(),
              snapshot.leaves.count > 1 else { return }
        do {
            try workspace.toggleMaximizeFocused(expectedRevision: snapshot.layoutRevision)
            projectSelectedWorkspaceIfNeeded()
            scheduleGhosttyResize()
        } catch {
            presentError(error, in: tabs[selectedIndex])
        }
        #endif
    }

    var canSplitFocusedPane: Bool {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        let hasSelectedTab = tabs.indices.contains(selectedIndex)
        let workspace = hasSelectedTab ? tabs[selectedIndex].workspaceTab : nil
        let allowed = !splitOperationInFlight
            && !inputLocked
            && brokerReady
            && hasSelectedTab
            && terminalContainer.bounds.width > 32
            && terminalContainer.bounds.height > 32
            && (workspace.map { (try? $0.canSplitFocused()) == true } ?? false)
            && (workspace.map { additionalPaneRuntimes.count == $0.paneCount - 1 } ?? false)
        TerminalPaneRuntimeTrace.record(
            "can-split.evaluate",
            "allowed=\(allowed) operation=\(splitOperationInFlight) inputLocked=\(inputLocked) "
                + "broker=\(brokerReady) selected=\(hasSelectedTab) "
                + "bounds=\(Int(terminalContainer.bounds.width))x\(Int(terminalContainer.bounds.height)) "
                + "workspace=\(workspace != nil) panes=\(workspace?.paneCount ?? 0) "
                + "additional=\(additionalPaneRuntimes.count)"
        )
        return allowed
        #else
        return false
        #endif
    }

    private var isAtPaneLimit: Bool {
        currentPaneCount >= TerminalPaneLimitFeedbackPolicy.maximumPaneCount
    }

    private var currentPaneCount: Int {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard tabs.indices.contains(selectedIndex),
              let workspace = tabs[selectedIndex].workspaceTab else { return 0 }
        return workspace.paneCount
        #else
        return 0
        #endif
    }

    private func presentPaneLimitReached() {
        let message = TerminalPaneLimitFeedbackPolicy.message
        presentTerminalHUD(
            text: message,
            announcement: message,
            priority: .high
        )
        NSSound.beep()
    }

    var canMoveFocus: Bool {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard !splitOperationInFlight, !inputLocked,
              tabs.indices.contains(selectedIndex),
              let workspace = tabs[selectedIndex].workspaceTab else { return false }
        return workspace.paneCount > 1
        #else
        return false
        #endif
    }

    var canCloseFocusedPane: Bool {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard canMoveFocus,
              let tab = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : nil,
              let workspace = tab.workspaceTab,
              let snapshot = try? workspace.snapshot() else { return false }
        if snapshot.focusedTerminalID == tab.brokerTerminalID {
            guard additionalPaneRuntimes.count == snapshot.leaves.count - 1 else {
                return false
            }
            return snapshot.leaves.contains {
                $0.terminalID != tab.brokerTerminalID
                    && additionalPaneRuntimes[$0.terminalID] != nil
            }
        }
        return additionalPaneRuntimes[snapshot.focusedTerminalID] != nil
        #else
        return false
        #endif
    }

    var canEqualizePanes: Bool { canMoveFocus }
    var canMaximizeFocusedPane: Bool { canMoveFocus }

    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private func splitCreationDimensions(
        axis: TerminalSplitAxis,
        workspace: TerminalWorkspaceTab
    ) -> (columns: Int, rows: Int) {
        let inset = OuroTheme.terminalContentInset * 2
        let focused = (try? workspace.snapshot()).flatMap { snapshot in
            snapshot.leaves.first(where: { $0.terminalID == snapshot.focusedTerminalID })
        }
        let scale: CGFloat = 1_000_000
        var width = max(
            1,
            terminalContainer.bounds.width * CGFloat(focused?.width ?? 1_000_000) / scale - inset
        )
        var height = max(
            1,
            terminalContainer.bounds.height * CGFloat(focused?.height ?? 1_000_000) / scale - inset
        )
        switch axis {
        case .leftRight: width *= 0.5
        case .topBottom: height *= 0.5
        }
        return (
            columns: max(2, Int(width / OuroTheme.terminalCellSize.width)),
            rows: max(2, Int(height / OuroTheme.terminalCellSize.height))
        )
    }

    private func moveFocusedPane(_ direction: TerminalSplitFocusDirection) {
        guard !splitOperationInFlight,
              tabs.indices.contains(selectedIndex) else { return }
        let tab = tabs[selectedIndex]
        guard let workspace = tab.workspaceTab,
              let snapshot = try? workspace.snapshot(),
              snapshot.leaves.count > 1 else { return }
        do {
            let change = try workspace.moveFocus(
                direction,
                expectedRevision: snapshot.layoutRevision
            )
            guard change.moved else { NSSound.beep(); return }
            focusedTypographyTerminalID = change.focusedTerminalID
            projectSelectedWorkspaceIfNeeded()
            activateWorkspacePane(change.focusedTerminalID, tab: tab, workspace: workspace)
        } catch {
            presentError(error, in: tab)
        }
    }

    private func synchronizeWorkspaceFocus(
        _ terminalID: String,
        tab: LocalTerminalTab
    ) {
        guard tabs.indices.contains(selectedIndex), tabs[selectedIndex] === tab,
              let workspace = tab.workspaceTab,
              let snapshot = try? workspace.snapshot(),
              snapshot.focusedTerminalID != terminalID else { return }
        do {
            try workspace.focus(
                terminalID: terminalID,
                expectedRevision: snapshot.layoutRevision
            )
            focusedTypographyTerminalID = terminalID
            projectSelectedWorkspaceIfNeeded()
            activateWorkspacePane(terminalID, tab: tab, workspace: workspace)
        } catch {
            presentError(error, in: tab)
        }
    }

    private func activateWorkspacePane(
        _ terminalID: String,
        tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab
    ) {
        guard desiredMirrorTab === tab, !splitOperationInFlight else { return }
        publishFocusedSessionPane()
        inputLocked = true
        for (candidateID, runtime) in additionalPaneRuntimes where candidateID != terminalID {
            runtime.revokeInput()
        }
        if terminalID == tab.brokerTerminalID,
           let surfaceCoordinator,
           let attachment = tab.attachment {
            surfaceCoordinator.activateInput(broker: broker, attachment: attachment) {
                [weak self, weak surfaceCoordinator] result in
                guard let self, let surfaceCoordinator else { return }
                switch result {
                case .success:
                    do {
                        try surfaceCoordinator.openInputAfterActivation(attachment: attachment)
                        self.inputLocked = false
                        self.view.window?.makeFirstResponder(surfaceCoordinator.view)
                    } catch { self.presentError(error, in: tab) }
                case .failure(let error): self.presentError(error, in: tab)
                }
            }
        } else if let runtime = additionalPaneRuntimes[terminalID] {
            surfaceCoordinator?.revokeInputLocally()
            runtime.present(
                focused: true,
                broker: broker,
                presentationGeneration: workspace.projectionGeneration
            ) { [weak self, weak runtime] result in
                guard let self, let runtime else { return }
                switch result {
                case .success:
                    self.inputLocked = false
                    self.view.window?.makeFirstResponder(runtime.coordinator.view)
                case .failure(let error): self.presentError(error, in: tab)
                }
            }
        }
    }

    private func attachSplitTerminal(
        _ terminal: BrokerTerminalSummary,
        to tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab,
        axis: TerminalSplitAxis,
        expectedRevision: UInt64,
        brokerGeneration: UInt64,
        primaryAttachment: BrokerAttachment
    ) {
        guard desiredMirrorTab === tab,
              tabs.indices.contains(selectedIndex),
              tabs[selectedIndex] === tab,
              Self.sameInputAuthority(tab.attachment, primaryAttachment),
              (try? workspace.snapshot().layoutRevision) == expectedRevision else {
            rollbackUnprojectedSplitTerminal(
                terminalID: terminal.id,
                runtime: nil,
                tab: tab,
                error: TerminalWorkspaceTabError.staleLayoutRevision(
                    expected: expectedRevision,
                    actual: (try? workspace.snapshot().layoutRevision) ?? expectedRevision
                )
            )
            return
        }
        terminalFontSizes[terminal.id] = terminalFontSizes[primaryAttachment.terminal.id]
            ?? OuroTheme.terminalFontSize
        broker.prepareAttachment(terminalID: terminal.id) { [weak self, weak tab] result in
            guard let self, let tab else { return }
            switch result {
            case .failure(let error):
                self.rollbackUnprojectedSplitTerminal(
                    terminalID: terminal.id,
                    runtime: nil,
                    tab: tab,
                    error: error
                )
            case .success(let prepared):
                let runtime: TerminalPaneRuntime
                do {
                    runtime = try TerminalPaneRuntime(
                        brokerGeneration: brokerGeneration,
                        prepared: prepared,
                        backingScale: self.view.window?.backingScaleFactor
                            ?? NSScreen.main?.backingScaleFactor
                            ?? 2,
                        fontPointSize: self.terminalFontSizes[terminal.id]
                            ?? OuroTheme.terminalFontSize,
                        onFocusChange: { [weak self, weak tab] focused in
                            guard focused, let self, let tab,
                                  self.tabs.indices.contains(self.selectedIndex),
                                  self.tabs[self.selectedIndex] === tab else { return }
                            self.focusedTypographyTerminalID = terminal.id
                            self.synchronizeWorkspaceFocus(terminal.id, tab: tab)
                        }
                    )
                } catch {
                    self.broker.abortRecovery(
                        prepared,
                        reason: "Split pane renderer allocation failed before broker commit."
                    )
                    self.rollbackUnprojectedSplitTerminal(
                        terminalID: terminal.id,
                        runtime: nil,
                        tab: tab,
                        error: error
                    )
                    return
                }
                // The transparent staging surface is in a real window so its
                // first drawable can settle before the workspace CAS exposes
                // the leaf. It has no AX or input authority while staged.
                runtime.container.translatesAutoresizingMaskIntoConstraints = true
                runtime.container.frame = self.terminalContainer.bounds
                runtime.container.autoresizingMask = [.width, .height]
                // An exactly transparent MTKView can be excluded from AppKit
                // presentation, preventing the renderer's first-present fence
                // from ever settling. Keep the staged drawable technically
                // composited while AX and input remain explicitly disabled.
                runtime.container.alphaValue = 0.01
                self.terminalContainer.addSubview(runtime.container)
                self.stagedPaneRuntime = runtime
                self.terminalContainer.layoutSubtreeIfNeeded()
                runtime.container.layoutSubtreeIfNeeded()
                TerminalPaneRuntimeTrace.record(
                    "host.staged",
                    runtime.coordinator.presentationReadinessDescription
                )
                runtime.onFailure = { [weak self, weak runtime] error in
                    guard let self, let runtime else { return }
                    if self.additionalPaneRuntimes[terminal.id] === runtime {
                        self.rollbackProjectedSplitTerminal(
                            terminalID: terminal.id,
                            runtime: runtime,
                            tab: tab,
                            workspace: workspace,
                            error: error
                        )
                    } else {
                        self.rollbackUnprojectedSplitTerminal(
                            terminalID: terminal.id,
                            runtime: runtime,
                            tab: tab,
                            error: error
                        )
                    }
                }
                runtime.onInputFailure = { [weak self] error in
                    self?.broker.reconnectAfterAuthorityFailure(error)
                }
                DispatchQueue.main.async { [weak self, weak tab, weak runtime] in
                    guard let self, let tab, let runtime else { return }
                    self.terminalContainer.layoutSubtreeIfNeeded()
                    runtime.container.layoutSubtreeIfNeeded()
                    TerminalPaneRuntimeTrace.record(
                        "host.staged.next-turn",
                        runtime.coordinator.presentationReadinessDescription
                    )
                    runtime.attach(
                        broker: self.broker,
                        brokerGeneration: brokerGeneration,
                        prepared: prepared,
                        presentationGeneration: workspace.projectionGeneration &+ 1
                    ) { [weak self, weak tab, weak runtime] attachResult in
                        guard let self, let tab, let runtime else { return }
                        switch attachResult {
                        case .failure(let error):
                            self.rollbackUnprojectedSplitTerminal(
                                terminalID: terminal.id,
                                runtime: runtime,
                                tab: tab,
                                error: error
                            )
                        case .success:
                            self.commitSplitProjection(
                                runtime,
                                terminal: terminal,
                                tab: tab,
                                workspace: workspace,
                                axis: axis,
                                expectedRevision: expectedRevision,
                                primaryAttachment: primaryAttachment
                            )
                        }
                    }
                }
            }
        }
    }

    private func commitSplitProjection(
        _ runtime: TerminalPaneRuntime,
        terminal: BrokerTerminalSummary,
        tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab,
        axis: TerminalSplitAxis,
        expectedRevision: UInt64,
        primaryAttachment: BrokerAttachment
    ) {
        broker.list { [weak self, weak tab, weak runtime] result in
            guard let self, let tab, let runtime else { return }
            guard self.desiredMirrorTab === tab,
                  self.tabs.indices.contains(self.selectedIndex),
                  self.tabs[self.selectedIndex] === tab,
                  Self.sameInputAuthority(tab.attachment, primaryAttachment),
                  let attachment = runtime.attachment else {
                self.rollbackUnprojectedSplitTerminal(
                    terminalID: terminal.id,
                    runtime: runtime,
                    tab: tab,
                    error: BrokerClientError.staleAttachment
                )
                return
            }
            switch result {
            case .failure(let error):
                self.rollbackUnprojectedSplitTerminal(
                    terminalID: terminal.id,
                    runtime: runtime,
                    tab: tab,
                    error: error
                )
            case .success(let terminals):
                let authoritativeIDs = Set(terminals.map(\.id))
                guard authoritativeIDs.contains(terminal.id),
                      tab.brokerTerminalID.map(authoritativeIDs.contains) == true else {
                    self.rollbackUnprojectedSplitTerminal(
                        terminalID: terminal.id,
                        runtime: runtime,
                        tab: tab,
                        error: TerminalWorkspaceTabError.unauthorizedTerminalID(terminal.id)
                    )
                    return
                }
                do {
                    _ = try workspace.splitFocused(
                        axis: axis,
                        newTerminalID: terminal.id,
                        expectedRevision: expectedRevision,
                        authoritativeTerminalIDs: authoritativeIDs
                    )
                    let snapshot = try workspace.snapshot()
                    let token = try workspace.projectionToken(
                        for: terminal.id,
                        attachment: attachment,
                        surfaceInstanceID: runtime.surfaceInstanceID,
                        runtimeGeneration: runtime.runtimeGeneration
                    )
                    try runtime.bindProjectionToken(token)
                    guard snapshot.layoutRevision == expectedRevision &+ 1,
                          snapshot.focusedTerminalID == terminal.id,
                          snapshot.leaves.count == workspace.paneCount,
                          snapshot.leaves.count
                            <= TerminalSplitLayoutConfiguration.maximumProductionLeaves,
                          snapshot.leaves.contains(where: {
                              $0.terminalID == primaryAttachment.terminal.id
                          }),
                          snapshot.leaves.allSatisfy({
                              authoritativeIDs.contains($0.terminalID)
                          }) else {
                        throw TerminalWorkspaceTabError.layoutIdentityMismatch
                    }
                    self.additionalPaneRuntimes[terminal.id] = runtime
                    if self.stagedPaneRuntime === runtime {
                        self.stagedPaneRuntime = nil
                    }
                    self.additionalPaneOwnerTab = tab
                    self.focusedTypographyTerminalID = terminal.id
                    runtime.container.alphaValue = 1
                    self.projectSelectedWorkspaceIfNeeded()
                    self.presentFocusedSplitRuntime(
                        tab: tab,
                        runtime: runtime,
                        workspace: workspace
                    )
                } catch {
                    self.rollbackProjectedSplitTerminal(
                        terminalID: terminal.id,
                        runtime: runtime,
                        tab: tab,
                        workspace: workspace,
                        error: error
                    )
                }
            }
        }
    }

    private func presentFocusedSplitRuntime(
        tab: LocalTerminalTab,
        runtime: TerminalPaneRuntime,
        workspace: TerminalWorkspaceTab
    ) {
        inputLocked = true
        runtime.present(
            focused: true,
            broker: broker,
            presentationGeneration: workspace.projectionGeneration
        ) { [weak self, weak runtime] presentationResult in
            guard let self, let runtime else { return }
            switch presentationResult {
            case .success:
                self.splitOperationInFlight = false
                self.inputLocked = false
                self.scheduleGhosttyResize()
                self.view.window?.makeFirstResponder(runtime.coordinator.view)
            case .failure(let error):
                self.rollbackProjectedSplitTerminal(
                    terminalID: runtime.terminalID,
                    runtime: runtime,
                    tab: tab,
                    workspace: workspace,
                    error: error
                )
            }
        }
    }

    private func rollbackProjectedSplitTerminal(
        terminalID: String,
        runtime: TerminalPaneRuntime,
        tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab,
        error: Error
    ) {
        if let snapshot = try? workspace.snapshot(),
           snapshot.leaves.contains(where: { $0.terminalID == terminalID }) {
            _ = try? workspace.closePane(
                terminalID: terminalID,
                expectedRevision: snapshot.layoutRevision
            )
        }
        rollbackUnprojectedSplitTerminal(
            terminalID: terminalID,
            runtime: runtime,
            tab: tab,
            error: error
        )
        restoreSingleSurfaceProjectionIfNeeded(tab: tab)
    }

    private func rollbackUnprojectedSplitTerminal(
        terminalID: String,
        runtime: TerminalPaneRuntime?,
        tab: LocalTerminalTab,
        error: Error
    ) {
        guard splitOperationInFlight || additionalPaneRuntimes[terminalID] != nil else { return }
        splitOperationInFlight = false
        terminalFontSizes.removeValue(forKey: terminalID)
        if stagedPaneRuntime === runtime || stagedPaneRuntime?.terminalID == terminalID {
            stagedPaneRuntime = nil
        }
        additionalPaneRuntimes.removeValue(forKey: terminalID)
        let finish: () -> Void = { [weak self, weak tab] in
            guard let self else { return }
            self.broker.terminate(terminalID: terminalID) { _ in }
            if let tab { self.presentError(error, in: tab) }
        }
        guard let runtime, let attachment = runtime.attachment else {
            runtime?.invalidate()
            finish()
            return
        }
        runtime.coordinator.deactivateInputBeforeDetach(attachment: attachment) {
            [weak self, weak runtime] barrierResult in
            guard let self else { return }
            switch barrierResult {
            case .success:
                self.broker.detach(attachment) { _ in
                    runtime?.invalidate()
                    finish()
                }
            case .failure(let barrierError):
                runtime?.invalidate()
                self.broker.reconnectAfterAuthorityFailure(barrierError)
                finish()
            }
        }
    }

    private func projectSelectedWorkspaceIfNeeded() {
        guard !additionalPaneRuntimes.isEmpty,
              tabs.indices.contains(selectedIndex),
              additionalPaneOwnerTab === tabs[selectedIndex],
              let workspace = tabs[selectedIndex].workspaceTab,
              let primaryID = tabs[selectedIndex].brokerTerminalID,
              let primarySurface = surfaceCoordinator,
              let snapshot = try? workspace.snapshot() else { return }
        let primaryContainer: NSView
        if let existing = workspacePaneContainers[primaryID] {
            primaryContainer = existing
        } else {
            primaryContainer = NSView(frame: .zero)
            primaryContainer.wantsLayer = true
            primaryContainer.layer?.backgroundColor = OuroTheme.canvas.cgColor
            workspacePaneContainers[primaryID] = primaryContainer
            terminalContainer.addSubview(primaryContainer)
            primarySurface.install(in: primaryContainer)
        }
        for runtime in additionalPaneRuntimes.values {
            workspacePaneContainers[runtime.terminalID] = runtime.container
            if runtime.container.superview !== terminalContainer {
                terminalContainer.addSubview(runtime.container)
            }
        }
        let bounds = terminalContainer.bounds
        let scale: CGFloat = 1_000_000
        let visibleTerminalIDs = Set(snapshot.presentationLeaves.map(\.terminalID))
        for (terminalID, container) in workspacePaneContainers {
            container.isHidden = !visibleTerminalIDs.contains(terminalID)
            container.setAccessibilityHidden(!visibleTerminalIDs.contains(terminalID))
        }
        for leaf in snapshot.presentationLeaves {
            guard let container = workspacePaneContainers[leaf.terminalID] else { continue }
            container.isHidden = false
            container.translatesAutoresizingMaskIntoConstraints = true
            let x = bounds.minX + bounds.width * CGFloat(leaf.x) / scale
            let width = bounds.width * CGFloat(leaf.width) / scale
            let height = bounds.height * CGFloat(leaf.height) / scale
            // Rust geometry uses top-origin y so directional Up/Down remains
            // platform neutral. Convert once at the AppKit projection edge.
            let y = bounds.minY + bounds.height
                - bounds.height * CGFloat(leaf.y + leaf.height) / scale
            container.frame = NSRect(x: x, y: y, width: width, height: height)
                .insetBy(dx: 0.5, dy: 0.5)
            container.autoresizingMask = []
        }
    }

    private func beginAdditionalPaneTeardown(owner: LocalTerminalTab) {
        guard !additionalPaneTeardownInFlight else { return }
        additionalPaneTeardownInFlight = true
        additionalPaneRestoreInFlight = false
        let runtimes = Array(additionalPaneRuntimes.values)
        guard !runtimes.isEmpty else {
            finishAdditionalPaneTeardown(owner: owner)
            return
        }
        var remaining = runtimes.count
        for runtime in runtimes {
            runtime.detach(broker: broker) { [weak self, weak runtime] result in
                guard let self else { return }
                if case .failure(let error) = result {
                    runtime?.invalidate()
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
                self.additionalPaneRuntimes.removeValue(forKey: runtime?.terminalID ?? "")
                if let terminalID = runtime?.terminalID {
                    self.terminalFontSizes.removeValue(forKey: terminalID)
                }
                remaining -= 1
                if remaining == 0 {
                    self.finishAdditionalPaneTeardown(owner: owner)
                }
            }
        }
    }

    private func finishAdditionalPaneTeardown(owner: LocalTerminalTab) {
        additionalPaneRuntimes.removeAll(keepingCapacity: true)
        additionalPaneOwnerTab = nil
        additionalPaneTeardownInFlight = false
        restoreSingleSurfaceProjectionIfNeeded(tab: owner, reactivateInput: false)
        let target = pendingPaneSwitchTab
        pendingPaneSwitchTab = nil
        if let target { requestMirrorSwitch(to: target) }
    }

    private func restoreAdditionalPanesIfNeeded(for tab: LocalTerminalTab) {
        guard !additionalPaneRestoreInFlight,
              !additionalPaneTeardownInFlight,
              !splitOperationInFlight,
              additionalPaneRuntimes.isEmpty,
              additionalPaneOwnerTab == nil,
              desiredMirrorTab === tab,
              mirrorTab === tab,
              let workspace = tab.workspaceTab,
              let primaryID = tab.brokerTerminalID,
              let snapshot = try? workspace.snapshot(),
              snapshot.leaves.count > 1 else { return }
        additionalPaneRestoreInFlight = true
        broker.list { [weak self, weak tab] result in
            guard let self, let tab else { return }
            guard self.desiredMirrorTab === tab,
                  let current = try? workspace.snapshot(),
                  current.layoutRevision == snapshot.layoutRevision else {
                self.additionalPaneRestoreInFlight = false
                return
            }
            switch result {
            case .failure(let error):
                self.additionalPaneRestoreInFlight = false
                self.presentError(error, in: tab)
            case .success(let terminals):
                let byID = Dictionary(uniqueKeysWithValues: terminals.map { ($0.id, $0) })
                guard byID[primaryID] != nil else {
                    self.additionalPaneRestoreInFlight = false
                    self.presentError(BrokerClientError.staleAttachment, in: tab)
                    return
                }
                // Broker identity is authoritative. Missing leaves collapse;
                // they are never replaced by a newly-created shell.
                for leaf in current.leaves where leaf.terminalID != primaryID && byID[leaf.terminalID] == nil {
                    if let revision = try? workspace.snapshot().layoutRevision {
                        _ = try? workspace.closePane(
                            terminalID: leaf.terminalID,
                            expectedRevision: revision
                        )
                    }
                }
                guard let repaired = try? workspace.snapshot() else {
                    self.additionalPaneRestoreInFlight = false
                    return
                }
                let ordered = repaired.leaves.compactMap { leaf -> BrokerTerminalSummary? in
                    guard leaf.terminalID != primaryID else { return nil }
                    return byID[leaf.terminalID]
                }
                self.restoreAdditionalPane(
                    at: 0,
                    terminals: ordered,
                    tab: tab,
                    workspace: workspace,
                    expectedRevision: repaired.layoutRevision,
                    focusedTerminalID: repaired.focusedTerminalID
                )
            }
        }
    }

    private func restoreAdditionalPane(
        at index: Int,
        terminals: [BrokerTerminalSummary],
        tab: LocalTerminalTab,
        workspace: TerminalWorkspaceTab,
        expectedRevision: UInt64,
        focusedTerminalID: String
    ) {
        guard desiredMirrorTab === tab,
              let brokerGeneration,
              let current = try? workspace.snapshot(),
              current.layoutRevision == expectedRevision else {
            additionalPaneRestoreInFlight = false
            return
        }
        guard terminals.indices.contains(index) else {
            additionalPaneRestoreInFlight = false
            additionalPaneOwnerTab = additionalPaneRuntimes.isEmpty ? nil : tab
            projectSelectedWorkspaceIfNeeded()
            scheduleGhosttyResize()
            if let focused = additionalPaneRuntimes[focusedTerminalID] {
                focused.present(
                    focused: true,
                    broker: broker,
                    presentationGeneration: workspace.projectionGeneration
                ) { [weak self, weak focused] result in
                    guard let self, let focused else { return }
                    if case .success = result {
                        self.view.window?.makeFirstResponder(focused.coordinator.view)
                    }
                }
            }
            return
        }
        let terminal = terminals[index]
        broker.prepareAttachment(terminalID: terminal.id) { [weak self, weak tab] result in
            guard let self, let tab else { return }
            switch result {
            case .failure:
                self.dropUnrestorablePane(
                    terminalID: terminal.id,
                    runtime: nil,
                    workspace: workspace
                )
                self.restoreAdditionalPane(
                    at: index + 1,
                    terminals: terminals,
                    tab: tab,
                    workspace: workspace,
                    expectedRevision: (try? workspace.snapshot().layoutRevision) ?? expectedRevision,
                    focusedTerminalID: focusedTerminalID
                )
            case .success(let prepared):
                let runtime: TerminalPaneRuntime
                do {
                    runtime = try TerminalPaneRuntime(
                        brokerGeneration: brokerGeneration,
                        prepared: prepared,
                        backingScale: self.view.window?.backingScaleFactor
                            ?? NSScreen.main?.backingScaleFactor
                            ?? 2,
                        fontPointSize: self.terminalFontSizes[terminal.id]
                            ?? OuroTheme.terminalFontSize,
                        onFocusChange: { [weak self, weak tab] focused in
                            guard focused, let self, let tab,
                                  self.tabs.indices.contains(self.selectedIndex),
                                  self.tabs[self.selectedIndex] === tab else { return }
                            self.focusedTypographyTerminalID = terminal.id
                            self.synchronizeWorkspaceFocus(terminal.id, tab: tab)
                        }
                    )
                } catch {
                    self.broker.abortRecovery(
                        prepared,
                        reason: "Restored pane could not allocate its renderer."
                    )
                    self.dropUnrestorablePane(
                        terminalID: terminal.id,
                        runtime: nil,
                        workspace: workspace
                    )
                    self.restoreAdditionalPane(
                        at: index + 1,
                        terminals: terminals,
                        tab: tab,
                        workspace: workspace,
                        expectedRevision: (try? workspace.snapshot().layoutRevision) ?? expectedRevision,
                        focusedTerminalID: focusedTerminalID
                    )
                    return
                }
                runtime.container.translatesAutoresizingMaskIntoConstraints = true
                runtime.container.frame = self.terminalContainer.bounds
                // See the split-create staging path above. Alpha zero can
                // suppress the drawable and deadlock restore before CAS bind.
                runtime.container.alphaValue = 0.01
                self.terminalContainer.addSubview(runtime.container)
                runtime.attach(
                    broker: self.broker,
                    brokerGeneration: brokerGeneration,
                    prepared: prepared,
                    presentationGeneration: workspace.projectionGeneration
                ) { [weak self, weak tab, weak runtime] attachResult in
                    guard let self, let tab, let runtime else { return }
                    switch attachResult {
                    case .failure:
                        self.dropUnrestorablePane(
                            terminalID: terminal.id,
                            runtime: runtime,
                            workspace: workspace
                        )
                    case .success:
                        do {
                            guard let attachment = runtime.attachment,
                                  let current = try? workspace.snapshot(),
                                  current.layoutRevision == expectedRevision else {
                                throw BrokerClientError.staleAttachment
                            }
                            let token = try workspace.projectionToken(
                                for: terminal.id,
                                attachment: attachment,
                                surfaceInstanceID: runtime.surfaceInstanceID,
                                runtimeGeneration: runtime.runtimeGeneration
                            )
                            try runtime.bindProjectionToken(token)
                            self.additionalPaneRuntimes[terminal.id] = runtime
                            self.additionalPaneOwnerTab = tab
                            runtime.container.alphaValue = 1
                            runtime.present(
                                focused: false,
                                broker: self.broker,
                                presentationGeneration: workspace.projectionGeneration
                            ) { _ in }
                            self.projectSelectedWorkspaceIfNeeded()
                        } catch {
                            self.dropUnrestorablePane(
                                terminalID: terminal.id,
                                runtime: runtime,
                                workspace: workspace
                            )
                        }
                    }
                    self.restoreAdditionalPane(
                        at: index + 1,
                        terminals: terminals,
                        tab: tab,
                        workspace: workspace,
                        expectedRevision: (try? workspace.snapshot().layoutRevision) ?? expectedRevision,
                        focusedTerminalID: focusedTerminalID
                    )
                }
            }
        }
    }

    private func dropUnrestorablePane(
        terminalID: String,
        runtime: TerminalPaneRuntime?,
        workspace: TerminalWorkspaceTab
    ) {
        let collapse = {
            if let snapshot = try? workspace.snapshot(),
               snapshot.leaves.contains(where: { $0.terminalID == terminalID }) {
                _ = try? workspace.closePane(
                    terminalID: terminalID,
                    expectedRevision: snapshot.layoutRevision
                )
            }
        }
        guard let runtime else {
            collapse()
            return
        }
        runtime.detach(broker: broker) { [weak self] result in
            if case .failure(let error) = result {
                runtime.invalidate()
                self?.broker.reconnectAfterAuthorityFailure(error)
            }
        }
        additionalPaneRuntimes.removeValue(forKey: terminalID)
        collapse()
    }

    private func restoreSingleSurfaceProjectionIfNeeded(
        tab: LocalTerminalTab,
        reactivateInput: Bool = true
    ) {
        guard additionalPaneRuntimes.isEmpty,
              desiredMirrorTab === tab,
              let surfaceCoordinator else { return }
        workspacePaneContainers.values.forEach { container in
            if container !== surfaceCoordinator.view { container.removeFromSuperview() }
        }
        workspacePaneContainers.removeAll(keepingCapacity: true)
        surfaceCoordinator.install(in: terminalContainer)
        surfaceCoordinator.view.isHidden = false
        surfaceCoordinator.setAccessibilityVisible(true)
        if reactivateInput, let attachment = tab.attachment {
            surfaceCoordinator.activateInput(broker: broker, attachment: attachment) {
                [weak self, weak surfaceCoordinator] result in
                guard let self, let surfaceCoordinator else { return }
                if case .success = result {
                    try? surfaceCoordinator.openInputAfterActivation(attachment: attachment)
                    self.inputLocked = false
                }
            }
        }
    }
    #endif

    private func openCleanShell(from identity: TerminalShellStartupIdentity) {
        guard tabs.count < Self.maximumTabs,
              TerminalShellStartupPolicy.isCurrent(
                shellStartupView.identity,
                tabID: identity.tabID,
                generation: identity.generation
              ),
              transitionGeneration == identity.generation,
              let origin = tabs.first(where: { $0.id == identity.tabID }),
              desiredMirrorTab === origin,
              origin.requiresSemanticPromptReadiness,
              !origin.semanticPromptReadinessObserved,
              !origin.closing else { return }
        appendTab(
          initialCommand: nil,
          shellLaunchMode: .cleanZsh,
          initialPath: origin.path
        )
        tabs.last?.creationFallbackTabID = origin.id
        showTab(at: tabs.count - 1)
    }

    @objc func closeTab(_ sender: Any?) {
        guard tabs.indices.contains(selectedIndex) else { return }
        let tab = tabs[selectedIndex]
        beginRemoval(of: tab, disposition: .closeView)
    }

    var canCloseSelectedTab: Bool {
        tabs.indices.contains(selectedIndex) && !tabs[selectedIndex].closing
    }

    @objc func terminateSession(_ sender: Any?) {
        guard tabs.indices.contains(selectedIndex) else { return }
        let tab = tabs[selectedIndex]
        guard !tab.closing, confirmTermination(of: tab) else { return }
        beginRemoval(of: tab, disposition: .terminateSession)
    }

    @objc func reopenClosedView(_ sender: Any?) {
        guard tabs.count < Self.maximumTabs,
              let record = closedViews.last else { return }
        broker.list { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let terminals):
                guard let terminal = terminals.first(where: {
                    $0.id == record.terminalID && $0.running
                }) else {
                    self.closedViews.removeAll { $0.terminalID == record.terminalID }
                    self.presentClosedViewUnavailable(record)
                    return
                }
                guard let recordIndex = self.closedViews.lastIndex(of: record) else { return }
                self.closedViews.remove(at: recordIndex)
                self.terminalFontSizes[terminal.id] = record.fontPointSize

                self.appendTab(
                    initialCommand: nil,
                    brokerTerminal: terminal,
                    restoredTitle: record.title,
                    restoredPath: record.path,
                    restoredDisplaySequence: record.displaySequence
                )
                self.showTab(at: self.tabs.count - 1)
            case .failure(let error):
                // A transient list failure must not consume the only local
                // reopen handle. The durable terminal remains broker-owned.
                self.presentError(error, in: self.tabs[self.selectedIndex])
            }
        }
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        showTab(at: (selectedIndex - 1 + tabs.count) % tabs.count)
    }

    @objc func selectNextTab(_ sender: Any?) {
        guard !tabs.isEmpty else { return }
        showTab(at: (selectedIndex + 1) % tabs.count)
    }

    /// Native AppKit menu key equivalents carry their one-based tab number in
    /// the menu item tag. Selection still crosses `showTab(at:)`, preserving
    /// the existing responder handoff and broker detach/input-lease barrier.
    @objc func selectTabByNumber(_ sender: Any?) {
        guard let menuItem = sender as? NSMenuItem else { return }
        let unavailable = Set(tabs.indices.filter { tabs[$0].closing })
        guard let index = NativeTerminalShortcutPolicy.tabIndex(
            commandNumber: menuItem.tag,
            tabCount: tabs.count,
            unavailableIndices: unavailable
        ) else { return }
        showTab(at: index)
    }

    @objc func focusTerminal(_ sender: Any?) {
        sessionWorkspaceContent?.onClose?()
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        if tabs.indices.contains(selectedIndex),
           let workspace = tabs[selectedIndex].workspaceTab,
           let focusedTerminalID = (try? workspace.snapshot())?.focusedTerminalID,
           let runtime = additionalPaneRuntimes[focusedTerminalID],
           !inputLocked {
            view.window?.makeFirstResponder(runtime.coordinator.view)
            return
        }
        guard let surfaceCoordinator, !inputLocked else {
            NSSound.beep()
            return
        }
        view.window?.makeFirstResponder(surfaceCoordinator.view)
        #else
        if let mirrorTerminal, mirrorTab === desiredMirrorTab, !inputLocked {
            view.window?.makeFirstResponder(mirrorTerminal)
        } else {
            NSSound.beep()
        }
        #endif
    }

    func commandSnapshot(limit: Int) -> [CommandDescriptor] {
        let provider = commandProviderID
        let selectedTabCanTerminate = tabs.indices.contains(selectedIndex)
            && !tabs[selectedIndex].closing
            && (tabs[selectedIndex].brokerTerminalID != nil
                || tabs[selectedIndex].creating
                || tabs[selectedIndex].creationOutcomeUnknown)
        var commands = [
            CommandDescriptor(
                id: CommandID(provider: provider, local: "new-tab"),
                title: "New Terminal Tab",
                keywords: ["shell", "create"],
                section: .actions,
                shortcut: "⌘T",
                symbolName: "plus.rectangle.on.rectangle",
                isEnabled: tabs.count < Self.maximumTabs,
                rankHint: 90
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "split-right"),
                title: "Split Right",
                subtitle: "Open an independent shell beside this pane",
                keywords: ["pane", "terminal", "vertical", "side by side"],
                section: .actions,
                shortcut: "⌘D",
                symbolName: "rectangle.split.2x1",
                isEnabled: canSplitFocusedPane,
                rankHint: 88
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "split-down"),
                title: "Split Down",
                subtitle: "Open an independent shell below this pane",
                keywords: ["pane", "terminal", "horizontal", "stack"],
                section: .actions,
                shortcut: "⇧⌘D",
                symbolName: "rectangle.split.1x2",
                isEnabled: canSplitFocusedPane,
                rankHint: 87
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "close-pane"),
                title: "Close Focused Pane",
                subtitle: "Release this pane without terminating its broker session",
                keywords: ["pane", "split", "detach"],
                section: .actions,
                shortcut: "⌥⌘W",
                symbolName: "rectangle.badge.xmark",
                isEnabled: canCloseFocusedPane,
                rankHint: 86
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "equalize-panes"),
                title: "Equalize Panes",
                subtitle: "Give every recursive divider an even share",
                keywords: ["pane", "split", "balance", "layout"],
                section: .actions,
                symbolName: "rectangle.split.3x1",
                isEnabled: canEqualizePanes,
                rankHint: 84
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "maximize-pane"),
                title: "Maximize Focused Pane",
                subtitle: "Temporarily fill the workspace; PTYs remain attached",
                keywords: ["pane", "focus", "zoom", "restore"],
                section: .actions,
                shortcut: "⇧⌘↩",
                symbolName: "arrow.up.left.and.arrow.down.right",
                isEnabled: canMaximizeFocusedPane,
                rankHint: 83
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "focus-pane-left"),
                title: "Focus Pane Left",
                keywords: ["pane", "focus", "split"],
                section: .actions,
                shortcut: "⌥⌘←",
                symbolName: "arrow.left",
                isEnabled: canMoveFocus,
                rankHint: 82
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "focus-pane-right"),
                title: "Focus Pane Right",
                keywords: ["pane", "focus", "split"],
                section: .actions,
                shortcut: "⌥⌘→",
                symbolName: "arrow.right",
                isEnabled: canMoveFocus,
                rankHint: 81
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "focus-pane-up"),
                title: "Focus Pane Up",
                keywords: ["pane", "focus", "split"],
                section: .actions,
                shortcut: "⌥⌘↑",
                symbolName: "arrow.up",
                isEnabled: canMoveFocus,
                rankHint: 80
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "focus-pane-down"),
                title: "Focus Pane Down",
                keywords: ["pane", "focus", "split"],
                section: .actions,
                shortcut: "⌥⌘↓",
                symbolName: "arrow.down",
                isEnabled: canMoveFocus,
                rankHint: 79
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "find"),
                title: "Find in Terminal",
                keywords: ["search", "scrollback"],
                section: .actions,
                shortcut: "⌘F",
                symbolName: "magnifyingglass",
                isEnabled: !tabs.isEmpty && !inputLocked,
                rankHint: 80
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "clear-screen"),
                title: "Clear Terminal Screen",
                keywords: ["clean", "reset", "shell"],
                section: .actions,
                shortcut: "⌘K",
                symbolName: "eraser",
                isEnabled: !tabs.isEmpty && !inputLocked,
                rankHint: 70
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "close-tab"),
                title: "Close Terminal Tab",
                subtitle: "Keeps the broker session running",
                keywords: ["detach", "view"],
                section: .actions,
                shortcut: "⌘W",
                symbolName: "xmark.rectangle",
                isEnabled: canCloseSelectedTab,
                rankHint: 40
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "reopen-tab"),
                title: "Reopen Closed Tab",
                keywords: ["restore", "view"],
                section: .actions,
                shortcut: "⇧⌘T",
                symbolName: "arrow.uturn.backward.square",
                isEnabled: tabs.count < Self.maximumTabs && !closedViews.isEmpty,
                rankHint: 35
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "previous-tab"),
                title: "Select Previous Tab",
                section: .actions,
                shortcut: "⇧⌘[",
                symbolName: "chevron.left",
                isEnabled: tabs.count > 1,
                rankHint: 20
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "next-tab"),
                title: "Select Next Tab",
                section: .actions,
                shortcut: "⇧⌘]",
                symbolName: "chevron.right",
                isEnabled: tabs.count > 1,
                rankHint: 20
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "rename-tab"),
                title: "Rename Terminal Tab…",
                keywords: ["label", "name", "tab"],
                section: .actions,
                symbolName: "pencil",
                isEnabled: tabs.indices.contains(selectedIndex) && !tabs[selectedIndex].closing,
                rankHint: 25
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "move-tab-left"),
                title: "Move Terminal Tab Left",
                keywords: ["reorder", "tab"],
                section: .actions,
                symbolName: "arrow.left.to.line",
                isEnabled: selectedIndex > 0 && tabs.indices.contains(selectedIndex),
                rankHint: 10
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "move-tab-right"),
                title: "Move Terminal Tab Right",
                keywords: ["reorder", "tab"],
                section: .actions,
                symbolName: "arrow.right.to.line",
                isEnabled: tabs.indices.contains(selectedIndex) && selectedIndex + 1 < tabs.count,
                rankHint: 10
            ),
            CommandDescriptor(
                id: CommandID(provider: provider, local: "terminate-session"),
                title: "Terminate Session…",
                subtitle: "Stops the shell after confirmation",
                keywords: ["kill", "process", "destructive"],
                section: .actions,
                shortcut: "⇧⌘W",
                symbolName: "exclamationmark.octagon",
                isEnabled: selectedTabCanTerminate,
                rankHint: -100
            ),
        ]
        commands.append(contentsOf: tabs.enumerated().map { index, tab in
            CommandDescriptor(
                id: CommandID(provider: provider, local: "tab:\(tab.id.uuidString)"),
                title: resolvedTabDisplayTitle(tab),
                subtitle: (tab.path as NSString).abbreviatingWithTildeInPath,
                keywords: [tab.path, "tab", "terminal", String(tab.displaySequence)],
                section: .terminals,
                shortcut: index < NativeTerminalShortcutPolicy.directTabLimit
                    ? "⌘\(index + 1)"
                    : nil,
                symbolName: tab === mirrorTab ? "terminal.fill" : "terminal",
                rankHint: tab === mirrorTab ? 120 : 0
            )
        })
        return Array(commands.prefix(max(0, limit)))
    }

    func perform(commandID: CommandID) -> CommandExecutionResult {
        guard commandID.provider == commandProviderID else {
            return .unavailable("The terminal command is no longer available.")
        }
        switch commandID.local {
        case "new-tab":
            guard tabs.count < Self.maximumTabs else { return .unavailable("The 32-tab limit has been reached.") }
            addTab(nil)
        case "split-right":
            guard !isAtPaneLimit else {
                presentPaneLimitReached()
                return .unavailable("Maximum 4 panes")
            }
            guard canSplitFocusedPane else { return .unavailable("This terminal cannot be split right now.") }
            splitPaneRight(nil)
        case "split-down":
            guard !isAtPaneLimit else {
                presentPaneLimitReached()
                return .unavailable("Maximum 4 panes")
            }
            guard canSplitFocusedPane else { return .unavailable("This terminal cannot be split right now.") }
            splitPaneDown(nil)
        case "close-pane":
            guard canCloseFocusedPane else { return .unavailable("The focused pane cannot be closed.") }
            closeFocusedPane(nil)
        case "equalize-panes":
            guard canEqualizePanes else { return .unavailable("There are no split panes to equalize.") }
            equalizePanes(nil)
        case "maximize-pane":
            guard canMaximizeFocusedPane else { return .unavailable("There are no split panes to maximize.") }
            toggleMaximizeFocusedPane(nil)
        case "focus-pane-left": focusPaneLeft(nil)
        case "focus-pane-right": focusPaneRight(nil)
        case "focus-pane-up": focusPaneUp(nil)
        case "focus-pane-down": focusPaneDown(nil)
        case "find":
            guard !tabs.isEmpty, !inputLocked else { return .unavailable("The terminal is still attaching.") }
            showFind(nil)
        case "clear-screen":
            guard !tabs.isEmpty, !inputLocked else { return .unavailable("The terminal is still attaching.") }
            clearTerminalScreen(nil)
        case "close-tab":
            guard canCloseSelectedTab else { return .unavailable("This tab cannot be closed right now.") }
            closeTab(nil)
        case "reopen-tab":
            guard tabs.count < Self.maximumTabs, !closedViews.isEmpty else {
                return .unavailable("There is no closed terminal view to reopen.")
            }
            reopenClosedView(nil)
        case "previous-tab": selectPreviousTab(nil)
        case "next-tab": selectNextTab(nil)
        case "rename-tab":
            guard tabs.indices.contains(selectedIndex), !tabs[selectedIndex].closing else {
                return .unavailable("This tab cannot be renamed right now.")
            }
            renameSelectedTab(nil)
        case "move-tab-left":
            guard selectedIndex > 0, tabs.indices.contains(selectedIndex) else {
                return .unavailable("This tab is already first.")
            }
            moveSelectedTabLeft(nil)
        case "move-tab-right":
            guard tabs.indices.contains(selectedIndex), selectedIndex + 1 < tabs.count else {
                return .unavailable("This tab is already last.")
            }
            moveSelectedTabRight(nil)
        case "terminate-session": terminateSession(nil)
        default:
            guard commandID.local.hasPrefix("tab:"),
                  let id = UUID(uuidString: String(commandID.local.dropFirst(4))),
                  let index = tabs.firstIndex(where: { $0.id == id }) else {
                return .unavailable("That terminal tab no longer exists.")
            }
            showTab(at: index)
        }
        return .executed
    }

    @objc private func toggleSources(_ sender: Any?) {
        onToggleSources?()
    }

    @objc private func openCommandPalette(_ sender: Any?) {
        onOpenCommandPalette?()
    }

    func setSourcesVisible(_ visible: Bool) {
        let label = visible ? "Hide Connections" : "Show Connections"
        sourcesButton.toolTip = label
        sourcesButton.setAccessibilityLabel(label)
        sourcesButton.contentTintColor = visible ? OuroTheme.text : .secondaryLabelColor
    }

    /// Projects verified Ouroboros-to-broker bindings into the existing tab
    /// strip. Unbound terminals keep their real shell title; this deliberately
    /// never infers identity from cwd or a repeated fanout label.
    @discardableResult
    func applySessionBindings(_ bindings: [TerminalSessionBinding]) -> Int {
        precondition(Thread.isMainThread)
        if bindings != advertisedSessionBindings {
            advertisedSessionBindings = bindings
            advertisedSessionBindingsRevision &+= 1
            if advertisedSessionBindingsRevision == 0 {
                advertisedSessionBindingsRevision = 1
            }
        }
        var changed = false
        var boundCount = 0
        for tab in tabs {
            let binding = tab.brokerTerminalID.flatMap { terminalID -> TerminalSessionBinding? in
                guard let brokerGeneration,
                      let leaf = TerminalSessionBindingPolicy.leaf(
                        for: terminalID,
                        brokerGeneration: brokerGeneration,
                        bindings: advertisedSessionBindings
                      ) else {
                    return nil
                }
                return TerminalSessionBindingPolicy.binding(
                    for: leaf,
                    brokerGeneration: brokerGeneration,
                    bindings: advertisedSessionBindings
                )
            }
            if binding != nil { boundCount += 1 }
            if tab.sessionBinding != binding {
                tab.sessionBinding = binding
                changed = true
            }
        }
        if changed { rebuildTabControl() }
        publishFocusedSessionPane()
        return boundCount
    }

    private func publishLiveTerminalSessions() {
        let snapshot = tabs.enumerated().map { index, tab in
            LiveTerminalSession(
                id: tab.id,
                title: resolvedTabDisplayTitle(tab),
                path: tab.path,
                selected: index == selectedIndex,
                running: tab.running,
                foregroundProcess: tab.foregroundProcess,
                binding: tab.sessionBinding
            )
        }
        onLiveTerminalSessionsChange?(snapshot)
    }

    func activateLiveTerminalSession(_ id: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }), !tabs[index].closing else {
            return false
        }
        showTab(at: index)
        return true
    }

    /// Re-projects pane focus through the current broker incarnation. A pane
    /// may keep accepting ordinary terminal input when this resolves to nil;
    /// only the separate session composer becomes unavailable.
    private func publishFocusedSessionPane() {
        precondition(Thread.isMainThread)
        let focusedTerminalID: String?
        if tabs.indices.contains(selectedIndex) {
            let tab = tabs[selectedIndex]
            #if OUROCODE_GHOSTTY_RENDERER
            focusedTerminalID = (try? tab.workspaceTab?.snapshot())?.focusedTerminalID
                ?? tab.brokerTerminalID
            #else
            focusedTerminalID = tab.brokerTerminalID
            #endif
        } else {
            focusedTerminalID = nil
        }
        let focus = SessionPaneSteeringFocusPolicy.resolve(
            focusedTerminalID: focusedTerminalID,
            brokerGeneration: brokerGeneration,
            bindings: advertisedSessionBindings
        )
        guard focus != publishedFocusedSessionPane else { return }
        publishedFocusedSessionPane = focus
        onFocusedSessionPaneChange?(focus)
    }

    /// Direct session-to-terminal activation for the rail. Existing views are
    /// selected immediately; a verified broker-owned PTY without a local view
    /// is adopted through `list`, then enters the normal attach/recovery path.
    private func openSessionSurfaceResolution(
        terminalID: String
    ) -> TerminalSessionOpenSurfaceResolution {
        #if OUROCODE_GHOSTTY_RENDERER
        var surfaces: [TerminalSessionOpenSurfaceTab] = []
        surfaces.reserveCapacity(tabs.count)
        for tab in tabs {
            let workspaceTerminalIDs: [String]
            if let workspace = tab.workspaceTab {
                guard let snapshot = try? workspace.snapshot() else {
                    return .ambiguous
                }
                workspaceTerminalIDs = snapshot.leaves.map(\.terminalID)
            } else {
                workspaceTerminalIDs = []
            }
            surfaces.append(TerminalSessionOpenSurfaceTab(
                primaryTerminalID: tab.brokerTerminalID,
                workspaceTerminalIDs: workspaceTerminalIDs
            ))
        }
        return TerminalSessionOpenSurfacePolicy.resolve(
            terminalID: terminalID,
            tabs: surfaces
        )
        #else
        return TerminalSessionOpenSurfacePolicy.resolve(
            terminalID: terminalID,
            tabs: tabs.map {
                TerminalSessionOpenSurfaceTab(
                    primaryTerminalID: $0.brokerTerminalID,
                    workspaceTerminalIDs: []
                )
            }
        )
        #endif
    }

    /// Returns nil only when the PTY has no local presentation. An ambiguous
    /// local identity is an explicit failure and must never fall through to
    /// broker adoption, which would duplicate an already-owned split leaf.
    private func activateOpenSessionSurface(
        terminalID: String,
        requestIsCurrent: () -> Bool
    ) -> TerminalSessionActivationResult? {
        switch openSessionSurfaceResolution(terminalID: terminalID) {
        case .none:
            return nil
        case .ambiguous:
            return .unavailable(.noVerifiedBinding)
        case .primary(let index):
            guard requestIsCurrent(), tabs.indices.contains(index) else {
                return .unavailable(.noVerifiedBinding)
            }
            showTab(at: index)
            return .activated
        case .splitPane(let index):
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            guard requestIsCurrent(), tabs.indices.contains(index),
                  let workspace = tabs[index].workspaceTab,
                  let snapshot = try? workspace.snapshot(),
                  snapshot.leaves.contains(where: { $0.terminalID == terminalID }) else {
                return .unavailable(.noVerifiedBinding)
            }
            let tab = tabs[index]
            do {
                if snapshot.focusedTerminalID != terminalID {
                    try workspace.focus(
                        terminalID: terminalID,
                        expectedRevision: snapshot.layoutRevision
                    )
                }
            } catch {
                return .unavailable(.noVerifiedBinding)
            }
            // Record exact pane focus before changing tabs. A background split
            // restores asynchronously and consumes this focused identity;
            // an already-projected split can transfer input immediately.
            showTab(at: index)
            focusedTypographyTerminalID = terminalID
            projectSelectedWorkspaceIfNeeded()
            if desiredMirrorTab === tab,
               additionalPaneRuntimes[terminalID] != nil {
                activateWorkspacePane(terminalID, tab: tab, workspace: workspace)
            }
            return .activated
            #else
            return .unavailable(.noVerifiedBinding)
            #endif
        }
    }

    func activateSessionLeaf(
        _ leaf: TerminalSessionLeafIdentity,
        bindings: [TerminalSessionBinding],
        requestIsCurrent: @escaping () -> Bool,
        completion: @escaping (TerminalSessionActivationResult) -> Void
    ) {
        precondition(Thread.isMainThread)
        guard let brokerGeneration else {
            completion(.unavailable(.noCurrentBrokerGeneration))
            return
        }
        guard let binding = TerminalSessionBindingPolicy.binding(
            for: leaf,
            brokerGeneration: brokerGeneration,
            bindings: bindings
        ), bindings == advertisedSessionBindings else {
            completion(.unavailable(.noVerifiedBinding))
            return
        }
        let expectedBindingsRevision = advertisedSessionBindingsRevision
        let terminalID = binding.terminalID
        let waiter = PendingSessionActivationWaiter(
            requestIsCurrent: requestIsCurrent,
            completion: completion
        )
        guard let existingResult = activateOpenSessionSurface(
            terminalID: terminalID,
            requestIsCurrent: requestIsCurrent
        ) else {
            guard tabs.count < Self.maximumTabs else {
                completion(.unavailable(.tabLimitReached))
                return
            }
            if pendingSessionActivations[terminalID] != nil {
                pendingSessionActivations[terminalID, default: []].append(waiter)
                return
            }
            pendingSessionActivations[terminalID] = [waiter]
            let expectedGeneration = brokerGeneration
            broker.list { [weak self] result in
                guard let self else { return }
                let waiters = self.pendingSessionActivations.removeValue(forKey: terminalID) ?? []
                let finish: (TerminalSessionActivationResult) -> Void = { activationResult in
                    for waiter in waiters { waiter.completion(activationResult) }
                }
                let activeWaiters = waiters.filter { $0.requestIsCurrent() }
                guard !activeWaiters.isEmpty else {
                    finish(.unavailable(.noVerifiedBinding))
                    return
                }
                guard self.brokerGeneration == expectedGeneration else {
                    finish(.unavailable(.noCurrentBrokerGeneration))
                    return
                }
                guard TerminalSessionBindingRevisionPolicy.accepts(
                    expectedRevision: expectedBindingsRevision,
                    currentRevision: self.advertisedSessionBindingsRevision,
                    expectedBinding: binding,
                    leaf: leaf,
                    brokerGeneration: expectedGeneration,
                    currentBindings: self.advertisedSessionBindings
                ) else {
                    finish(.unavailable(.noVerifiedBinding))
                    return
                }
                switch result {
                case .failure:
                    finish(.unavailable(.brokerUnavailable))
                case .success(let terminals):
                    if let existingResult = self.activateOpenSessionSurface(
                        terminalID: terminalID,
                        requestIsCurrent: { activeWaiters.contains(where: { $0.requestIsCurrent() }) }
                    ) {
                        finish(existingResult)
                        return
                    }
                    guard let terminal = terminals.first(where: { $0.id == terminalID }) else {
                        finish(.unavailable(.terminalNotOpen))
                        return
                    }
                    let canAdopt = TerminalSessionBrokerAdoptionPolicy.accepts(
                        expectedTerminalID: terminalID,
                        expectedBrokerGeneration: expectedGeneration,
                        currentBrokerGeneration: self.brokerGeneration,
                        listedTerminalID: terminal.id,
                        listedTerminalIsRunning: terminal.running,
                        terminalAlreadyOpen: self.openSessionSurfaceResolution(
                            terminalID: terminalID
                        ).isOpen,
                        hasTabCapacity: self.tabs.count < Self.maximumTabs
                    )
                    guard canAdopt else {
                        finish(.unavailable(
                            terminal.running ? .tabLimitReached : .terminalNotOpen
                        ))
                        return
                    }
                    // Session entry is also an explicit reopen of this durable
                    // broker PTY. Consume any same-process Close View record so
                    // the generic reopen command cannot create a duplicate tab.
                    if let closed = self.closedViews.last(where: { $0.terminalID == terminalID }) {
                        self.terminalFontSizes[terminalID] = closed.fontPointSize
                    }
                    self.closedViews.removeAll { $0.terminalID == terminalID }
                    self.appendTab(
                        initialCommand: nil,
                        brokerTerminal: terminal,
                        restoredTitle: binding.tabTitle
                    )
                    guard let adoptedTab = self.tabs.last else {
                        finish(.unavailable(.brokerUnavailable))
                        return
                    }
                    adoptedTab.sessionBinding = binding
                    self.showTab(at: self.tabs.count - 1)
                    finish(.activated)
                }
            }
            return
        }
        completion(existingResult)
    }

    private func typographyTargetTerminalID() -> String? {
        guard tabs.indices.contains(selectedIndex),
              let primaryID = tabs[selectedIndex].brokerTerminalID else { return nil }
        #if OUROCODE_GHOSTTY_RENDERER
        if let focused = focusedTypographyTerminalID,
           let workspace = tabs[selectedIndex].workspaceTab,
           (try? workspace.snapshot())?.leaves.contains(where: { $0.terminalID == focused }) == true {
            return focused
        }
        #endif
        return primaryID
    }

    /// Resolve terminal-wide commands against the pane the person is actually
    /// using. The tab's primary renderer is retained separately for the
    /// single-pane fast path; every additional split owns an independent
    /// coordinator and scrollback projection.
    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private func focusedSurfaceCoordinator() -> TerminalSurfaceCoordinator? {
        guard tabs.indices.contains(selectedIndex) else { return nil }
        let tab = tabs[selectedIndex]
        let focusedTerminalID = tab.workspaceTab.flatMap { try? $0.snapshot().focusedTerminalID }
        let targetTerminalID = TerminalFocusedSurfaceRouting.terminalID(
            primaryTerminalID: tab.brokerTerminalID,
            focusedTerminalID: focusedTerminalID,
            availableAdditionalTerminalIDs: Set(additionalPaneRuntimes.keys)
        )
        guard let targetTerminalID else { return nil }
        if targetTerminalID == tab.brokerTerminalID {
            return surfaceCoordinator
        }
        return additionalPaneRuntimes[targetTerminalID]?.coordinator
    }
    #endif

    /// Application-level zoom is inert when the key window has no terminal
    /// surface (for example while the host is still bootstrapping). The
    /// AppDelegate uses this to avoid changing a global preference behind a
    /// Connections/session workspace with no eligible target.
    var hasEligibleTerminalForApplicationTypography: Bool {
        !tabs.isEmpty
    }

    private func typographyTargetFontSize() -> CGFloat {
        guard let targetID = typographyTargetTerminalID() else {
            return OuroTheme.terminalFontSize
        }
        return terminalFontSizes[targetID] ?? OuroTheme.terminalFontSize
    }

    @objc func increaseTerminalFontSize(_ sender: Any?) {
        applyTerminalFontSize(typographyTargetFontSize() + 1)
    }

    @objc func decreaseTerminalFontSize(_ sender: Any?) {
        applyTerminalFontSize(typographyTargetFontSize() - 1)
    }

    @objc func resetTerminalFontSize(_ sender: Any?) {
        let targetID = typographyTargetTerminalID()
        let previous = typographyTargetFontSize()
        let current = OuroTheme.defaultTerminalFontSize
        guard current != previous else {
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            TerminalTypographyRuntimeTrace.record("coalesced", "reset-at-default")
            #endif
            presentTerminalFontSizeHUD(status: "Default")
            return
        }
        OuroTheme.resetTerminalFontSize()
        if let targetID {
            terminalFontSizes[targetID] = current
            OuroTheme.setTerminalFontSize(current)
        }
        applyTerminalTypography(targetTerminalID: targetID)
        presentTerminalFontSizeHUD(status: "Default")
    }

    @objc func clearTerminalScreen(_ sender: Any?) {
        guard !tabs.isEmpty, !inputLocked else {
            NSSound.beep()
            return
        }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        focusedSurfaceCoordinator()?.clearScreen()
        #else
        mirrorTerminal?.send([0x0c])
        #endif
    }

    @objc func scrollTerminalToTop(_ sender: Any?) {
        guard !tabs.isEmpty else {
            NSSound.beep()
            return
        }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        focusedSurfaceCoordinator()?.scrollToTop()
        #else
        NSSound.beep()
        #endif
    }

    @objc func scrollTerminalToBottom(_ sender: Any?) {
        guard !tabs.isEmpty else {
            NSSound.beep()
            return
        }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        focusedSurfaceCoordinator()?.scrollToBottom()
        #else
        NSSound.beep()
        #endif
    }

    func performTypographyShortcut(_ action: TerminalTypographyShortcut) {
        switch action {
        case .increase: increaseTerminalFontSize(nil)
        case .decrease: decreaseTerminalFontSize(nil)
        case .reset: resetTerminalFontSize(nil)
        }
    }

    func isTypographyActionEnabled(_ action: TerminalTypographyShortcut) -> Bool {
        typographyActionEnabled(action)
    }

    @objc func showFind(_ sender: Any?) {
        let panel = findPanelController ?? {
            let next = TerminalFindPanelController()
            next.onSearch = { [weak self] query, completion in
                #if OUROCODE_GHOSTTY_METAL_SURFACE
                guard let self, let surface = self.focusedSurfaceCoordinator(),
                      !self.inputLocked,
                      self.mirrorTab === self.desiredMirrorTab else {
                    completion(.failure(TerminalSurfaceCoordinatorError.activeStreamMissing))
                    return
                }
                surface.findScrollback(query: query, completion: completion)
                #else
                completion(.success(TerminalFindResult(matches: [], truncated: false)))
                #endif
            }
            next.onReveal = { [weak self] match in
                #if OUROCODE_GHOSTTY_METAL_SURFACE
                guard let self,
                      !self.inputLocked,
                      self.mirrorTab === self.desiredMirrorTab else { return }
                self.focusedSurfaceCoordinator()?.revealFindMatch(match)
                #endif
            }
            findPanelController = next
            return next
        }()
        panel.present(relativeTo: view.window)
    }

    @objc func findNext(_ sender: Any?) {
        guard let findPanelController else {
            showFind(sender)
            return
        }
        findPanelController.revealNext()
    }

    @objc func findPrevious(_ sender: Any?) {
        guard let findPanelController else {
            showFind(sender)
            return
        }
        findPanelController.revealPrevious()
    }

    func setTerminalFontSize(_ size: CGFloat) {
        applyTerminalFontSize(size)
    }

    private func applyTerminalFontSize(_ size: CGFloat) {
        let targetID = typographyTargetTerminalID()
        let previous = typographyTargetFontSize()
        guard let change = TerminalTypographyPointSizeTransition.resolve(
            current: previous,
            requested: size,
            minimum: OuroTheme.minimumTerminalFontSize,
            maximum: OuroTheme.maximumTerminalFontSize
        ) else {
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            TerminalTypographyRuntimeTrace.record("coalesced", "font=\(previous)")
            #endif
            let status = TerminalTypographyPointSizeTransition.noOpFeedback(
                action: size > previous ? .increase : .decrease,
                current: previous,
                minimum: OuroTheme.minimumTerminalFontSize,
                maximum: OuroTheme.maximumTerminalFontSize,
                defaultSize: OuroTheme.defaultTerminalFontSize
            )
            presentTerminalFontSizeHUD(status: status ?? "Unchanged")
            return
        }
        OuroTheme.setTerminalFontSize(change.next)
        let current = change.next
        if let targetID { terminalFontSizes[targetID] = current }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        TerminalTypographyRuntimeTrace.record(
            "preference",
            "previous=\(previous) next=\(current)"
        )
        #endif
        applyTerminalTypography(targetTerminalID: targetID)
        presentTerminalFontSizeHUD(status: change.boundary?.rawValue)
    }


    private func presentTerminalFontSizeHUD(status: String?) {
        let pointSize = Int(typographyTargetFontSize().rounded())
        let suffix = status.map { " · \($0)" } ?? ""
        presentTerminalHUD(
            text: "\(pointSize) pt\(suffix)",
            announcement: "Terminal text size \(pointSize) points\(status.map { ", \($0.lowercased())" } ?? "")",
            priority: .medium
        )
    }

    private func presentTerminalHUD(
        text: String,
        announcement: String,
        priority: NSAccessibilityPriorityLevel
    ) {
        textSizeHUDGeneration &+= 1
        let generation = textSizeHUDGeneration
        textSizeHUDHideWorkItem?.cancel()
        textSizeHUD.layer?.removeAllAnimations()
        textSizeHUDLabel.stringValue = text
        textSizeHUD.alphaValue = 1
        textSizeHUD.isHidden = false
        NSAccessibility.post(
            element: view,
            notification: .announcementRequested,
            userInfo: [
                .announcement: announcement,
                .priority: priority.rawValue,
            ]
        )

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hide = DispatchWorkItem { [weak self] in
            guard let self, self.textSizeHUDGeneration == generation else { return }
            if reduceMotion {
                self.textSizeHUD.isHidden = true
                return
            }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                self.textSizeHUD.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                guard let self, self.textSizeHUDGeneration == generation else { return }
                self.textSizeHUD.isHidden = true
                self.textSizeHUD.alphaValue = 1
            }
        }
        textSizeHUDHideWorkItem = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hide)
    }

    private func applyTerminalTypography(targetTerminalID: String? = nil) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        let targetID = targetTerminalID ?? typographyTargetTerminalID()
        scheduleGhosttyResize(onlyTerminalID: targetID)
    #else
    let font = OuroTheme.monoFont(size: OuroTheme.terminalFontSize)
    mirrorTerminal?.font = font
    candidateTerminal?.font = font
    #endif
    NotificationCenter.default.post(name: TerminalPreferences.didChangeNotification, object: nil)
  }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(addTab(_:)):
            return tabs.count < Self.maximumTabs
        case #selector(splitPaneRight(_:)), #selector(splitPaneDown(_:)):
            return canSplitFocusedPane
        case #selector(closeFocusedPane(_:)):
            return canCloseFocusedPane
        case #selector(equalizePanes(_:)):
            return canEqualizePanes
        case #selector(toggleMaximizeFocusedPane(_:)):
            return canMaximizeFocusedPane
        case #selector(focusPaneLeft(_:)), #selector(focusPaneRight(_:)),
             #selector(focusPaneUp(_:)), #selector(focusPaneDown(_:)):
            return canMoveFocus
        case #selector(closeTab(_:)):
            return canCloseSelectedTab
        case #selector(terminateSession(_:)):
            return tabs.indices.contains(selectedIndex)
                && !tabs[selectedIndex].closing
                && (tabs[selectedIndex].brokerTerminalID != nil
                    || tabs[selectedIndex].creating
                    || tabs[selectedIndex].creationOutcomeUnknown)
        case #selector(reopenClosedView(_:)):
            return tabs.count < Self.maximumTabs && !closedViews.isEmpty
        case #selector(selectPreviousTab(_:)), #selector(selectNextTab(_:)):
            return !tabs.isEmpty
        case #selector(selectTabByNumber(_:)):
            let unavailable = Set(tabs.indices.filter { tabs[$0].closing })
            return NativeTerminalShortcutPolicy.tabIndex(
                commandNumber: menuItem.tag,
                tabCount: tabs.count,
                unavailableIndices: unavailable
            ) != nil
        case #selector(renameSelectedTab(_:)):
            return tabs.indices.contains(selectedIndex) && !tabs[selectedIndex].closing
        case #selector(moveSelectedTabLeft(_:)):
            return tabs.indices.contains(selectedIndex) && selectedIndex > 0
        case #selector(moveSelectedTabRight(_:)):
            return tabs.indices.contains(selectedIndex) && selectedIndex + 1 < tabs.count
        case #selector(focusTerminal(_:)):
            return !tabs.isEmpty && !inputLocked
        case #selector(showFind(_:)), #selector(findNext(_:)), #selector(findPrevious(_:)):
            return !tabs.isEmpty && !inputLocked
        case #selector(clearTerminalScreen(_:)):
            return view.window?.isKeyWindow == true && !tabs.isEmpty && !inputLocked
        case #selector(scrollTerminalToTop(_:)), #selector(scrollTerminalToBottom(_:)):
            return view.window?.isKeyWindow == true && !tabs.isEmpty
        case #selector(increaseTerminalFontSize(_:)):
            return typographyActionEnabled(.increase)
        case #selector(decreaseTerminalFontSize(_:)):
            return typographyActionEnabled(.decrease)
        case #selector(resetTerminalFontSize(_:)):
            return typographyActionEnabled(.reset)
        default:
            return true
        }
    }

    private func typographyActionEnabled(_ action: TerminalTypographyShortcut) -> Bool {
        TerminalTypographyAvailability.isEnabled(
            action,
            // A session workspace or another Ourocode panel may temporarily
            // be key while this controller still owns the selected terminal.
            // Zoom remains an app-wide command as long as the app is active
            // and a terminal exists.
            hasEligibleTerminal: NSApp.isActive && !tabs.isEmpty,
            currentSize: typographyTargetFontSize(),
            minimumSize: OuroTheme.minimumTerminalFontSize,
            maximumSize: OuroTheme.maximumTerminalFontSize,
            defaultSize: OuroTheme.defaultTerminalFontSize
        )
    }

    private func confirmTermination(of tab: LocalTerminalTab) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Terminate this session?"
        if tab.foregroundProcess {
            alert.informativeText = "This stops the foreground process and its shell. This cannot be undone. To keep them running, use Close View instead."
        } else if tab.running {
            alert.informativeText = "This stops the shell and removes its broker session. This cannot be undone. To keep it running, use Close View instead."
        } else {
            alert.informativeText = "This permanently removes the broker session if its creation completed. This cannot be undone."
        }
        alert.alertStyle = .warning
        let terminateButton = alert.addButton(withTitle: "Terminate Session")
        terminateButton.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    @objc private func selectTab(_ sender: NSButton) {
        guard tabs.indices.contains(sender.tag) else { return }
        showTab(at: sender.tag)
    }

    @objc func renameSelectedTab(_ sender: Any?) {
        guard tabs.indices.contains(selectedIndex), !tabs[selectedIndex].closing else { return }
        renameTab(tabs[selectedIndex])
    }

    @objc func moveSelectedTabLeft(_ sender: Any?) {
        guard tabs.indices.contains(selectedIndex) else { return }
        moveTab(tabs[selectedIndex], offset: -1)
    }

    @objc func moveSelectedTabRight(_ sender: Any?) {
        guard tabs.indices.contains(selectedIndex) else { return }
        moveTab(tabs[selectedIndex], offset: 1)
    }

    private func renameTab(_ tab: LocalTerminalTab) {
        guard tabs.contains(where: { $0 === tab }), !tab.closing else { return }
        let field = NSTextField(string: tab.titleWasSetByUser ? tab.title : "")
        field.placeholderString = resolvedTabDisplayTitle(tab)
        field.setAccessibilityLabel("Terminal tab name")
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)

        let alert = NSAlert()
        alert.messageText = "Rename Terminal Tab"
        alert.informativeText = "Leave the name empty to follow the shell and working directory again."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if let title = TerminalTabCustomTitleStore.normalized(field.stringValue) {
            tab.title = title
            tab.titleWasSetByUser = true
            tab.titleWasSetByShell = false
            if let terminalID = tab.brokerTerminalID {
                TerminalTabCustomTitleStore.set(title, for: terminalID)
            }
        } else {
            tab.titleWasSetByUser = false
            tab.titleWasSetByShell = false
            tab.title = URL(fileURLWithPath: LaunchConfiguration.shell).lastPathComponent
            if let terminalID = tab.brokerTerminalID {
                TerminalTabCustomTitleStore.set(nil, for: terminalID)
            }
        }
        #if OUROCODE_GHOSTTY_RENDERER
        tab.synchronizeWorkspaceTitle()
        #endif
        rebuildTabControl()
    }

    private func moveTab(_ tab: LocalTerminalTab, offset: Int) {
        guard let source = tabs.firstIndex(where: { $0 === tab }) else { return }
        let destination = source + offset
        guard tabs.indices.contains(destination) else { return }
        let selectedTab = tabs.indices.contains(selectedIndex) ? tabs[selectedIndex] : tab
        tabs.swapAt(source, destination)
        selectedIndex = tabs.firstIndex(where: { $0 === selectedTab }) ?? destination
        rebuildTabControl()
        scrollSelectedTabToVisible()
    }

    @objc private func showAllTabs(_ sender: NSButton) {
        let picker = TerminalTabPickerViewController()
        picker.onSelect = { [weak self] index in
            guard let self else { return }
            self.allTabsPopover?.performClose(nil)
            self.showTab(at: index)
        }
        picker.update(items: tabPickerItems())

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = picker
        popover.contentSize = picker.preferredContentSize
        allTabsPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        DispatchQueue.main.async { picker.focusSearch() }
    }

    private func configureSymbolButton(_ button: NSButton, symbol: String, label: String) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.isBordered = false
        button.bezelStyle = .inline
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.setAccessibilityHelp("Button")
    }

    private func tabPickerItems() -> [TerminalTabPickerItem] {
        tabs.enumerated().map { index, tab in
            TerminalTabPickerItem(
                index: index,
                title: resolvedTabDisplayTitle(tab),
                path: tab.path,
                selected: index == selectedIndex
            )
        }
    }

    private func tabDisplayTitle(_ tab: LocalTerminalTab) -> String {
        TerminalTabPresentation.displayTitle(
            shellTitle: tab.title,
            shellProvidedTitle: tab.titleWasSetByShell || tab.titleWasSetByUser,
            path: tab.path,
            homePath: FileManager.default.homeDirectoryForCurrentUser.path,
            displaySequence: tab.displaySequence,
            sessionBinding: tab.sessionBinding
        )
    }

    private func resolvedTabDisplayTitle(_ tab: LocalTerminalTab) -> String {
        tabDisplayTitle(tab)
    }

    private func updateResponsiveTabWidths() {
        guard !tabButtons.isEmpty else { return }
        let availableWidth = max(1, tabScrollView.contentSize.width)
        for button in tabButtons {
            let width = TerminalTabWidthPolicy.width(
                preferredWidth: button.preferredWidth,
                availableWidth: availableWidth,
                visibleCount: tabButtons.count
            )
            if abs((button.compactWidthConstraint?.constant ?? 0) - width) > 0.5 {
                button.compactWidthConstraint?.constant = width
            }
        }
    }

    private func layoutTabStripDocument() {
        let contentHeight = max(1, tabScrollView.contentSize.height)
        let intrinsicWidth = max(1, tabStrip.fittingSize.width)
        let documentWidth = max(tabScrollView.contentSize.width, intrinsicWidth)
        let newFrame = NSRect(x: 0, y: 0, width: documentWidth, height: contentHeight)
        guard tabStrip.frame != newFrame else { return }
        tabStrip.frame = newFrame
        tabStrip.needsLayout = true
        tabStrip.layoutSubtreeIfNeeded()
    }

    private func scrollSelectedTabToVisible() {
        guard let displayedIndex = tabButtonIndices.firstIndex(of: selectedIndex),
              tabButtons.indices.contains(displayedIndex) else { return }
        layoutTabStripDocument()
        tabStrip.layoutSubtreeIfNeeded()
        let buttonFrame = tabButtons[displayedIndex].frame.insetBy(dx: -8, dy: 0)
        tabStrip.scrollToVisible(buttonFrame)
        tabScrollView.reflectScrolledClipView(tabScrollView.contentView)
        updateTabOverflowCues()
    }

    private func updateTabOverflowCues() {
        let bounds = tabScrollView.contentView.bounds
        let contentWidth = tabScrollView.documentView?.bounds.width ?? 0
        let visibility = TerminalTabOverflowVisibility.resolve(
            viewportOrigin: bounds.minX,
            viewportWidth: bounds.width,
            contentWidth: contentWidth
        )
        leadingTabOverflowCue.isHidden = !visibility.leading
        trailingTabOverflowCue.isHidden = !visibility.trailing
    }

    private func appendTab(
        initialCommand: String?,
        shellLaunchMode: TerminalShellLaunchMode = .configured,
        brokerTerminal: BrokerTerminalSummary? = nil,
        initialPath: String? = nil,
        restoredTitle: String? = nil,
        restoredPath: String? = nil,
        restoredDisplaySequence: UInt64? = nil
    ) {
        let shellName = URL(
            fileURLWithPath: shellLaunchMode.executable ?? LaunchConfiguration.shell
        ).lastPathComponent
        let displaySequence = restoredDisplaySequence ?? allocateTabDisplaySequence()
        let restoredCustomTitle = brokerTerminal.flatMap {
            TerminalTabCustomTitleStore.title(for: $0.id)
        }
        let tab = LocalTerminalTab(
            displaySequence: displaySequence,
            // A restored broker PTY may have changed directory without OSC 7.
            // Do not show a guessed cwd. The shell identity is always true;
            // an explicit OSC title/directory can replace it later.
            title: restoredCustomTitle ?? restoredTitle ?? shellName,
            path: restoredPath ?? initialPath ?? LaunchConfiguration.displayProjectDirectory,
            pendingInitialCommand: initialCommand,
            shellLaunchMode: shellLaunchMode,
            brokerTerminal: brokerTerminal
        )
        tab.titleWasSetByUser = restoredCustomTitle != nil
        #if OUROCODE_GHOSTTY_RENDERER
        tab.installOneLeafWorkspace(
            occupiedTerminalIDs: Set(tabs.compactMap(\.brokerTerminalID))
        )
        #endif
        tabs.append(tab)
        if let brokerTerminal {
            terminalFontSizes[brokerTerminal.id] = terminalFontSizes[brokerTerminal.id]
                ?? OuroTheme.terminalFontSize
        }
        rebuildTabControl()
    }

    private func allocateTabDisplaySequence() -> UInt64 {
        let sequence = nextTabDisplaySequence
        nextTabDisplaySequence &+= 1
        if nextTabDisplaySequence == 0 { nextTabDisplaySequence = 1 }
        return sequence
    }

    private func rebuildTabControl(preserveFocusedTab: Bool = true) {
        tabProjectionGeneration &+= 1
        let projectionGeneration = tabProjectionGeneration
        // The tab strip uses a bounded set of native buttons for the visible
        // projection. Capture the semantic tab that currently owns keyboard
        // focus before reusing those button slots; otherwise AppKit's AX
        // element would silently change meaning when the projection shifts.
        let focusedTabID = preserveFocusedTab
            ? (view.window?.firstResponder as? TerminalTabButton)?.representedTabID
            : nil
        // Stable chronological order lets spatial memory work. Overflow is a
        // native horizontal scroll, while the searchable picker remains the
        // direct path for large tab sets.
        tabButtonIndices = TerminalTabWindow.indices(
            total: tabs.count,
            selected: selectedIndex
        )
        if let stack = tabTailSpacer.superview as? NSStackView {
            stack.removeArrangedSubview(tabTailSpacer)
            tabTailSpacer.removeFromSuperview()
        }
        while tabButtons.count < tabButtonIndices.count {
            let button = TerminalTabButton(
                title: "",
                target: self,
                action: #selector(selectTab(_:))
            )
            button.isBordered = false
            button.setButtonType(.pushOnPushOff)
            button.setAccessibilityRole(.radioButton)
            button.alignment = .center
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingMiddle
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.compactWidthConstraint = button.widthAnchor.constraint(equalToConstant: 100)
            button.compactHeightConstraint = button.heightAnchor.constraint(equalToConstant: 34)
            button.compactWidthConstraint?.isActive = true
            button.compactHeightConstraint?.isActive = true
            tabStrip.addArrangedSubview(button)
            tabButtons.append(button)
        }
        while tabButtons.count > tabButtonIndices.count {
            let button = tabButtons.removeLast()
            tabStrip.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        for (slot, index) in tabButtonIndices.enumerated() {
            let tab = tabs[index]
            let fullTitle = resolvedTabDisplayTitle(tab)
            let title = shortTitle(fullTitle, maximumLength: 30)
            let button = tabButtons[slot]
            button.representedTabID = tab.id
            button.title = title
            button.tag = index
            button.toolTip = fullTitle
            button.isEnabled = !tab.closing
            button.state = index == selectedIndex ? .on : .off
            button.setAccessibilityValue(index == selectedIndex ? 1 : 0)
            updateTabAccessibility(button, index: index)
            let measured = (title as NSString).size(withAttributes: [.font: button.font as Any]).width
            button.preferredWidth = min(180, max(104, ceil(measured) + 48))
            button.compactWidthConstraint?.constant = TerminalTabWidthPolicy.width(
                preferredWidth: button.preferredWidth,
                availableWidth: max(1, tabScrollView.contentSize.width),
                visibleCount: tabButtonIndices.count
            )
            button.onRequestClose = { [weak self, weak tab] in
                guard let self, let tab,
                      self.tabs.contains(where: { $0 === tab }) else { return }
                self.beginRemoval(of: tab, disposition: .closeView)
            }
            button.onRequestRename = { [weak self, weak tab] in
                guard let self, let tab,
                      self.tabs.contains(where: { $0 === tab }) else { return }
                self.renameTab(tab)
            }
            if index > 0 {
                button.onRequestMoveLeft = { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.moveTab(tab, offset: -1)
                }
            } else {
                button.onRequestMoveLeft = nil
            }
            if index + 1 < tabs.count {
                button.onRequestMoveRight = { [weak self, weak tab] in
                    guard let self, let tab else { return }
                    self.moveTab(tab, offset: 1)
                }
            } else {
                button.onRequestMoveRight = nil
            }
        }
        tabTailSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tabTailSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tabStrip.addArrangedSubview(tabTailSpacer)
        addButton.isEnabled = tabs.count < Self.maximumTabs
        allTabsButton.isEnabled = !tabs.isEmpty
        allTabsButton.title = String(tabs.count)
        allTabsButton.imagePosition = .imageLeading
        allTabsButton.font = OuroTheme.uiFont(size: 11, weight: .medium)
        allTabsButton.toolTip = "Show all \(tabs.count) terminal tabs"
        allTabsButton.setAccessibilityHelp("Search and switch among \(tabs.count) terminal tabs")
        if let picker = allTabsPopover?.contentViewController as? TerminalTabPickerViewController {
            picker.update(items: tabPickerItems())
        }
        layoutTabStripDocument()
        NSAccessibility.post(element: tabStrip, notification: .layoutChanged)
        publishLiveTerminalSessions()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updateAllTabsVisibility()
            self.scrollSelectedTabToVisible()
            guard let targetID = TerminalTabFocusRestoration.target(
                    focusedID: focusedTabID,
                    liveIDs: self.tabs.map(\.id),
                    preserve: preserveFocusedTab,
                    terminalFocusPending: self.pendingTerminalFocusTabID != nil,
                    requestGeneration: projectionGeneration,
                    currentGeneration: self.tabProjectionGeneration
                  ),
                  let focusedIndex = self.tabs.firstIndex(where: { $0.id == targetID }),
                  let focusedSlot = self.tabButtonIndices.firstIndex(of: focusedIndex),
                  self.tabButtons.indices.contains(focusedSlot) else { return }
            // Restore first-responder focus to the newly-created semantic
            // element, preserving keyboard navigation across slot reuse.
            self.view.window?.makeFirstResponder(self.tabButtons[focusedSlot])
        }
    }

    private func updateAllTabsVisibility() {
        let requiredWidth = tabButtons.reduce(CGFloat.zero) { partial, button in
            partial + max(button.bounds.width, button.fittingSize.width)
        }
        // The first nine tabs have direct Command-number shortcuts. Keep the
        // picker visible beyond that boundary even if an early layout pass
        // reports stale button bounds; tabs 10–32 must remain mouse reachable.
        let overflow = tabButtonIndices.count < tabs.count
            || requiredWidth > max(1, tabScrollView.contentSize.width)
        guard allTabsButton.isHidden != !overflow else { return }
        allTabsButton.isHidden = !overflow
        view.needsLayout = true
    }

    private func showTab(at index: Int) {
        guard tabs.indices.contains(index), !tabs[index].closing else { return }
        // A terminal tab is a different work plane. Close the borrowed
        // session surface before handing focus/input back to the PTY so the
        // hidden terminal never remains an accessibility or key-input target.
        sessionWorkspaceContent?.onClose?()
        let tab = tabs[index]
        if desiredMirrorTab !== tab { findPanelController?.reset() }
        selectedIndex = index
        #if OUROCODE_GHOSTTY_RENDERER
        focusedTypographyTerminalID = (try? tab.workspaceTab?.snapshot())?
            .focusedTerminalID ?? tab.brokerTerminalID
        #else
        focusedTypographyTerminalID = tab.brokerTerminalID
        #endif
        pendingTerminalFocusTabID = tab.id
        publishFocusedSessionPane()
        // Selection has an explicit focus destination. Do not let an async
        // preservation callback from this projection override that handoff.
        rebuildTabControl(preserveFocusedTab: false)
        scrollSelectedTabToVisible()
        // Remove the old terminal from the responder path before moving its
        // input lease. This also keeps IME preedit from mutating the retained
        // old scene during the transition.
        if let selectedButton = tabButtons.first(where: { $0.tag == index }) {
            view.window?.makeFirstResponder(selectedButton)
        }
        requestMirrorSwitch(to: tab)
    }

    private func updateTabAccessibility(_ button: NSButton, index: Int) {
        guard tabs.indices.contains(index) else { return }
        let selected = index == selectedIndex
        let shortcut = index < 9 ? ", Command-\(index + 1)" : ""
        button.setAccessibilityLabel(
            "Terminal tab \(index + 1) of \(tabs.count): \(resolvedTabDisplayTitle(tabs[index]))"
        )
        button.setAccessibilityHelp(
            selected ? "Selected terminal tab\(shortcut)" : "Switch to this terminal tab\(shortcut)"
        )
    }

    // MARK: - Single mirror switching

    /// Selection is a UI fact and changes immediately. Broker authority moves
    /// separately through a FIFO detach barrier, so the old scene remains
    /// visible but cannot accept input while the requested tab is recovered.
    private func requestMirrorSwitch(to tab: LocalTerminalTab) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        if let owner = additionalPaneOwnerTab,
           owner !== tab,
           !additionalPaneRuntimes.isEmpty {
            pendingPaneSwitchTab = tab
            beginAdditionalPaneTeardown(owner: owner)
            return
        }
        #endif
        if desiredMirrorTab === tab {
            if mirrorTab === tab, tab.attachment != nil, !transitionInFlight {
                unlockInputIfSupported()
                focusMirrorWhenReady()
            } else if !transitionInFlight {
                advanceMirrorSwitch()
            }
            return
        }
        findPanelController?.reset()
        desiredMirrorTab = tab
        transitionGeneration &+= 1
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        semanticPromptReadiness.reset()
        shellStartupWatchdog?.cancel()
        shellStartupWatchdog = nil
        shellStartupView.dismiss()
        #endif
        inputLocked = true
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        // The tab chrome changes immediately. Hide the old drawable until a
        // frame for the newly selected generation has crossed first-present;
        // an already-scheduled Metal presentation cannot be recalled safely.
        surfaceCoordinator?.view.isHidden = true
        surfaceCoordinator?.setAccessibilityVisible(false)
        if surfaceCoordinator?.invalidateTransition() == true {
            transitionInFlight = false
        }
        #endif
        if let preparingTerminalID, preparingTerminalID != tab.brokerTerminalID {
            broker.cancelAttachmentPreparation(
                terminalID: preparingTerminalID,
                reason: "A different terminal tab was selected."
            )
        }
        guard !transitionInFlight else { return }
        advanceMirrorSwitch()
    }

    private func advanceMirrorSwitch() {
        guard brokerReady,
              let target = desiredMirrorTab,
              tabs.contains(where: { $0 === target }),
              !target.closing else { return }

        if mirrorTab === target, target.attachment != nil {
            unlockInputIfSupported()
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            surfaceCoordinator?.setAccessibilityVisible(true)
            #else
            mirrorTerminal?.isBrokerRunning = target.running
            #endif
            focusMirrorWhenReady()
            return
        }

        // No target may recover until the old subscription and input lease
        // have crossed broker v4's detached FIFO barrier.
        if let owner = mirrorTab, let attachment = owner.attachment {
            transitionInFlight = true
            inputLocked = true
            detachAfterInputBarrier(attachment) { [weak self, weak owner] result in
                guard let self else { return }
                self.transitionInFlight = false
                if let owner {
                    if case let .success(receipt) = result {
                        #if OUROCODE_GHOSTTY_METAL_SURFACE
                        self.releasePromotedPrimaryRuntimeIfMatching(attachment)
                        #endif
                        owner.cursor = max(owner.cursor, receipt.stateSequence)
                    }
                    owner.attachment = nil
                }
                switch result {
                case .success:
                    self.advanceMirrorSwitch()
                case .failure(let error):
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
            }
            return
        }

        // A stale successful commit can exist without becoming the visible
        // mirror if the user clicked again mid-recovery. Revoke it first.
        if let stale = tabs.first(where: { $0 !== mirrorTab && $0.attachment != nil }),
           let attachment = stale.attachment {
            transitionInFlight = true
            detachAfterInputBarrier(attachment) { [weak self, weak stale] result in
                guard let self else { return }
                self.transitionInFlight = false
                stale?.attachment = nil
                if case let .success(receipt) = result {
                    stale?.cursor = max(stale?.cursor ?? 0, receipt.stateSequence)
                }
                switch result {
                case .success:
                    self.advanceMirrorSwitch()
                case .failure(let error):
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
            }
            return
        }

        guard let terminalID = target.brokerTerminalID else {
            guard !target.creating, !target.createRejected else { return }
            startShell(for: target)
            return
        }

        beginTargetRecovery(target, terminalID: terminalID)
    }

    private func beginTargetRecovery(_ tab: LocalTerminalTab, terminalID: String) {
        let operationGeneration = transitionGeneration
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        markGhosttyRecoveryPending(tab: tab, generation: operationGeneration)
        #endif
        guard !tab.attaching else { return }
        tab.attaching = true
        transitionInFlight = true
        preparingTerminalID = terminalID
        broker.prepareAttachment(
            terminalID: terminalID,
            afterStateSequence: tab.hasRenderedState ? tab.cursor : nil
        ) { [weak self, weak tab] result in
            guard let self, let tab else { return }
            self.preparingTerminalID = nil
            switch result {
            case .success(let prepared):
                if tab.removalRequested {
                    tab.attaching = false
                    self.transitionInFlight = false
                    self.broker.abortRecovery(
                        prepared,
                        reason: "Terminal view removal superseded checkpoint import."
                    )
                    self.continueRemoval(of: tab)
                    return
                }
                guard self.desiredMirrorTab === tab,
                      self.transitionGeneration == operationGeneration,
                      self.tabs.contains(where: { $0 === tab }) else {
                    tab.attaching = false
                    self.transitionInFlight = false
                    self.broker.abortRecovery(prepared, reason: "Terminal selection changed before checkpoint import.")
                    self.advanceMirrorSwitch()
                    return
                }
                self.importAndCommit(prepared, for: tab, generation: operationGeneration)
            case .failure(let error):
                tab.attaching = false
                self.transitionInFlight = false
                if tab.removalRequested {
                    self.continueRemoval(of: tab)
                    return
                }
                // Cancellation is expected during rapid tab changes. Only a
                // still-selected failed recovery is user-visible.
                if self.desiredMirrorTab === tab,
                   self.transitionGeneration == operationGeneration {
                    #if OUROCODE_GHOSTTY_METAL_SURFACE
                    self.recoverGhosttyTransition(
                        error, tab: tab, generation: operationGeneration
                    )
                    #else
                    self.presentRecoveryError(error, in: tab)
                    #endif
                } else {
                    self.advanceMirrorSwitch()
                }
            }
        }
    }

    private func focusMirrorWhenReady() {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard let surfaceCoordinator,
              mirrorTab === desiredMirrorTab,
              let mirrorTab,
              let attachment = mirrorTab.attachment else { return }
        // The exact attachment, presented frame, activation generation, and
        // local input lease own this path. OSC 133 is optional presentation
        // metadata; requiring it here would re-lock a valid PTY immediately
        // after `openInputAfterActivation` succeeds.
        guard semanticPromptReadiness.tabID == mirrorTab.id,
              semanticPromptReadiness.generation == transitionGeneration,
              semanticPromptReadiness.activationIssued else {
            inputLocked = true
            return
        }
        surfaceCoordinator.install(in: terminalContainer)
        guard surfaceCoordinator.matchesFirstPresentedAttachment(attachment) else {
            recoverGhosttyTransition(
                BrokerClientError.staleAttachment,
                tab: mirrorTab,
                generation: transitionGeneration
            )
            return
        }
        surfaceCoordinator.view.isHidden = false
        surfaceCoordinator.setAccessibilityVisible(true)
        if inputLocked {
            if surfaceCoordinator.hasInputAuthority {
                do {
                    try surfaceCoordinator.openInputAfterActivation(attachment: attachment)
                    markGhosttyInputReady()
                } catch {
                    recoverGhosttyTransition(
                        error,
                        tab: mirrorTab,
                        generation: transitionGeneration
                    )
                    return
                }
            } else {
                // Semantic observation already issued the one activation
                // request. Wait for its ordered focus/pointer receipts.
                return
            }
        }
        DispatchQueue.main.async { [weak self, weak surfaceCoordinator, weak mirrorTab] in
            guard let self, let surfaceCoordinator, let mirrorTab,
                  self.surfaceCoordinator === surfaceCoordinator,
                  self.desiredMirrorTab === mirrorTab,
                  self.pendingTerminalFocusTabID == nil
                    || self.pendingTerminalFocusTabID == mirrorTab.id,
                  !self.inputLocked else { return }
            guard self.view.window?.makeFirstResponder(surfaceCoordinator.view) == true else { return }
            if self.pendingTerminalFocusTabID == mirrorTab.id {
                self.pendingTerminalFocusTabID = nil
            }
        }
        #else
        guard let terminal = mirrorTerminal,
              mirrorTab === desiredMirrorTab,
              let mirrorTab,
              !inputLocked else { return }
        terminal.exposesAccessibilitySnapshot = true
        if terminal.superview == nil {
            terminalContainer.addSubview(terminal)
            NSLayoutConstraint.activate([
                terminal.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
                terminal.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
                terminal.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
                terminal.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor)
            ])
        }
        try? terminal.setUseMetal(true)
        DispatchQueue.main.async { [weak self, weak terminal, weak mirrorTab] in
            guard let self, let terminal, let mirrorTab,
                  self.mirrorTerminal === terminal,
                  self.desiredMirrorTab === mirrorTab,
                  self.pendingTerminalFocusTabID == nil
                    || self.pendingTerminalFocusTabID == mirrorTab.id,
                  !self.inputLocked else { return }
            guard self.view.window?.makeFirstResponder(terminal) == true else { return }
            if self.pendingTerminalFocusTabID == mirrorTab.id {
                self.pendingTerminalFocusTabID = nil
            }
        }
        #endif
    }

    private func unlockInputIfSupported() {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        inputLocked = !(surfaceCoordinator?.view.inputEnabled ?? false)
        #else
        inputLocked = false
        #endif
    }

    private func makeTerminal() -> AccessibleTerminalView {
        let terminal = AccessibleTerminalView(frame: .zero)
        terminal.font = OuroTheme.monoFont(size: OuroTheme.terminalFontSize)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.nativeForegroundColor = OuroTheme.text
        terminal.nativeBackgroundColor = OuroTheme.canvas
        terminal.caretColor = OuroTheme.mint
        terminal.optionAsMetaKey = false
        terminal.allowMouseReporting = true
        terminal.metalBufferingMode = .perRowPersistent
        terminal.getTerminal().setCursorStyle(.steadyBar)
        return terminal
    }

    private func configureSessionMessageGateway(for hello: BrokerHello) {
        sessionMessageGateway?.stop(reason: "Terminal broker generation changed")
        sessionMessageGateway = nil
        guard let descriptor = hello.sessionMessageGateway else {
            onSessionMessageCapabilityStateChange?(.unavailable(
                reason: "Authenticated session messaging is not advertised by the terminal broker"
            ))
            return
        }
        guard descriptor.brokerGeneration == hello.generation else {
            onSessionMessageCapabilityStateChange?(.unavailable(reason: "Session gateway generation is stale"))
            return
        }
        let gateway = SessionMessageGatewayClientV1(
            descriptor: descriptor,
            expectedBrokerPID: hello.pid
        )
        gateway.onCapabilityStateChange = { [weak self, weak gateway] state in
            guard let self, let gateway, self.sessionMessageGateway === gateway else { return }
            self.onSessionMessageCapabilityStateChange?(state)
        }
        sessionMessageGateway = gateway
        gateway.start()
    }

    private func connectBroker() {
        broker.onReconnect = { [weak self] hello in
            guard let self else { return }
            self.brokerReady = true
            self.transitionGeneration &+= 1
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            self.semanticPromptReadiness.reset()
            self.shellStartupWatchdog?.cancel()
            self.shellStartupWatchdog = nil
            self.shellStartupView.dismiss()
            #endif
            self.brokerGeneration = hello.generation
            self.publishFocusedSessionPane()
            self.configureSessionMessageGateway(for: hello)
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            self.surfaceCoordinator?.invalidateTransition()
            self.surfaceCoordinator?.revokeInputLocally()
            #endif
            if let manifest = hello.manifest,
               manifest.snapshotMagic == "OUROCODE-ANSI-REPLAY",
               manifest.engineSourceCommit == "fixture:vt100-0.15.2" {
                let status = TerminalBrokerPresentationPolicy.compatibilityEngine
                self.compatibilityLabel.stringValue = status.label
                self.compatibilityLabel.toolTip = status.help
                self.compatibilityLabel.setAccessibilityHelp(status.help)
                self.compatibilityLabel.isHidden = true
            } else if hello.manifest != nil {
                self.compatibilityLabel.isHidden = true
            }
            if !self.restoredInitialState {
                self.restoreOrCreateInitialTabs()
            }
            for tab in self.tabs where tab.creationOutcomeUnknown {
                self.reconcileCreateOutcome(
                    for: tab,
                    originalError: BrokerClientError.timedOut("create")
                )
            }
            self.transitionInFlight = false
            self.preparingTerminalID = nil
            self.candidateTerminal = nil
            self.tabs.forEach { $0.attachment = nil; $0.attaching = false }
            self.inputLocked = true
            for tab in self.tabs where tab.removalRequested {
                self.continueRemoval(of: tab)
            }
            self.advanceMirrorSwitch()
        }
        broker.onDisconnect = { [weak self] _ in
            guard let self else { return }
            self.brokerReady = false
            self.transitionGeneration &+= 1
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            self.semanticPromptReadiness.reset()
            self.shellStartupWatchdog?.cancel()
            self.shellStartupWatchdog = nil
            self.shellStartupView.dismiss()
            #endif
            self.transitionInFlight = false
            self.preparingTerminalID = nil
            self.candidateTerminal = nil
            self.brokerGeneration = nil
            self.publishFocusedSessionPane()
            self.sessionMessageGateway?.stop()
            self.sessionMessageGateway = nil
            self.onSessionMessageCapabilityStateChange?(.revoked(reason: "Terminal broker disconnected"))
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            self.surfaceCoordinator?.invalidateTransition()
            self.surfaceCoordinator?.revokeInputLocally()
            self.surfaceCoordinator?.setAccessibilityVisible(false)
            if let promoted = self.promotedPrimaryPaneRuntime {
                promoted.invalidate()
                self.promotedPrimaryPaneRuntime = nil
                self.surfaceCoordinator = nil
            }
            #endif
            self.inputLocked = true
            for tab in self.tabs {
                tab.attachment = nil
                tab.attaching = false
            }
            #if !OUROCODE_GHOSTTY_METAL_SURFACE
            self.mirrorTerminal?.isBrokerRunning = false
            #endif
        }
        broker.onExit = { [weak self] terminalID, _ in
            guard let self,
                  let index = self.tabs.firstIndex(where: { $0.brokerTerminalID == terminalID }) else { return }
            let tab = self.tabs[index]
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            if let attachment = tab.attachment {
                self.releasePromotedPrimaryRuntimeIfMatching(attachment)
            }
            #endif
            tab.running = false
            tab.attachment = nil
            #if !OUROCODE_GHOSTTY_METAL_SURFACE
            if self.mirrorTab === tab { self.mirrorTerminal?.isBrokerRunning = false }
            #endif
        }
        broker.onResyncRequired = { [weak self] terminalID, _ in
            guard let self,
                  let tab = self.tabs.first(where: { $0.brokerTerminalID == terminalID }) else { return }
            // Keep the rendered terminal intact while a new verified recovery
            // is imported offscreen. Only a successful attached_ready swaps it.
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            if let attachment = tab.attachment {
                self.releasePromotedPrimaryRuntimeIfMatching(attachment)
            }
            #endif
            tab.attachment = nil
            tab.attaching = false
            guard self.desiredMirrorTab === tab else { return }
            self.transitionGeneration &+= 1
            self.transitionInFlight = false
            self.preparingTerminalID = nil
            self.inputLocked = true
            #if OUROCODE_GHOSTTY_METAL_SURFACE
            self.surfaceCoordinator?.invalidateTransition()
            self.surfaceCoordinator?.revokeInputLocally()
            self.surfaceCoordinator?.setAccessibilityVisible(false)
            #endif
            self.advanceMirrorSwitch()
        }
        broker.onCompatibilityMode = { [weak self] reason in
            guard let self else { return }
            self.compatibilityLabel.isHidden = false
            self.compatibilityLabel.toolTip = reason
            self.compatibilityLabel.setAccessibilityHelp(reason)
        }
        broker.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.brokerReady = true
                self.restoreOrCreateInitialTabs()
            case .failure(let error):
                self.offerCompatibilityMode(after: error)
            }
        }
    }

    private func offerCompatibilityMode(after v4Error: Error) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        presentBrokerFailure(v4Error)
        #else
        let alert = NSAlert()
        alert.messageText = TerminalBrokerPresentationPolicy.degradedChoiceHeadline
        alert.informativeText = TerminalBrokerPresentationPolicy.degradedChoiceExplanation
        alert.alertStyle = .warning
        // Keep trying stays the default. Silently settling for reduced
        // capability is not a choice a person should make by pressing Return.
        alert.addButton(withTitle: TerminalBrokerPresentationPolicy.keepTryingButtonTitle)
        alert.addButton(withTitle: TerminalBrokerPresentationPolicy.useLimitedEngineButtonTitle)
        guard alert.runModal() == .alertSecondButtonReturn else {
            let status = TerminalBrokerPresentationPolicy.retrying(
                reason: v4Error.localizedDescription
            )
            compatibilityLabel.stringValue = status.label
            compatibilityLabel.toolTip = status.help
            compatibilityLabel.setAccessibilityHelp(status.help)
            compatibilityLabel.isHidden = false
            return
        }
        broker.startLegacyCompatibility { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.brokerReady = true
                self.restoreOrCreateInitialTabs()
            case .failure(let error):
                self.presentBrokerFailure(error)
            }
        }
        #endif
    }

    private func restoreOrCreateInitialTabs() {
        guard !restoredInitialState else { return }
        restoredInitialState = true
        if let initialCommand = LaunchConfiguration.initialCommand {
            appendTab(initialCommand: initialCommand)
            showTab(at: 0)
            return
        }
        broker.list { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let terminals):
                let running = terminals.filter(\.running).prefix(Self.maximumTabs)
                if running.isEmpty {
                    self.appendTab(initialCommand: nil)
                } else {
                    for terminal in running { self.appendTab(initialCommand: nil, brokerTerminal: terminal) }
                }
                self.selectedIndex = 0
                self.showTab(at: 0)
            case .failure(let error):
                self.presentBrokerFailure(error)
            }
        }
    }

    private func presentBrokerFailure(_ error: Error) {
        if tabs.isEmpty { appendTab(initialCommand: nil) }
        let status = TerminalBrokerPresentationPolicy.offline
        compatibilityLabel.stringValue = status.label
        compatibilityLabel.toolTip = status.help
        compatibilityLabel.setAccessibilityHelp(status.help)
        compatibilityLabel.isHidden = false
        NSAccessibility.post(element: compatibilityLabel, notification: .valueChanged)
        #if !OUROCODE_GHOSTTY_METAL_SURFACE
        // The mirror text is the only terminal content a person can see in
        // this state. It names the failure without the transport detail; the
        // exact cause stays in Copy Details.
        let message = "\r\n\(TerminalBrokerPresentationPolicy.failureHeadline)\r\n"
        let tab = tabs[0]
        let terminal = mirrorTerminal ?? makeTerminal()
        terminal.receiveHostData(Array(message.utf8))
        terminal.isBrokerRunning = false
        mirrorTerminal = terminal
        mirrorTab = tab
        bindTerminal(tab, terminal: terminal)
        tab.hasRenderedState = true
        showTab(at: 0)
        #endif
        presentBrokerRecovery(error)
    }

    /// Human recovery surface for a failed terminal start. Rams audit P0 2:
    /// the headline names what the person lost and offers a retry; the socket
    /// path and cause are demoted to a copyable payload they opt into.
    private func presentBrokerRecovery(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = TerminalBrokerPresentationPolicy.failureHeadline
        alert.informativeText = TerminalBrokerPresentationPolicy.failureExplanation
        alert.alertStyle = .warning
        alert.addButton(withTitle: TerminalBrokerPresentationPolicy.retryButtonTitle)
        alert.addButton(withTitle: TerminalBrokerPresentationPolicy.diagnosticsButtonTitle)
        alert.addButton(withTitle: TerminalBrokerPresentationPolicy.dismissButtonTitle)
        let handle: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.retryBrokerStart()
            case .alertSecondButtonReturn:
                self.copyBrokerDiagnostics(error)
                // Copying must not strand the person without a retry, so the
                // same recovery choice is offered again.
                self.presentBrokerRecovery(error)
            default:
                break
            }
        }
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: handle)
        } else {
            handle(alert.runModal())
        }
    }

    private func retryBrokerStart() {
        // `BrokerClient.start` returns early once `started` is true: it only
        // registers this completion, because the client owns its own bounded
        // reconnect cycle. So this reports the next attempt's outcome rather
        // than forcing a fresh connect. When an earlier start threw before
        // connecting, `started` is false and this does begin a new attempt.
        //
        // The restore latch is deliberately left alone. `restoreOrCreateInitialTabs`
        // appends without clearing, so releasing the latch here would duplicate
        // tabs against the placeholder this failure path already created, and
        // would race the `onReconnect` restore that carries the same guard.
        broker.start { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.brokerReady = true
                self.restoreOrCreateInitialTabs()
            case .failure(let error):
                self.presentBrokerFailure(error)
            }
        }
    }

    private func copyBrokerDiagnostics(_ error: Error) {
        let helperName: String
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        helperName = GhosttyRenderDeployment.helperName
        #else
        helperName = "ouro-broker-v4"
        #endif
        let payload = TerminalBrokerPresentationPolicy.diagnostics(
            reason: error.localizedDescription,
            socketPath: broker.socketURL.path,
            helperName: helperName
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    private func bindTerminal(_ tab: LocalTerminalTab, terminal: AccessibleTerminalView) {
        surfaceBindingGeneration &+= 1
        let bindingGeneration = surfaceBindingGeneration
        terminal.onInput = { [weak self, weak tab, weak terminal] bytes in
            guard let self, let tab, let terminal,
                  self.surfaceBindingGeneration == bindingGeneration,
                  self.mirrorTerminal === terminal,
                  self.mirrorTab === tab,
                  self.desiredMirrorTab === tab,
                  !self.inputLocked,
                  let attachment = tab.attachment else { return }
            self.broker.input(Data(bytes), using: attachment) { [weak tab] result in
                if case .failure = result { tab?.attachment = nil }
            }
        }
        terminal.onResize = { [weak self, weak tab, weak terminal] columns, rows in
            guard let self, let tab, let terminal,
                  self.surfaceBindingGeneration == bindingGeneration,
                  self.mirrorTerminal === terminal,
                  self.mirrorTab === tab,
                  self.desiredMirrorTab === tab,
                  !self.inputLocked,
                  let attachment = tab.attachment else { return }
            tab.layoutEpoch &+= 1
            let pixels = terminal.cellSizeInPixels(source: terminal.getTerminal()) ?? (width: 1, height: 1)
            self.broker.resize(
                columns: columns,
                rows: rows,
                cellWidthPixels: max(1, pixels.width),
                cellHeightPixels: max(1, pixels.height),
                layoutEpoch: tab.layoutEpoch,
                using: attachment
            )
        }
        terminal.onTitle = { [weak self, weak tab, weak terminal] title in
            guard let self, let tab, !title.isEmpty,
                  let terminal,
                  self.surfaceBindingGeneration == bindingGeneration,
                  self.mirrorTerminal === terminal,
                  self.mirrorTab === tab,
                  self.tabs.contains(where: { $0 === tab }),
                  !tab.titleWasSetByUser else { return }
            guard tab.title != title || !tab.titleWasSetByShell else { return }
            tab.title = title
            tab.titleWasSetByShell = true
            #if OUROCODE_GHOSTTY_RENDERER
            tab.synchronizeWorkspaceTitle()
            #endif
            self.rebuildTabControl()
        }
        terminal.onDirectory = { [weak self, weak tab, weak terminal] directory in
            guard let self, let tab, let terminal,
                  self.surfaceBindingGeneration == bindingGeneration,
                  self.mirrorTerminal === terminal,
                  self.mirrorTab === tab,
                  let directory else { return }
            let previousPath = tab.path
            let previousTitle = tab.title
            if let path = TerminalShellMetadataPolicy.directory(directory) {
                tab.path = path
            }
            if !tab.titleWasSetByUser, !tab.titleWasSetByShell {
                guard let path = TerminalShellMetadataPolicy.directory(directory) else { return }
                let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
                let location = standardized == home ? "~" : standardized.lastPathComponent
                if !location.isEmpty { tab.title = location }
            }
            if tab.path != previousPath || tab.title != previousTitle {
                #if OUROCODE_GHOSTTY_RENDERER
                tab.synchronizeWorkspaceTitle()
                #endif
                self.rebuildTabControl()
            }
        }
    }

    private func startShell(for tab: LocalTerminalTab) {
        guard brokerReady, !tab.creating, tab.brokerTerminalID == nil else { return }
        tab.createRejected = false
        tab.creating = true
        let shell = tab.shellLaunchMode.executable ?? LaunchConfiguration.shell
        let usesAccountLoginShell = tab.shellLaunchMode == .accountZsh
            || (tab.shellLaunchMode == .configured && LaunchConfiguration.shellOverride == nil)
        var environment = LaunchConfiguration.terminalEnvironment(
            shell: shell,
            accountLoginShell: usesAccountLoginShell
        )
        if tab.shellLaunchMode.installsZshIntegration,
           (tab.shellLaunchMode == .accountZsh || LaunchConfiguration.shellOverride == nil),
           URL(fileURLWithPath: shell).lastPathComponent == "zsh",
           let applicationSupport = FileManager.default.urls(
               for: .applicationSupportDirectory,
               in: .userDomainMask
           ).first {
            var integrationEnvironment = environment
            if let userZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"] {
                integrationEnvironment["ZDOTDIR"] = userZDOTDIR
            }
            if let installation = try? ZshShellIntegration.install(
                inherited: integrationEnvironment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                applicationSupportDirectory: applicationSupport
            ) {
                environment = installation.environment
                tab.requiresSemanticPromptReadiness = true
            }
        }
        let arguments: [String]
        if let launchArguments = tab.shellLaunchMode.arguments {
            arguments = launchArguments
        } else if LaunchConfiguration.shellOverride != nil && tab.shellLaunchMode == .configured {
            // An explicit override applies only to configured/restored tabs;
            // newly-created tabs intentionally remain account zsh sessions.
            arguments = []
        } else {
            // A product session is explicitly interactive and login-scoped so
            // zsh reads the account's .zprofile and .zshrc under Finder launch.
            arguments = ["-l", "-i"]
        }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        // Size the PTY from the laid-out terminal container before zsh prints
        // its first prompt. Creating at the renderer bootstrap's 80×24 and
        // shrinking one frame later made right prompts wrap only on launch.
        let contentInset = OuroTheme.terminalContentInset * 2
        let container = terminalContainer.bounds.size
        let dimensions: (columns: Int, rows: Int)
        if container.width > contentInset + OuroTheme.terminalCellSize.width,
           container.height > contentInset + OuroTheme.terminalCellSize.height {
            dimensions = (
                columns: max(2, Int((container.width - contentInset) / OuroTheme.terminalCellSize.width)),
                rows: max(2, Int((container.height - contentInset) / OuroTheme.terminalCellSize.height))
            )
        } else {
            dimensions = surfaceCoordinator?.dimensions ?? (columns: 80, rows: 24)
        }
        #else
        let model = mirrorTerminal?.getTerminal()
        let dimensions = (columns: model?.cols ?? 80, rows: model?.rows ?? 24)
        #endif
        broker.create(
            createNonce: tab.createNonce,
            program: shell,
            args: arguments,
            // A new tab follows the selected tab's last authoritative OSC 7
            // directory. The broker still validates the path and falls back
            // safely when a retained session points at a deleted directory.
            currentDirectory: TerminalTabLaunchDirectory.resolve(
                inheritedPath: tab.path,
                fallbackPath: LaunchConfiguration.projectDirectory
            ),
            environment: environment,
            columns: dimensions.columns,
            rows: dimensions.rows
        ) { [weak self, weak tab] result in
            guard let self, let tab else { return }
            tab.creating = false
            switch result {
            case .success(let terminal):
                self.adoptCreatedTerminal(terminal, for: tab)
            case .failure(let error):
                if let brokerError = error as? BrokerClientError,
                   case .server = brokerError {
                    // A framed server rejection is definitive: the broker did
                    // not create a PTY. Do not run ambiguity reconciliation or
                    // immediately re-enter create from advanceMirrorSwitch().
                    tab.createRejected = true
                    self.handleDefinitiveCreateFailure(error, for: tab)
                    return
                }
                tab.creationOutcomeUnknown = true
                self.reconcileCreateOutcome(for: tab, originalError: error)
            }
            if self.desiredMirrorTab === tab, !tab.removalRequested {
                self.advanceMirrorSwitch()
            }
        }
    }

    private func handleDefinitiveCreateFailure(_ error: Error, for tab: LocalTerminalTab) {
        tab.creationOutcomeUnknown = false
        guard let failedIndex = tabs.firstIndex(where: { $0 === tab }) else { return }
        if pendingTerminalFocusTabID == tab.id {
            pendingTerminalFocusTabID = nil
        }

        if tabs.count > 1 {
            tabs.remove(at: failedIndex)
            selectedIndex = tab.creationFallbackTabID.flatMap { fallbackID in
                tabs.firstIndex(where: { $0.id == fallbackID })
            } ?? min(failedIndex, tabs.count - 1)
            desiredMirrorTab = tabs[selectedIndex]
            rebuildTabControl()
            scrollSelectedTabToVisible()
        } else {
            // Keep one inert placeholder so the window retains a clear error
            // state without spinning a retry loop.
            selectedIndex = 0
            desiredMirrorTab = tab
            rebuildTabControl()
        }
        NSApp.presentError(error)
        if desiredMirrorTab !== tab { advanceMirrorSwitch() }
    }

    private func adoptCreatedTerminal(_ terminal: BrokerTerminalSummary, for tab: LocalTerminalTab) {
        tab.creationOutcomeUnknown = false
        tab.createRejected = false
        tab.brokerTerminalID = terminal.id
        terminalFontSizes[terminal.id] = typographyTargetFontSize()
        tab.cursor = terminal.cursor
        tab.running = terminal.running
        tab.foregroundProcess = terminal.foregroundProcess
        #if OUROCODE_GHOSTTY_RENDERER
        tab.installOneLeafWorkspace(
            occupiedTerminalIDs: Set(
                tabs.lazy
                    .filter { $0 !== tab }
                    .compactMap(\.brokerTerminalID)
            )
        )
        #endif
        if tab.titleWasSetByUser {
            TerminalTabCustomTitleStore.set(tab.title, for: terminal.id)
        }
        if tab.removalRequested {
            continueRemoval(of: tab)
        } else if desiredMirrorTab === tab {
            advanceMirrorSwitch()
        }
    }

    private func reconcileCreateOutcome(for tab: LocalTerminalTab, originalError: Error) {
        guard !tab.createReconciliationInFlight else { return }
        tab.createReconciliationInFlight = true
        broker.list { [weak self, weak tab] result in
            guard let self, let tab,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            tab.createReconciliationInFlight = false
            switch result {
            case .success(let terminals):
                tab.creationOutcomeUnknown = false
                if let terminal = terminals.first(where: { $0.createNonce == tab.createNonce }) {
                    self.adoptCreatedTerminal(terminal, for: tab)
                } else if tab.removalRequested {
                    self.finishClosing(tab)
                } else {
                    self.presentError(originalError, in: tab)
                }
            case .failure(let reconciliationError):
                tab.closing = tab.removalRequested
                self.rebuildTabControl()
                self.presentError(
                    BrokerClientError.unavailable(
                        "Create outcome is unknown; the tab was preserved for reconciliation. \(reconciliationError.localizedDescription)"
                    ),
                    in: tab
                )
                if self.brokerReady {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak tab] in
                        guard let self, let tab, tab.creationOutcomeUnknown else { return }
                        self.reconcileCreateOutcome(for: tab, originalError: originalError)
                    }
                }
            }
        }
    }

    private func importAndCommit(
        _ prepared: BrokerPreparedRecovery,
        for tab: LocalTerminalTab,
        generation: UInt64
    ) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        importGhosttyAndCommit(prepared, for: tab, generation: generation)
        #else
        guard prepared.manifest.snapshotMagic == "OUROCODE-ANSI-REPLAY",
              prepared.manifest.snapshotFormatVersion == 1,
              prepared.manifest.terminalABIVersion == 1,
              prepared.manifest.engineSourceCommit == "fixture:vt100-0.15.2",
              prepared.manifest.unicodeWidthPolicy == "unicode-width:fixture",
              prepared.manifest.graphicsPolicy == "disabled",
              prepared.manifest.compression == "none" else {
            tab.attaching = false
            transitionInFlight = false
            broker.abortRecovery(
                prepared,
                reason: "Renderer rejected the broker recovery manifest before offscreen import."
            )
            presentRecoveryError(
                BrokerClientError.resyncRequired(
                    "This build can import only the explicitly versioned ANSI compatibility checkpoint. The broker advertised a different terminal engine."
                ),
                in: tab
            )
            return
        }

        let candidate = makeTerminal()
        candidateTerminal = candidate
        candidate.getTerminal().resize(
            cols: prepared.terminal.columns,
            rows: prepared.terminal.rows
        )
        candidate.getTerminal().resetToInitialState()
        candidate.receiveHostData([UInt8](prepared.checkpoint))

        broker.commitAttachment(
            prepared,
            onEvent: { [weak self, weak tab, weak candidate] event in
                guard let self, let tab, let candidate,
                      self.transitionGeneration == generation,
                      (self.candidateTerminal === candidate
                          || (self.mirrorTerminal === candidate && self.mirrorTab === tab)),
                      self.tabs.contains(where: { $0 === tab }) else { return }
                self.apply(event, to: candidate, tab: tab)
            }
        ) { [weak self, weak tab, weak candidate] result in
            guard let self, let tab, let candidate,
                  self.tabs.contains(where: { $0 === tab }) else { return }
            tab.attaching = false
            self.transitionInFlight = false
            if self.candidateTerminal === candidate { self.candidateTerminal = nil }
            switch result {
            case .success(let attachment):
                tab.attachment = attachment
                tab.cursor = attachment.terminal.stateSequence
                tab.running = attachment.terminal.running
                tab.foregroundProcess = attachment.terminal.foregroundProcess
                candidate.isBrokerRunning = tab.running
                if tab.removalRequested {
                    self.continueRemoval(of: tab)
                } else if self.desiredMirrorTab === tab,
                          self.transitionGeneration == generation {
                    attachment.consumeCatchUpEvents { events in
                        for event in events {
                            self.apply(event, to: candidate, tab: tab)
                        }
                    }
                    self.installMirror(for: tab, terminal: candidate)
                    tab.hasRenderedState = true
                    self.inputLocked = false
                    self.sendPendingInitialCommandIfNeeded()
                    self.focusMirrorWhenReady()
                } else {
                    // Selection changed after commit began. The new lease is
                    // valid but must never become a hidden subscription.
                    self.advanceMirrorSwitch()
                }
            case .failure(let error):
                if tab.removalRequested {
                    // A lost commit reply may have installed authority. Do not
                    // remove the view until reconnect has released that lease.
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                    return
                }
                if self.desiredMirrorTab === tab,
                   self.transitionGeneration == generation {
                    self.presentRecoveryError(error, in: tab)
                } else {
                    self.advanceMirrorSwitch()
                }
            }
        }
        #endif
    }

    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private func importGhosttyAndCommit(
        _ prepared: BrokerPreparedRecovery,
        for tab: LocalTerminalTab,
        generation: UInt64
    ) {
        guard let brokerGeneration else {
            failGhosttyRecovery(
                BrokerClientError.staleAttachment,
                prepared: prepared,
                tab: tab,
                generation: generation
            )
            return
        }
        let surface: TerminalSurfaceCoordinator
        do {
            surface = try ensureGhosttySurface(
                brokerGeneration: brokerGeneration,
                prepared: prepared
            )
        } catch {
            failGhosttyRecovery(error, prepared: prepared, tab: tab, generation: generation)
            return
        }

        let surfaceCandidate: TerminalSurfaceCoordinator.Candidate
        do {
            surfaceCandidate = try surface.prepareCandidate(
                brokerGeneration: brokerGeneration,
                prepared: prepared
            )
        } catch {
            failGhosttyRecovery(error, prepared: prepared, tab: tab, generation: generation)
            return
        }

        broker.commitAttachment(
            prepared,
            onEvent: { [weak self, weak tab] event in
                guard let self, let tab,
                      self.tabs.contains(where: { $0 === tab }),
                      tab.attachment != nil else { return }
                do {
                    try surface.applyAttachedEvent(event)
                    tab.cursor = event.sequence
                } catch {
                    tab.attachment = nil
                    self.inputLocked = true
                    surface.setAccessibilityVisible(false)
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
            }
        ) { [weak self, weak tab] result in
            guard let self, let tab,
                  self.tabs.contains(where: { $0 === tab }) else {
                surface.abortCandidate(surfaceCandidate)
                return
            }
            tab.attaching = false
            switch result {
            case .success(let attachment):
                tab.attachment = attachment
                tab.cursor = attachment.terminal.stateSequence
                tab.running = attachment.terminal.running
                tab.foregroundProcess = attachment.terminal.foregroundProcess
                guard self.desiredMirrorTab === tab,
                      self.transitionGeneration == generation,
                      !tab.removalRequested else {
                    surface.abortCandidate(surfaceCandidate)
                    self.transitionInFlight = false
                    if tab.removalRequested {
                        self.continueRemoval(of: tab)
                    } else {
                        self.advanceMirrorSwitch()
                    }
                    return
                }
                do {
                    try attachment.consumeCatchUpEvents { events in
                        for event in events {
                            try surface.applyCandidate(event)
                            tab.cursor = event.sequence
                        }
                    }
                    surface.commitCandidate(
                        surfaceCandidate,
                        attachment: attachment,
                        attachedReadyStateSequence: attachment.terminal.stateSequence,
                        presentationGeneration: generation
                    ) { [weak self, weak tab, weak surface] commitResult in
                        guard let self, let tab, let surface else { return }
                        switch commitResult {
                        case .success:
                            // Authority is attached, but selection, AX, and
                            // any input route stay on the old presentation
                            // until this full frame reaches the drawable.
                            self.transitionInFlight = true
                            self.inputLocked = true
                        case .failure(let error):
                            self.transitionInFlight = false
                            self.inputLocked = true
                            surface.setAccessibilityVisible(false)
                            if self.transitionGeneration == generation,
                               self.desiredMirrorTab === tab {
                                tab.attachment = nil
                                self.recoverGhosttyTransition(
                                    error, tab: tab, generation: generation
                                )
                            }
                        }
                    }
                } catch {
                    surface.abortCandidate(surfaceCandidate)
                    tab.attachment = nil
                    self.transitionInFlight = false
                    self.inputLocked = true
                    surface.setAccessibilityVisible(false)
                    self.recoverGhosttyTransition(
                        error, tab: tab, generation: generation
                    )
                }
            case .failure(let error):
                surface.abortCandidate(surfaceCandidate)
                self.transitionInFlight = false
                if tab.removalRequested {
                    // Commit outcome is ambiguous across transport/projection
                    // failures; reconnect before the close state machine
                    // removes UI or sends a destructive operation.
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                    return
                }
                if self.desiredMirrorTab === tab,
                   self.transitionGeneration == generation {
                    self.recoverGhosttyTransition(
                        error, tab: tab, generation: generation
                    )
                } else {
                    self.advanceMirrorSwitch()
                }
            }
        }
    }

    private func ensureGhosttySurface(
        brokerGeneration: UInt64,
        prepared: BrokerPreparedRecovery
    ) throws -> TerminalSurfaceCoordinator {
        if let surfaceCoordinator { return surfaceCoordinator }
        let surface = try TerminalSurfaceCoordinator(
            brokerGeneration: brokerGeneration,
            bootstrapTerminalID: UUID().uuidString,
            columns: prepared.terminal.columns,
            rows: prepared.terminal.rows,
            backingScale: view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2,
            fontPointSize: terminalFontSizes[prepared.terminal.id]
                ?? OuroTheme.terminalFontSize
        )
        surface.onFocusChange = { [weak self, weak surface] focused in
            guard focused, let self, let surface,
                  self.surfaceCoordinator === surface,
                  let tab = self.mirrorTab,
                  self.tabs.indices.contains(self.selectedIndex),
                  self.tabs[self.selectedIndex] === tab,
                  let terminalID = tab.brokerTerminalID else { return }
            self.focusedTypographyTerminalID = terminalID
            self.synchronizeWorkspaceFocus(terminalID, tab: tab)
        }
        guard surface.bridge.pinNamespace == GhosttyRenderDeployment.pinNamespace,
              surface.bridge.bundledHelperName == GhosttyRenderDeployment.helperName,
              surface.bridge.defaultSocketURL == GhosttyRenderDeployment.socketURL else {
            throw GhosttyRenderBridgeError.manifestMismatch(
                "The surface and broker helper do not share the exact Ghostty pin namespace."
            )
        }
        surface.onFirstPresented = { [weak self, weak surface] presentationGeneration, terminalID, stateSequence, accessibility in
            guard let self, let surface else { return }
            self.completeGhosttyPresentation(
                surface: surface,
                generation: presentationGeneration,
                terminalID: terminalID,
                stateSequence: stateSequence,
                accessibility: accessibility
            )
        }
        surface.onAccessibilityPresented = { [weak self, weak surface] terminalID, _, accessibility in
            guard let self, let surface,
                  self.surfaceCoordinator === surface,
                  self.mirrorTab === self.desiredMirrorTab,
                  self.mirrorTab?.brokerTerminalID == terminalID,
                  let tab = self.mirrorTab,
                  let attachment = tab.attachment,
                  surface.matchesFirstPresentedAttachment(attachment) else { return }
            self.observeGhosttySemanticPrompt(
              surface: surface,
              tab: tab,
              attachment: attachment,
              generation: self.transitionGeneration,
              accessibility: accessibility
            )
        }
        surface.onFailure = { [weak self, weak surface] error in
            guard let self, let surface, self.surfaceCoordinator === surface else { return }
            self.inputLocked = true
            surface.setAccessibilityVisible(false)
            self.broker.reconnectAfterAuthorityFailure(error)
        }
        surface.onInputFailure = { [weak self, weak surface] error in
            guard let self, let surface, self.surfaceCoordinator === surface else { return }
            self.inputLocked = true
            self.compatibilityLabel.stringValue = "Input paused · delivery uncertain"
            self.compatibilityLabel.toolTip = error.localizedDescription
            self.compatibilityLabel.setAccessibilityHelp(error.localizedDescription)
            self.compatibilityLabel.isHidden = false
            NSSound.beep()
            self.broker.reconnectAfterAuthorityFailure(error)
        }
        surface.onInputNotice = { [weak self] error in
            guard let self else { return }
            self.compatibilityLabel.stringValue = "Input not sent"
            self.compatibilityLabel.toolTip = error.localizedDescription
            self.compatibilityLabel.setAccessibilityHelp(error.localizedDescription)
            self.compatibilityLabel.isHidden = false
            NSSound.beep()
        }
        surface.onBell = { [weak self, weak surface] count in
            guard let self, let surface,
                  self.surfaceCoordinator === surface,
                  self.mirrorTab === self.desiredMirrorTab
            else { return }
            surface.view.presentBell(count: count)
        }
        surface.onMetadata = { [weak self, weak surface] terminalID, _, metadata in
            guard let self, let surface,
                  self.surfaceCoordinator === surface,
                  let tab = self.tabs.first(where: { $0.brokerTerminalID == terminalID }),
                  self.desiredMirrorTab === tab else { return }
            let previousTitle = tab.title
            let previousPath = tab.path
            if !tab.titleWasSetByUser {
                if case let .value(rawTitle) = metadata.title,
                   let title = TerminalShellMetadataPolicy.title(rawTitle) {
                    tab.title = title
                    tab.titleWasSetByShell = true
                } else if tab.titleWasSetByShell {
                    tab.title = URL(fileURLWithPath: LaunchConfiguration.shell).lastPathComponent
                    tab.titleWasSetByShell = false
                }
            }
            switch metadata.pwd {
            case let .value(rawPath):
                tab.path = TerminalShellMetadataPolicy.directory(rawPath)
                    ?? LaunchConfiguration.projectDirectory
            case .cleared, .invalid:
                // OSC 7 clear and malformed/remote metadata must not leave a
                // stale authoritative cwd that a later tab could inherit.
                tab.path = LaunchConfiguration.projectDirectory
            }
            if tab.title != previousTitle || tab.path != previousPath {
                tab.synchronizeWorkspaceTitle()
                self.rebuildTabControl()
            }
        }
        surface.onLockedInteraction = { [weak self, weak surface] in
            guard let self, let surface else { return }
            let shouldBeep = self.compatibilityLabel.isHidden
            self.compatibilityLabel.stringValue = "Pointer paused · syncing"
            self.compatibilityLabel.toolTip = "A resize or tab switch is synchronizing pointer geometry. Try again in a moment."
            self.compatibilityLabel.setAccessibilityHelp(self.compatibilityLabel.toolTip)
            self.compatibilityLabel.isHidden = false
            NSAccessibility.post(element: self.compatibilityLabel, notification: .valueChanged)
            NSAccessibility.post(element: self.view, notification: .layoutChanged)
            surface.requestPointerReadyNotice()
            if shouldBeep { NSSound.beep() }
        }
        surface.onPointerReady = { [weak self, weak surface] in
            guard let self, let surface, self.surfaceCoordinator === surface,
                  self.compatibilityLabel.stringValue == "Pointer paused · syncing"
            else { return }
            self.compatibilityLabel.isHidden = true
            NSAccessibility.post(element: self.view, notification: .layoutChanged)
        }
        surface.install(in: terminalContainer)
        surface.setAccessibilityVisible(false)
        surface.view.isHidden = true
        surfaceCoordinator = surface
        compatibilityLabel.stringValue = "Ghostty surface · attaching"
        compatibilityLabel.toolTip = "Input opens after the selected terminal's first full frame and focus receipt. Pointer input and selection remain disabled."
        compatibilityLabel.setAccessibilityHelp(compatibilityLabel.toolTip)
        compatibilityLabel.isHidden = false
        return surface
    }

    private func completeGhosttyPresentation(
        surface: TerminalSurfaceCoordinator,
        generation: UInt64,
        terminalID: String,
        stateSequence: UInt64,
        accessibility: OuroTerminalAccessibilitySnapshot
    ) {
        guard surfaceCoordinator === surface else { return }
        // A Metal frame already queued before a tab switch can still cross
        // the renderer after that switch. Its callback is useful for the old
        // surface only; it must not clear the new transition's in-flight bit
        // or activate input for a stale attachment.
        guard transitionGeneration == generation else { return }
        guard let presentedTab = tabs.first(where: { $0.brokerTerminalID == terminalID }),
              presentedTab.attachment != nil else {
            transitionInFlight = false
            surface.setAccessibilityVisible(false)
            advanceMirrorSwitch()
            return
        }
        guard desiredMirrorTab === presentedTab else { return }
        transitionInFlight = false
        presentedTab.cursor = max(presentedTab.cursor, stateSequence)
        presentedTab.hasRenderedState = true
        mirrorTab = presentedTab
        inputLocked = true
        surface.install(in: terminalContainer)
        surface.view.replaceTerminalAccessibility(accessibility)
        guard let attachment = presentedTab.attachment,
              surface.matchesFirstPresentedAttachment(attachment) else {
            recoverGhosttyTransition(
                BrokerClientError.staleAttachment,
                tab: presentedTab,
                generation: generation
            )
            return
        }
        observeGhosttySemanticPrompt(
          surface: surface,
          tab: presentedTab,
          attachment: attachment,
          generation: generation,
          accessibility: accessibility
        )
    }

    /// Processes the live accessibility projection after the broker-owned
    /// attachment and first frame are verified. Input activation is one-shot
    /// for the exact tab/generation; OSC 133 enriches conversation metadata
    /// when available but never hides or locks an otherwise usable terminal.
    private func observeGhosttySemanticPrompt(
        surface: TerminalSurfaceCoordinator,
        tab: LocalTerminalTab,
        attachment: BrokerAttachment,
        generation: UInt64,
        accessibility: OuroTerminalAccessibilitySnapshot
    ) {
        guard surfaceCoordinator === surface,
              desiredMirrorTab === tab,
              transitionGeneration == generation,
              Self.sameInputAuthority(tab.attachment, attachment) else { return }
        surface.view.replaceTerminalAccessibility(accessibility)
        switch semanticPromptReadiness.observe(
              tabID: tab.id,
              generation: generation,
              hasSemanticPrompt: accessibility.hasSemanticPrompt,
              hasSemanticInput: accessibility.hasSemanticInput
            ) {
            case .ignoredStale:
                return
            case .waiting:
                inputLocked = true
                surface.view.isHidden = true
                surface.setAccessibilityVisible(false)
                let identity = TerminalShellStartupIdentity(tabID: tab.id, generation: generation)
                shellStartupView.present(identity: identity, state: .starting)
                compatibilityLabel.stringValue = "Shell starting…"
                compatibilityLabel.toolTip = "Waiting for zsh to finish setup and publish OSC 133 prompt and input semantics."
                compatibilityLabel.setAccessibilityHelp(compatibilityLabel.toolTip)
                compatibilityLabel.isHidden = false
                NSAccessibility.post(element: compatibilityLabel, notification: .valueChanged)
                return
            case .opened:
                tab.semanticPromptReadinessObserved = tab.semanticPromptReadinessObserved
                  || (accessibility.hasSemanticPrompt && accessibility.hasSemanticInput)
                shellStartupWatchdog?.cancel()
                shellStartupWatchdog = nil
                shellStartupView.dismiss(
                  ifCurrent: TerminalShellStartupIdentity(tabID: tab.id, generation: generation)
                )
                activateGhosttyInput(
                  surface: surface,
                  tab: tab,
                  attachment: attachment,
                  generation: generation
                )
            case .alreadyOpened:
                tab.semanticPromptReadinessObserved = tab.semanticPromptReadinessObserved
                  || (accessibility.hasSemanticPrompt && accessibility.hasSemanticInput)
                shellStartupView.dismiss(
                  ifCurrent: TerminalShellStartupIdentity(tabID: tab.id, generation: generation)
                )
                surface.view.isHidden = false
                surface.setAccessibilityVisible(true)
            }
    }

    private func activateGhosttyInput(
        surface: TerminalSurfaceCoordinator,
        tab: LocalTerminalTab,
        attachment: BrokerAttachment,
        generation: UInt64
    ) {
        surface.activateInput(broker: broker, attachment: attachment) { [weak self, weak surface, weak tab] result in
            guard let self, let surface, let presentedTab = tab,
                  self.surfaceCoordinator === surface,
                  self.transitionGeneration == generation,
                  self.desiredMirrorTab === presentedTab,
                  Self.sameInputAuthority(presentedTab.attachment, attachment) else { return }
            switch result {
            case .success:
                do {
                    try surface.openInputAfterActivation(attachment: attachment)
                    self.shellStartupView.dismiss(
                      ifCurrent: TerminalShellStartupIdentity(
                        tabID: presentedTab.id,
                        generation: generation
                      )
                    )
                    surface.view.isHidden = false
                    surface.setAccessibilityVisible(true)
                    self.markGhosttyInputReady()
                    self.focusMirrorWhenReady()
                } catch {
                    self.inputLocked = true
                    surface.revokeInputLocally()
                }
            case .failure:
                self.inputLocked = true
            }
        }
    }

    private func markGhosttyInputReady() {
        shellStartupWatchdog?.cancel()
        shellStartupWatchdog = nil
        shellStartupView.dismiss()
        inputLocked = false
        // Canonical Ghostty readiness is the normal state, not chrome. Keep
        // this status slot for degraded, attaching, or delivery-uncertain
        // states so the terminal remains the visual center of the window.
        compatibilityLabel.isHidden = true
        sendPendingInitialCommandIfNeeded()
        scheduleGhosttyResize()
        if let mirrorTab { restoreAdditionalPanesIfNeeded(for: mirrorTab) }
    }

    private func sendPendingInitialCommandIfNeeded() {
        guard let tab = mirrorTab,
              let command = tab.pendingInitialCommand,
              !command.isEmpty,
              let attachment = tab.attachment else { return }
        // Clear before delivery. An ambiguous transport failure must never
        // cause a launch command to execute twice after reconnect.
        tab.pendingInitialCommand = nil
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        surfaceCoordinator?.sendCommandLine(command)
        #else
        broker.input(Data((command + "\r").utf8), using: attachment) { _ in }
        #endif
    }

    private func scheduleGhosttyResize(onlyTerminalID: String? = nil) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        pendingResizeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let primaryID = self.tabs.indices.contains(self.selectedIndex)
                ? self.tabs[self.selectedIndex].brokerTerminalID
                : nil
            if onlyTerminalID == nil || onlyTerminalID == primaryID {
                self.resizeSelectedGhosttyTerminal()
            }
            self.resizeAdditionalPaneRuntimes(onlyTerminalID: onlyTerminalID)
        }
        pendingResizeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
        #endif
    }

    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private func resizeSelectedGhosttyTerminal() {
        // Typography is a presentation resize, not an input-authority grant.
        // It must still be able to converge while the first-frame input gate
        // is closed; the exact attachment and the coordinator's pointer
        // barrier below remain the authority checks.
        guard tabs.indices.contains(selectedIndex),
              let surface = surfaceCoordinator,
              let window = view.window else {
            TerminalTypographyRuntimeTrace.record("skip", "missing tab/surface/window")
            return
        }
        let tab = tabs[selectedIndex]
        guard desiredMirrorTab === tab,
              let attachment = tab.attachment,
              let brokerGeneration,
              surface.matchesFirstPresentedAttachment(attachment),
              surface.hasInputAuthority(for: attachment) else {
            TerminalTypographyRuntimeTrace.record(
                "skip",
                "desired=\(desiredMirrorTab === tab) attachment=\(tab.attachment != nil) presented=\(tab.attachment.map(surface.matchesFirstPresentedAttachment) ?? false) authority=\(tab.attachment.map(surface.hasInputAuthority) ?? false)"
            )
            return
        }
        let projectionAuthority = TerminalTypographyProjectionAuthority(
            terminalID: attachment.terminal.id,
            brokerGeneration: brokerGeneration,
            inputEpoch: attachment.inputEpoch,
            leaseID: attachment.leaseID
        )
        let fontPointSize = terminalFontSizes[attachment.terminal.id]
            ?? OuroTheme.terminalFontSize
        let pixelGeometry = TerminalBackingScaleGeometry(
            cellSize: OuroTheme.terminalCellSize(fontSize: fontPointSize),
            backingScale: window.backingScaleFactor
        )
        let inset = OuroTheme.terminalContentInset * 2
        let pointGeometry = pixelGeometry.cellSizeInPoints
        let primaryBounds = workspacePaneContainers[tab.brokerTerminalID ?? ""]?.bounds
            ?? terminalContainer.bounds
        let columns = max(2, Int((primaryBounds.width - inset) / pointGeometry.width))
        let rows = max(2, Int((primaryBounds.height - inset) / pointGeometry.height))
        let request = GhosttyResizeRequest(
            tabID: tab.id,
            projectionAuthority: projectionAuthority,
            baselineLayoutEpoch: tab.layoutEpoch,
            columns: columns,
            rows: rows,
            cellWidthPixels: pixelGeometry.cellWidthPixels,
            cellHeightPixels: pixelGeometry.cellHeightPixels,
            backingScale: pixelGeometry.backingScale,
            fontPointSize: fontPointSize
        )
        TerminalTypographyRuntimeTrace.record(
            "request",
            "font=\(fontPointSize) cols=\(columns) rows=\(rows) cell=\(request.cellWidthPixels)x\(request.cellHeightPixels) epoch=\(request.baselineLayoutEpoch)"
        )
        if let activeGhosttyResize,
           activeGhosttyResize.request.hasSameGeometry(as: request) {
            // The latest layout returned to the in-flight target. Discard any
            // superseded pending target instead of resizing away and back.
            pendingGhosttyResize = nil
            return
        }
        if let pendingGhosttyResize,
           pendingGhosttyResize.hasSameGeometry(as: request) { return }
        let updateKind = tab.typographyProjection.resolve(
            next: request.projectionIdentity,
            authority: projectionAuthority
        )
        if activeGhosttyResize == nil, updateKind != .terminalGeometry {
            if updateKind == .none { return }
            do {
                try surface.updateTypographyWithoutGeometry(
                    geometry: pixelGeometry,
                    fontPointSize: request.fontPointSize
                )
                guard tab.typographyProjection.commitRendererOnly(
                    request.projectionIdentity,
                    authority: projectionAuthority
                ) else {
                    throw BrokerClientError.staleAttachment
                }
                TerminalTypographyRuntimeTrace.record(
                    "font-only",
                    "font=\(request.fontPointSize) cell=\(request.cellWidthPixels)x\(request.cellHeightPixels) broker-resizes=0"
                )
            } catch {
                TerminalTypographyRuntimeTrace.record("font-only-failed", error.localizedDescription)
                // The renderer rejected a font-only mutation. Revoke the
                // projection before retrying so this exact identity can only
                // take the ordered broker geometry path once; rescheduling
                // with the committed projection intact would spin forever.
                tab.typographyProjection.revoke()
                pendingGhosttyResize = request
                driveGhosttyResize()
            }
            return
        }
        pendingGhosttyResize = request
        driveGhosttyResize()
    }

    private func resizeAdditionalPaneRuntimes(onlyTerminalID: String? = nil) {
        guard !additionalPaneRuntimes.isEmpty else { return }
        let scale = view.window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        let inset = OuroTheme.terminalContentInset * 2
        for runtime in additionalPaneRuntimes.values
        where onlyTerminalID == nil || runtime.terminalID == onlyTerminalID {
            let fontPointSize = terminalFontSizes[runtime.terminalID]
                ?? OuroTheme.terminalFontSize
            let cell = OuroTheme.terminalCellSize(fontSize: fontPointSize)
            let bounds = runtime.container.bounds
            runtime.resize(
                broker: broker,
                columns: max(2, Int((bounds.width - inset) / cell.width)),
                rows: max(2, Int((bounds.height - inset) / cell.height)),
                backingScale: scale,
                fontPointSize: fontPointSize
            )
        }
    }

    private func driveGhosttyResize() {
        guard activeGhosttyResize == nil,
              let request = pendingGhosttyResize,
              let surface = surfaceCoordinator else { return }
        pendingGhosttyResize = nil
        let transaction = GhosttyResizeTransaction(request: request)
        activeGhosttyResize = transaction
        TerminalTypographyRuntimeTrace.record("prepare", "epoch=\(request.baselineLayoutEpoch)")
        surface.prepareForResize { [weak self, weak surface] result in
            guard let self, let surface,
                  self.activeGhosttyResize === transaction else { return }
            switch result {
            case .success:
                TerminalTypographyRuntimeTrace.record("prepared", "epoch=\(transaction.request.baselineLayoutEpoch)")
                if let latest = self.pendingGhosttyResize,
                   latest.tabID == transaction.request.tabID {
                    transaction.request = latest
                    self.pendingGhosttyResize = nil
                }
                self.sendPreparedGhosttyResize(transaction, surface: surface)
            case .failure(let error):
                TerminalTypographyRuntimeTrace.record("prepare-failed", error.localizedDescription)
                self.finishGhosttyResize(transaction, result: .failure(error))
            }
        }
    }

    private func sendPreparedGhosttyResize(
        _ transaction: GhosttyResizeTransaction,
        surface: TerminalSurfaceCoordinator
    ) {
        let request = transaction.request
        guard let targetEpoch = TerminalLayoutEpoch.next(after: request.baselineLayoutEpoch) else {
            let error = BrokerClientError.invalidRequest("Terminal layout epoch is exhausted.")
            surface.abortPreparedResize(error)
            finishGhosttyResize(transaction, result: .failure(error))
            return
        }
        transaction.targetLayoutEpoch = targetEpoch
        do {
            try surface.expectPreparedResize(layoutEpoch: targetEpoch) {
                [weak self] result in
                guard let self, self.activeGhosttyResize === transaction else { return }
                switch result {
                case .success:
                    transaction.pointerGateReady = true
                    self.completeGhosttyResizeIfReady(transaction)
                case .failure(let error):
                    self.finishGhosttyResize(transaction, result: .failure(error))
                }
            }
        } catch {
            surface.abortPreparedResize(error)
            finishGhosttyResize(transaction, result: .failure(error))
            return
        }
        TerminalTypographyRuntimeTrace.record(
            "send",
            "targetEpoch=\(targetEpoch) cell=\(request.cellWidthPixels)x\(request.cellHeightPixels)"
        )

        guard tabs.indices.contains(selectedIndex),
              let tab = tabs.first(where: { $0.id == request.tabID }),
              tabs[selectedIndex] === tab,
              desiredMirrorTab === tab,
              let attachment = tab.attachment,
              surface.matchesFirstPresentedAttachment(attachment),
              surface.hasInputAuthority(for: attachment) else {
            surface.abortPreparedResize(BrokerClientError.staleAttachment)
            return
        }
        do {
            // Typography and backing-scale mutations share the pointer barrier;
            // the old coordinate space is already closed and cancelled here.
            try surface.updateTypography(
                geometry: TerminalBackingScaleGeometry(
                    cellSize: OuroTheme.terminalCellSize(
                        fontSize: request.fontPointSize
                    ),
                    backingScale: request.backingScale
                ),
                fontPointSize: request.fontPointSize
            )
        } catch {
            surface.abortPreparedResize(error)
            return
        }

        TerminalTypographyRuntimeTrace.record(
            "broker-requested",
            "epoch=\(targetEpoch) cols=\(request.columns) rows=\(request.rows)"
        )
        broker.resize(
            columns: request.columns,
            rows: request.rows,
            cellWidthPixels: request.cellWidthPixels,
            cellHeightPixels: request.cellHeightPixels,
            layoutEpoch: targetEpoch,
            using: attachment
        ) { [weak self, weak surface, weak tab] result in
            guard let self, let surface,
                  self.activeGhosttyResize === transaction else { return }
            switch result {
            case .success:
                TerminalTypographyRuntimeTrace.record("broker-accepted", "epoch=\(targetEpoch)")
                transaction.brokerAccepted = true
                self.completeGhosttyResizeIfReady(transaction)
            case .failure(let error):
                TerminalTypographyRuntimeTrace.record("broker-failed", error.localizedDescription)
                if Self.resizeFailureIsExplicitlyUncommitted(error) {
                    surface.abortPreparedResize(error)
                } else {
                    // A lost or malformed resize reply may have committed. The
                    // old and new coordinate spaces are now ambiguous, so never
                    // reopen either one on this attachment.
                    self.inputLocked = true
                    tab?.typographyProjection.revoke()
                    surface.revokeInputLocally()
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
            }
        }
    }

    private func completeGhosttyResizeIfReady(_ transaction: GhosttyResizeTransaction) {
        guard transaction.brokerAccepted, transaction.pointerGateReady else { return }
        guard let targetEpoch = transaction.targetLayoutEpoch,
              let tab = tabs.first(where: { $0.id == transaction.request.tabID }),
              let attachment = tab.attachment,
              let brokerGeneration,
              transaction.request.projectionAuthority == TerminalTypographyProjectionAuthority(
                  terminalID: attachment.terminal.id,
                  brokerGeneration: brokerGeneration,
                  inputEpoch: attachment.inputEpoch,
                  leaseID: attachment.leaseID
              ) else {
            let error = BrokerClientError.staleAttachment
            tabForResizeTransaction(transaction)?.typographyProjection.revoke()
            inputLocked = true
            surfaceCoordinator?.revokeInputLocally()
            broker.reconnectAfterAuthorityFailure(error)
            finishGhosttyResize(transaction, result: .failure(error))
            return
        }
        tab.layoutEpoch = targetEpoch
        tab.typographyProjection.commitTerminalGeometry(
            transaction.request.projectionIdentity,
            authority: transaction.request.projectionAuthority
        )
        TerminalTypographyRuntimeTrace.record(
            "geometry-committed",
            "epoch=\(targetEpoch) broker-resizes=1"
        )
        finishGhosttyResize(transaction, result: .success(()))
    }

    private func tabForResizeTransaction(
        _ transaction: GhosttyResizeTransaction
    ) -> LocalTerminalTab? {
        tabs.first(where: { $0.id == transaction.request.tabID })
    }

    private func finishGhosttyResize(
        _ transaction: GhosttyResizeTransaction,
        result: Result<Void, Error>
    ) {
        guard activeGhosttyResize === transaction else { return }
        activeGhosttyResize = nil
        TerminalTypographyRuntimeTrace.record(
            "finished",
            "success=\((try? result.get()) != nil) pending=\(pendingGhosttyResize != nil)"
        )
        driveGhosttyResize()
    }

    private static func resizeFailureIsExplicitlyUncommitted(_ error: Error) -> Bool {
        guard let brokerError = error as? BrokerClientError else { return false }
        switch brokerError {
        case .server, .invalidRequest, .staleAttachment, .unavailable:
            return true
        case .notConnected, .helperMissing, .connectFailed, .disconnected,
             .protocolViolation, .resyncRequired, .timedOut:
            return false
        }
    }
    #endif

    private func failGhosttyRecovery(
        _ error: Error,
        prepared: BrokerPreparedRecovery,
        tab: LocalTerminalTab,
        generation: UInt64
    ) {
        tab.attaching = false
        transitionInFlight = false
        broker.abortRecovery(
            prepared,
            reason: "Ghostty surface rejected the prepared checkpoint: \(error.localizedDescription)"
        )
        if tab.removalRequested {
            continueRemoval(of: tab)
        } else {
            recoverGhosttyTransition(error, tab: tab, generation: generation)
        }
    }

    private func markGhosttyRecoveryPending(tab: LocalTerminalTab, generation: UInt64) {
        guard desiredMirrorTab === tab,
              transitionGeneration == generation,
              tabs.contains(where: { $0 === tab }) else { return }
        semanticPromptReadiness.begin(
          tabID: tab.id,
          generation: generation,
          requiresSemanticPrompt: tab.requiresSemanticPromptReadiness,
          previouslyObserved: tab.semanticPromptReadinessObserved
        )
        inputLocked = true
        shellStartupWatchdog?.cancel()
        shellStartupWatchdog = nil
        if tab.requiresSemanticPromptReadiness && !tab.semanticPromptReadinessObserved {
            shellStartupView.present(
              identity: TerminalShellStartupIdentity(tabID: tab.id, generation: generation),
              state: .starting
            )
            compatibilityLabel.stringValue = "Shell starting…"
            compatibilityLabel.toolTip = "Waiting for zsh to finish setup and publish OSC 133 prompt and input semantics."
            scheduleShellStartupWatchdog(tab: tab, generation: generation)
        } else {
            shellStartupView.dismiss()
            compatibilityLabel.stringValue = "Restoring selected tab…"
            compatibilityLabel.toolTip = "Waiting for a verified Ghostty checkpoint and first presented frame."
        }
        compatibilityLabel.setAccessibilityHelp(compatibilityLabel.toolTip)
        compatibilityLabel.isHidden = false
        NSAccessibility.post(element: compatibilityLabel, notification: .valueChanged)
    }

    private func scheduleShellStartupWatchdog(tab: LocalTerminalTab, generation: UInt64) {
        shellStartupWatchdog?.cancel()
        let work = DispatchWorkItem { [weak self, weak tab] in
            guard let self, let tab,
                  self.desiredMirrorTab === tab,
                  self.transitionGeneration == generation,
                  self.semanticPromptReadiness.tabID == tab.id,
                  self.semanticPromptReadiness.generation == generation,
                  !self.semanticPromptReadiness.semanticRequirementSatisfied,
                  tab.requiresSemanticPromptReadiness,
                  !tab.semanticPromptReadinessObserved else { return }
            self.compatibilityLabel.stringValue = "Shell setup is taking longer than expected"
            self.compatibilityLabel.toolTip = "zsh has not published the optional OSC 133 prompt/input boundary yet. The terminal remains usable; command grouping will improve when it arrives."
            self.compatibilityLabel.setAccessibilityHelp(self.compatibilityLabel.toolTip)
            self.compatibilityLabel.isHidden = false
            let identity = TerminalShellStartupIdentity(tabID: tab.id, generation: generation)
            self.shellStartupView.present(identity: identity, state: .delayed)
            NSAccessibility.post(element: self.compatibilityLabel, notification: .valueChanged)
            let responder = self.view.window?.firstResponder
            let selectedTabButtonOwnsFocus = (responder as? TerminalTabButton)?.representedTabID
              == identity.tabID
            if responder == nil || responder === self.view || selectedTabButtonOwnsFocus {
                self.shellStartupView.focusRecoveryAction(ifCurrent: identity)
            }
        }
        shellStartupWatchdog = work
        DispatchQueue.main.asyncAfter(
          deadline: .now() + TerminalShellStartupPolicy.delayedInterval,
          execute: work
        )
    }

    private func recoverGhosttyTransition(
        _ error: Error,
        tab: LocalTerminalTab,
        generation: UInt64
    ) {
        guard desiredMirrorTab === tab,
              transitionGeneration == generation,
              tabs.contains(where: { $0 === tab }) else {
            advanceMirrorSwitch()
            return
        }
        transitionInFlight = false
        shellStartupWatchdog?.cancel()
        shellStartupWatchdog = nil
        shellStartupView.dismiss(
          ifCurrent: TerminalShellStartupIdentity(tabID: tab.id, generation: generation)
        )
        inputLocked = true
        surfaceCoordinator?.revokeInputLocally()
        surfaceCoordinator?.view.isHidden = true
        surfaceCoordinator?.setAccessibilityVisible(false)
        compatibilityLabel.stringValue = "Tab recovery failed · reconnecting"
        compatibilityLabel.toolTip = error.localizedDescription
        compatibilityLabel.setAccessibilityHelp(error.localizedDescription)
        compatibilityLabel.isHidden = false
        NSAccessibility.post(element: compatibilityLabel, notification: .valueChanged)
        broker.reconnectAfterAuthorityFailure(error)
    }
    #endif

    #if !OUROCODE_GHOSTTY_METAL_SURFACE
    private func sendPendingInitialCommandIfNeeded() {
        guard let tab = mirrorTab,
              let command = tab.pendingInitialCommand,
              !command.isEmpty,
              let attachment = tab.attachment else { return }
        tab.pendingInitialCommand = nil
        broker.input(Data((command + "\r").utf8), using: attachment) { _ in }
    }
    #endif

    private func apply(_ event: BrokerStateEvent, to terminal: AccessibleTerminalView, tab: LocalTerminalTab) {
        switch event {
        case let .ptyBytes(sequence, data):
            tab.cursor = sequence
            terminal.receiveHostData([UInt8](data))
        case let .resize(sequence, columns, rows, _, _, layoutEpoch):
            tab.cursor = sequence
            tab.layoutEpoch = max(tab.layoutEpoch, layoutEpoch)
            terminal.getTerminal().resize(cols: columns, rows: rows)
        }
    }

    private func installMirror(for tab: LocalTerminalTab, terminal replacement: AccessibleTerminalView) {
        if let previous = mirrorTerminal, previous !== replacement {
            previous.exposesAccessibilitySnapshot = false
            previous.onInput = nil
            previous.onResize = nil
            previous.onTitle = nil
            previous.onDirectory = nil
            try? previous.setUseMetal(false)
            previous.removeFromSuperview()
        }
        mirrorTerminal = replacement
        mirrorTab = tab
        bindTerminal(tab, terminal: replacement)
        guard desiredMirrorTab === tab else { return }
        replacement.exposesAccessibilitySnapshot = true
        terminalContainer.addSubview(replacement)
        NSLayoutConstraint.activate([
            replacement.topAnchor.constraint(equalTo: terminalContainer.topAnchor),
            replacement.leadingAnchor.constraint(equalTo: terminalContainer.leadingAnchor),
            replacement.trailingAnchor.constraint(equalTo: terminalContainer.trailingAnchor),
            replacement.bottomAnchor.constraint(equalTo: terminalContainer.bottomAnchor)
        ])
        try? replacement.setUseMetal(true)
        view.window?.makeFirstResponder(replacement)
    }

    private func presentRecoveryError(_ error: Error, in tab: LocalTerminalTab) {
        // Recovery failures must never alter the currently rendered terminal.
        // Surface the resync failure outside the byte stream instead.
        guard tabs.contains(where: { $0 === tab }) else { return }
        NSApp.presentError(error)
    }

    private func presentError(_ error: Error, in tab: LocalTerminalTab) {
        let message = "\r\n[broker] \(error.localizedDescription)\r\n"
        if mirrorTab === tab, let mirrorTerminal {
            mirrorTerminal.receiveHostData(Array(message.utf8))
            tab.hasRenderedState = true
        } else {
            NSApp.presentError(error)
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self,
               event.window === self.view.window,
               self.handleTabShortcut(event) {
                return nil
            }
            guard let self,
                  self.tabs.indices.contains(self.selectedIndex),
                  let window = self.view.window,
                  let terminal = self.mirrorTerminal,
                  self.mirrorTab === self.tabs[self.selectedIndex],
                  self.desiredMirrorTab === self.mirrorTab,
                  !self.inputLocked,
                  window.firstResponder === terminal else { return event }
            let unmodified = event.modifierFlags
                .intersection([.command, .control, .option, .shift]).isEmpty
            if unmodified, terminal.hasMarkedText(), [36, 48, 49, 76].contains(event.keyCode),
               terminal.commitMarkedTextForBoundary() {
                switch event.keyCode {
                case 36, 76: terminal.send([0x0d])
                case 48: terminal.send([0x09])
                case 49: terminal.send([0x20])
                default: break
                }
                return nil
            }
            let returnKey = event.keyCode == 36 || event.keyCode == 76
            let modified = !event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            guard returnKey,
                  !modified,
                  !terminal.hasMarkedText(),
                  terminal.getTerminal().keyboardEnhancementFlags.isEmpty else { return event }
            terminal.send([0x0d])
            return nil
        }
    }

    private func handleTabShortcut(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // AppKit correctly disables the native Split menu items at the
        // production cap. Intercept only the matching key equivalents so a
        // fifth split attempt still gives bounded visible and VoiceOver
        // feedback instead of disappearing silently.
        if TerminalPaneLimitFeedbackPolicy.shouldAnnounce(
            paneCount: currentPaneCount,
            keyCode: event.keyCode,
            modifiers: modifiers
        ) {
            presentPaneLimitReached()
            return true
        }
        if modifiers == [.command, .shift] {
            if event.keyCode == 33 {
                selectPreviousTab(nil)
                return true
            }
            if event.keyCode == 30 {
                selectNextTab(nil)
                return true
            }
        }

        guard event.keyCode == 48,
              modifiers == [.control] || modifiers == [.control, .shift] else { return false }
        if modifiers.contains(.shift) {
            selectPreviousTab(nil)
        } else {
            selectNextTab(nil)
        }
        return true
    }

    private func detachAfterInputBarrier(
        _ attachment: BrokerAttachment,
        completion: @escaping (Result<BrokerDetachReceipt, Error>) -> Void
    ) {
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        guard let surfaceCoordinator else {
            broker.detach(attachment, completion: completion)
            return
        }
        surfaceCoordinator.deactivateInputBeforeDetach(attachment: attachment) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.broker.detach(attachment, completion: completion)
            case .failure(let error):
                completion(.failure(error))
            }
        }
        #else
        broker.detach(attachment, completion: completion)
        #endif
    }

    private static func sameInputAuthority(
        _ current: BrokerAttachment?,
        _ expected: BrokerAttachment
    ) -> Bool {
        guard let current else { return false }
        return current.terminal.id == expected.terminal.id
            && current.inputEpoch == expected.inputEpoch
            && current.leaseID == expected.leaseID
    }

    #if OUROCODE_GHOSTTY_METAL_SURFACE
    private func releasePromotedPrimaryRuntimeIfMatching(
        _ detachedAttachment: BrokerAttachment
    ) {
        guard let runtime = promotedPrimaryPaneRuntime,
              let runtimeAttachment = runtime.attachment,
              Self.sameInputAuthority(runtimeAttachment, detachedAttachment)
        else { return }
        let promotedSurface = runtime.coordinator
        do {
            try runtime.invalidateAfterExternalPrimaryDetach(detachedAttachment)
        } catch {
            runtime.invalidate()
            broker.reconnectAfterAuthorityFailure(error)
        }
        promotedPrimaryPaneRuntime = nil
        if surfaceCoordinator === promotedSurface {
            surfaceCoordinator = nil
        }
    }
    #endif

    private func beginRemoval(
        of tab: LocalTerminalTab,
        disposition: TerminalViewDisposition
    ) {
        guard !tab.closing else { return }
        tab.removalDisposition = disposition
        tab.closing = true
        rebuildTabControl()
        continueRemoval(of: tab)
    }

    /// Drives every removal entry point through one non-destructive-first
    /// state machine. In particular, an attachment that commits after the user
    /// pressed close is detached here instead of becoming a hidden lease.
    private func continueRemoval(of tab: LocalTerminalTab) {
        guard tabs.contains(where: { $0 === tab }),
              let disposition = tab.removalDisposition else { return }
        let snapshot = TerminalViewLifecycleSnapshot(
            hasStableTerminalIdentity: tab.brokerTerminalID != nil,
            hasAttachment: tab.attachment != nil,
            attachmentPreparationInFlight: tab.attaching,
            creationInFlight: tab.creating,
            creationOutcomeUnknown: tab.creationOutcomeUnknown
        )
        switch TerminalViewLifecyclePolicy.nextAction(
            disposition: disposition,
            snapshot: snapshot
        ) {
        case .waitForStableIdentity:
            if tab.creationOutcomeUnknown, !tab.createReconciliationInFlight {
                reconcileCreateOutcome(
                    for: tab,
                    originalError: BrokerClientError.timedOut("create")
                )
            }

        case .cancelAttachmentPreparation:
            guard !tab.attachmentCancellationRequested,
                  let terminalID = tab.brokerTerminalID else { return }
            tab.attachmentCancellationRequested = true
            broker.cancelAttachmentPreparation(
                terminalID: terminalID,
                reason: disposition == .closeView
                    ? "Terminal view is closing; keep its broker session alive."
                    : "Confirmed session termination superseded attachment recovery."
            )

        case .detachAttachment:
            guard !tab.detachingForRemoval,
                  let attachment = tab.attachment else { return }
            tab.detachingForRemoval = true
            inputLocked = true
            transitionInFlight = true
            detachAfterInputBarrier(attachment) { [weak self, weak tab] result in
                guard let self, let tab else { return }
                tab.detachingForRemoval = false
                self.transitionInFlight = false
                tab.attachment = nil
                switch result {
                case .success(let receipt):
                    tab.cursor = max(tab.cursor, receipt.stateSequence)
                    self.continueRemoval(of: tab)
                case .failure(let error):
                    // The local authority is ambiguous. Keep the disabled view
                    // until a new connection proves it has no attachment.
                    self.inputLocked = true
                    self.broker.reconnectAfterAuthorityFailure(error)
                }
            }

        case .removeView:
            finishClosing(tab)

        case .terminateSession:
            guard let terminalID = tab.brokerTerminalID else {
                finishClosing(tab)
                return
            }
            requestTermination(of: tab, terminalID: terminalID)
        }
    }

    private func requestTermination(of tab: LocalTerminalTab, terminalID: String) {
        guard !tab.terminating else { return }
        tab.terminating = true
        broker.terminate(terminalID: terminalID) { [weak self, weak tab] result in
            guard let self, let tab else { return }
            tab.terminating = false
            switch result {
            case .success:
                self.finishClosing(tab)
            case .failure(let error):
                tab.removalDisposition = nil
                tab.closing = false
                self.rebuildTabControl()
                self.presentError(error, in: tab)
                if self.desiredMirrorTab === tab,
                   tab.attachment == nil,
                   tab.brokerTerminalID != nil,
                   tab.running {
                    self.advanceMirrorSwitch()
                }
            }
        }
    }

    private func finishClosing(_ tab: LocalTerminalTab) {
        guard let removingIndex = tabs.firstIndex(where: { $0 === tab }) else { return }
        if tab.removalDisposition == .closeView,
           tab.running,
           let terminalID = tab.brokerTerminalID {
            rememberClosedView(
                ClosedTerminalViewRecord(
                    terminalID: terminalID,
                    displaySequence: tab.displaySequence,
                    title: tab.title,
                    path: tab.path,
                    cursor: tab.cursor,
                    fontPointSize: terminalFontSizes[terminalID] ?? OuroTheme.terminalFontSize
                )
            )
        }
        let wasSelected = removingIndex == selectedIndex
        if desiredMirrorTab === tab || preparingTerminalID == tab.brokerTerminalID {
            transitionGeneration &+= 1
        }
        if preparingTerminalID == tab.brokerTerminalID, let terminalID = tab.brokerTerminalID {
            broker.cancelAttachmentPreparation(terminalID: terminalID, reason: "Terminal tab closed.")
        }
        if mirrorTab === tab, let terminal = mirrorTerminal {
            terminal.exposesAccessibilitySnapshot = false
            try? terminal.setUseMetal(false)
            terminal.removeFromSuperview()
            mirrorTerminal = nil
            mirrorTab = nil
            surfaceBindingGeneration &+= 1
        }
        #if OUROCODE_GHOSTTY_METAL_SURFACE
        if mirrorTab === tab {
            surfaceCoordinator?.setAccessibilityVisible(false)
            mirrorTab = nil
        }
        #endif
        tab.attachment = nil
        tab.running = false
        if let terminalID = tab.brokerTerminalID {
            terminalFontSizes.removeValue(forKey: terminalID)
        }
        tabs.remove(at: removingIndex)

        if tabs.isEmpty {
            rebuildTabControl()
            view.window?.performClose(nil)
            return
        }
        if removingIndex < selectedIndex {
            selectedIndex -= 1
        } else if wasSelected {
            selectedIndex = min(removingIndex, tabs.count - 1)
        }
        showTab(at: selectedIndex)
    }

    private func rememberClosedView(_ record: ClosedTerminalViewRecord) {
        closedViews.removeAll { $0.terminalID == record.terminalID }
        closedViews.append(record)
        if closedViews.count > Self.maximumTabs {
            closedViews.removeFirst(closedViews.count - Self.maximumTabs)
        }
    }

    private func presentClosedViewUnavailable(_ record: ClosedTerminalViewRecord) {
        let alert = NSAlert()
        alert.messageText = "This terminal is no longer running"
        alert.informativeText = "The broker no longer has \(record.title). Its saved view was removed without creating a replacement shell."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func shortTitle(_ value: String, maximumLength: Int = 28) -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maximumLength > 1, clean.count > maximumLength else { return clean }
        return String(clean.prefix(maximumLength - 1)) + "…"
    }

}
