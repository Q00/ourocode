import AppKit

private final class MCPSourceOutlineView: NSOutlineView {
    var semanticNodeIDForSelection: (() -> String?)?
    var onSpace: ((String) -> Void)?
    var onPrimaryAction: ((String) -> Void)?
    private(set) var isHandlingExplicitSelectionInput = false

    override func mouseDown(with event: NSEvent) {
        isHandlingExplicitSelectionInput = true
        defer { isHandlingExplicitSelectionInput = false }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        isHandlingExplicitSelectionInput = true
        defer { isHandlingExplicitSelectionInput = false }
        let actionModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        let hasActionModifier = !event.modifierFlags.intersection(actionModifiers).isEmpty
        switch MCPPrimaryClickActivation.keyAction(
            keyCode: event.keyCode,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            hasActionModifier: hasActionModifier
        ) {
        case .detail:
            guard let nodeID = semanticNodeIDForSelection?() else {
                NSSound.beep()
                return
            }
            onSpace?(nodeID)
        case .primaryAction:
            guard let nodeID = semanticNodeIDForSelection?() else {
                NSSound.beep()
                return
            }
            onPrimaryAction?(nodeID)
        case .system:
            super.keyDown(with: event)
        }
    }

    // Keep the familiar AppKit disclosure glyph while giving it a forgiving
    // pointer target across compact collection and session rows.
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        let frame = super.frameOfOutlineCell(atRow: row)
        guard !frame.isEmpty else { return frame }
        return NSRect(x: max(0, frame.minX - 6), y: frame.minY, width: 28, height: frame.height)
    }
}

private final class MCPRailBackgroundView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        state = .active
        wantsLayer = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        let accessibility = OuroTheme.accessibility
        state = .active
        material = accessibility.reduceTransparency || accessibility.increaseContrast
            ? .windowBackground
            : .sidebar
        blendingMode = accessibility.reduceTransparency ? .withinWindow : .behindWindow
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = accessibility.reduceTransparency
                ? OuroTheme.railCanvas.cgColor
                : NSColor.clear.cgColor
        }
    }
}

private final class MCPSourceRowView: NSTableRowView {
    var onAccessibilityPress: (() -> Bool)?

    override func accessibilityPerformPress() -> Bool {
        onAccessibilityPress?() ?? false
    }

    /// AppKit's synthesized outline-cell element can temporarily report an
    /// empty frame after reloadData(). The semantic action lives on the row,
    /// so expose the row's live full-width screen rect directly.
    override func accessibilityFrame() -> NSRect {
        guard window != nil, !bounds.isEmpty else { return super.accessibilityFrame() }
        return NSAccessibility.screenRect(fromView: self, rect: bounds)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let selectionBounds = bounds.insetBy(dx: 2, dy: 2)
        let selectionPath = NSBezierPath(
            roundedRect: selectionBounds,
            xRadius: 7,
            yRadius: 7
        )
        OuroTheme.railSelection.setFill()
        selectionPath.fill()

        if OuroTheme.accessibility.increaseContrast {
            NSColor.separatorColor.setStroke()
            selectionPath.lineWidth = 1
            selectionPath.stroke()
        }
    }
}

private final class MCPSourceCellView: NSTableCellView {}

struct MCPSelectionDetail {
    let source: String
    let title: String
    let detail: String
    let status: String
    let isLive: Bool
    let terminalEntry: SessionTerminalEntryPresentation
    let note: String
    let recentEvents: MCPRecentEventsPresentation

    init(
        source: String,
        title: String,
        detail: String,
        status: String,
        isLive: Bool,
        terminalEntry: SessionTerminalEntryPresentation = .none,
        note: String? = nil,
        recentEvents: MCPRecentEventsPresentation = .none
    ) {
        self.source = source
        self.title = title
        self.detail = detail
        self.status = status
        self.isLive = isLive
        self.terminalEntry = terminalEntry
        self.recentEvents = recentEvents
        self.note = note ?? (isLive
            ? "Send a message after this agent finishes its current turn."
            : "This session has ended. You can review it, but not send messages.")
    }
}

enum MCPRecentEventsPresentation: Equatable {
    case none
    case loading
    case ready(
        [OuroborosSessionDetailProjectionV0511.Event],
        moreAvailable: Bool,
        runProjection: OuroborosRunProjectionV0516.Snapshot?
    )
    case unavailable(String)
}

private enum MCPBrowserNodeKind {
    case source
    case collection
    case item
    case sessionGroup
    case sessionLeaf
}

private final class MCPBrowserNode: NSObject {
    let id: String
    let kind: MCPBrowserNodeKind
    let title: String
    let detail: String
    let status: String
    let source: String
    let sourceID: String
    let sessionID: String?
    let executionID: String?
    let target: OuroborosSignalTarget?
    let sessionIdentity: OuroborosSessionAttemptIdentityV1?
    let surface: OuroborosSessionSurfaceResolutionV1
    var children: [MCPBrowserNode]

    init(
        id: String,
        kind: MCPBrowserNodeKind,
        title: String,
        detail: String,
        status: String,
        source: String = "Ouroboros",
        sourceID: String = "ouroboros",
        sessionID: String? = nil,
        executionID: String? = nil,
        target: OuroborosSignalTarget? = nil,
        sessionIdentity: OuroborosSessionAttemptIdentityV1? = nil,
        surface: OuroborosSessionSurfaceResolutionV1 = .unbound(.notAdvertised),
        children: [MCPBrowserNode] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.status = status
        self.source = source
        self.sourceID = sourceID
        self.sessionID = sessionID
        self.executionID = executionID
        self.target = target
        self.sessionIdentity = sessionIdentity
        self.surface = surface
        self.children = children
    }

    var canSteer: Bool {
        return SessionLifecycleCapabilityPolicy.isLive(status)
            && target?.modes.contains("after_turn") == true
    }

    var terminalIdentity: OuroborosSessionAttemptIdentityV1? {
        guard case .pty(let binding) = surface else { return nil }
        return binding.identity
    }

    var advertisesLiveTerminal: Bool {
        return SessionLifecycleCapabilityPolicy.isLive(status)
            && terminalIdentity != nil
    }
}

private final class MCPSourceRuntime {
    let registration: MCPSourceRegistration
    let adapter: MCPSourceAdapter
    var catalog: MCPSourceCatalog
    var status = "starting"
    var detail = "Connecting to the local MCP endpoint"
    var isEnabled: Bool
    var projectionTrusted = false
    var lastSuccessfulRefresh: Date?
    var groups: [OuroborosSessionGroup] = []
    var routingState: OuroborosRoutingContractState = .unavailable
    var authenticatedSteeringState: MCPAuthenticatedSteeringState = .unavailable(
        reason: "Authenticated MCP steering is unavailable"
    )

    init(registration: MCPSourceRegistration, adapter: MCPSourceAdapter, isEnabled: Bool) {
        self.registration = registration
        self.adapter = adapter
        self.isEnabled = isEnabled
        self.catalog = MCPSourceCatalog(serverName: registration.displayName)
    }

    var id: String { registration.id.rawValue }
    var displayName: String { registration.displayName }
    var connectorClass: LocalMCPConnectorClass { registration.descriptor?.effectiveConnectorClass ?? .managed }
    var requiredMacOSPermissions: [String] { registration.descriptor?.requiredMacOSPermissions ?? [] }

    var sessionAdapter: MCPSessionSourceAdapter? {
        adapter as? MCPSessionSourceAdapter
    }


    var sessionDetailAdapter: MCPSessionDetailSourceAdapter? {
        adapter as? MCPSessionDetailSourceAdapter
    }
}

final class SessionRailViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate, NSPopoverDelegate, CommandProvider {
    private let privilegedApprovalStore = PrivilegedMCPApprovalStore()
    private let ouroborosClient = OuroborosMCPClient()
    private let sourceEnablementStore = MCPSourceEnablementStore()
    private lazy var sourceRegistry = DesktopMCPSourceRegistry.make(
        ouroborosAdapter: ouroborosClient,
        localDescriptors: ([SharedCUAServiceRuntime.descriptor()] + LocalMCPSourceDescriptorLoader.load())
            .reduce(into: [LocalMCPSourceDescriptor]()) { result, descriptor in
                guard !result.contains(where: { $0.id == descriptor.id }) else { return }
                result.append(descriptor)
            },
        includeCatalogDemoFixture: LaunchConfiguration.mcpV2CatalogFixtureEnabled
    )
    private lazy var sources: [MCPSourceRuntime] = {
        let adapters = sourceRegistry.makeAdapters()
        let ids = adapters.map { $0.registration.id.rawValue }
        let enabled = sourceEnablementStore.enabledSourceIDs(allSourceIDs: ids)
        return adapters.map {
            MCPSourceRuntime(
                registration: $0.registration,
                adapter: $0.adapter,
                isEnabled: enabled.contains($0.registration.id.rawValue)
            )
        }
    }()
    private let outline = MCPSourceOutlineView()
    private let modeSelector = NSSegmentedControl(labels: ["Sessions", "MCP"], trackingMode: .selectOne, target: nil, action: nil)
    private let catalogSearchField = NSSearchField(string: "")
    private let catalogSearchStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let selectedLabel = NSTextField(wrappingLabelWithString: "")
    private let steeringCaption = NSTextField(labelWithString: "Message agent")
    private let steeringExplanation = NSTextField(labelWithString: "Delivered after the current response")
    private let messageField = NSTextField(string: "")
    private let sendButton = NSButton(title: "Queue message", target: nil, action: nil)
    private let receiptLabel = NSTextField(wrappingLabelWithString: "")
    private let readOnlyStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let sourceNotice = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var steeringPanel: NSView?
    private var steeringHeightConstraint: NSLayoutConstraint?
    private var composerControls: [NSView] = []
    private var composerVerticalConstraints: [NSLayoutConstraint] = []
    private var hasSteeringSelection = false
    private var steeringPresentation: SessionComposerPresentation = .hidden
    private var noticeHeightConstraint: NSLayoutConstraint?

    private var roots: [MCPBrowserNode] = []
    private var selectedNodeID: String?
    private var isRebuildingTree = false
    private var isOutlineReloadSettling = false
    private var outlineReloadSettlingGeneration: UInt64 = 0
    private var isApplyingExplicitOutlineSelection = false
    private var selectedTarget: OuroborosSignalTarget?
    private var selectedTerminalStatus: String?
    private var terminalActivationFailureNodeID: String?
    private var terminalActivationFailure: TerminalSessionActivationFailure?
    private var terminalActivationInFlightNodeID: String?
    private var pendingTerminalActivationNodeID: String?
    private var pendingTerminalActivationGeneration: UInt64?
    private var selectedSourceID = "ouroboros"
    private var activeMode: SessionRailMode = .initial
    private var expandedIDsByMode: [SessionRailMode: Set<String>] = [:]
    private var requestGeneration: UInt64 = 0
    private var sidebarExpanded = false
    private var observationActive = false
    private var observationGeneration: UInt64 = 0
    private var selectedDraftKey: String?
    private var selectedFromPaneFocus = false
    private var focusedSessionPane: SessionPaneSteeringFocus?
    private var pendingFocusedPaneLeaf: TerminalSessionLeafIdentity?
    private var draftsByTarget: [String: String] = [:]
    private var receiptsByTarget: [String: String] = [:]
    private var latestSteeringReceiptByTarget: [String: OuroborosSteeringReceipt] = [:]
    private var steeringReceiptLedger = OuroborosSteeringReceiptLedger()
    private var steeringReceiptPolls: [String: DispatchWorkItem] = [:]
    private var steeringReceiptPollGeneration: [String: UInt64] = [:]
    private var steeringReceiptPollsInFlight = Set<String>()
    private var steeringTargetKeyRetention = OuroborosSteeringTargetKeyRetention()
    // This value is updated only by the kernel-authenticated terminal broker
    // gateway path. Public MCP catalog/session metadata never enters it.
    private var messageCapabilityState: SessionMessageCapabilityStateV1 = .unavailable(
        reason: "Waiting for terminal broker verification"
    )
    private var activeSessionActivation: MCPSessionActivation?
    private var liveTerminalSessions: [LiveTerminalSession] = []

    private var sessionDetailState: MCPSessionDetailState = .idle
    private var nextSessionActivationGeneration: UInt64 = 0
    private let detailView = MCPDetailOverlayView(frame: .zero)
    private var detailPopover: NSPopover?
    private var detailVisible = false
    private var detailUsesSessionWorkspace = false
    private weak var detailPreviousFirstResponder: NSResponder?
    private var detailPreviousNodeID: String?
    private var detailFocusGeneration: UInt64 = 0
    private var accessibilityObserver: NSObjectProtocol?
    private var catalogSearchHeightConstraint: NSLayoutConstraint?
    private var catalogSearchStatusHeightConstraint: NSLayoutConstraint?
    private var catalogSearchQuery = ""
    private var catalogSearchRetainedNodeID: String?
    private var catalogSearchWorkItem: DispatchWorkItem?
    private var expansionWithoutTargetRefreshNodeID: String?
    private var nextAgentDiscoveryGeneration: UInt64 = 0
    private var agentDiscoveryIntentByExecutionID: [String: UInt64] = [:]
    private var agentDiscoveryOutcomeByExecutionID: [String: MCPSessionTargetDiscoveryOutcome] = [:]

    let commandProviderID = CommandProviderID(rawValue: "connections")!
    /// The AppDelegate/toolbar owns the actual sidebar visibility transition.
    /// Palette execution asks for it explicitly; search itself never wakes MCP.
    var onRequestOpen: (() -> Void)?
    /// The terminal host owns PTY tabs. The rail only exports verified
    /// server-owned surface bindings and never infers a tab from labels.
    var onSessionTerminalBindingsChange: (([TerminalSessionBinding]) -> Void)?
    var onRequestActivateTerminal: ((
        OuroborosSessionAttemptIdentityV1,
        [TerminalSessionBinding],
        @escaping () -> Bool,
        @escaping (TerminalSessionActivationResult) -> Void
    ) -> Void)?
    /// Headless and completed runs are still real sessions. They borrow the
    /// main work area for their activity/control surface instead of pretending
    /// to be a PTY or being reduced to a small popover.
    var onRequestPresentSessionWorkspace: ((MCPDetailOverlayView) -> Void)?
    var onRequestDismissSessionWorkspace: ((MCPDetailOverlayView) -> Void)?

    func updateLiveTerminalSessions(_ sessions: [LiveTerminalSession]) {
        precondition(Thread.isMainThread)
        guard liveTerminalSessions != sessions else { return }
        liveTerminalSessions = sessions
        if activeMode == .sessions { rebuildTree() }
    }

    var onRequestActivateLiveTerminal: ((UUID) -> Bool)?

    func updateSessionMessageCapability(_ state: SessionMessageCapabilityStateV1) {
        precondition(Thread.isMainThread)
        guard messageCapabilityState != state else { return }
        if messageCapabilityState.authority != state.authority {
            requestGeneration &+= 1
        }
        messageCapabilityState = state
        updateSteeringState()
        if detailVisible, let id = selectedNodeID, let node = findNode(id: id) {
            updateShownDetail(for: node)
        }
    }

    private var primarySource: MCPSourceRuntime { sources[0] }
    private var groups: [OuroborosSessionGroup] { get { primarySource.groups } set { primarySource.groups = newValue } }
    private var catalog: MCPSourceCatalog { get { primarySource.catalog } set { primarySource.catalog = newValue } }
    private var sourceStatus: String { get { primarySource.status } set { primarySource.status = newValue } }
    private var sourceDetail: String { get { primarySource.detail } set { primarySource.detail = newValue } }
    private var projectionTrusted: Bool { get { primarySource.projectionTrusted } set { primarySource.projectionTrusted = newValue } }
    private var lastSuccessfulRefresh: Date? { get { primarySource.lastSuccessfulRefresh } set { primarySource.lastSuccessfulRefresh = newValue } }

    override func loadView() {
        let root = MCPRailBackgroundView()
        view = root

        let brand = NSTextField(labelWithString: "Connections")
        brand.font = OuroTheme.uiFont(size: 15, weight: .semibold)
        brand.textColor = .labelColor
        brand.translatesAutoresizingMaskIntoConstraints = false
        brand.setAccessibilityLabel("Connections")

        modeSelector.translatesAutoresizingMaskIntoConstraints = false
        modeSelector.selectedSegment = activeMode == .mcp ? 1 : 0
        modeSelector.segmentStyle = .texturedRounded
        modeSelector.setAccessibilityLabel("Connection view")
        modeSelector.setAccessibilityHelp("Choose Sessions to browse fanout runs or MCP to browse connected capabilities.")
        modeSelector.target = self
        modeSelector.action = #selector(modeChanged(_:))

        catalogSearchField.placeholderString = "Search MCP"
        catalogSearchField.font = OuroTheme.uiFont(size: 13)
        catalogSearchField.sendsSearchStringImmediately = true
        catalogSearchField.sendsWholeSearchString = false
        catalogSearchField.delegate = self
        catalogSearchField.translatesAutoresizingMaskIntoConstraints = false
        catalogSearchField.setAccessibilityLabel("Search MCP catalog")
        catalogSearchField.setAccessibilityHelp(
            "Filter connected sources, tools, resources, and prompts. Sessions are not filtered."
        )
        catalogSearchField.toolTip = "Search connected MCP capabilities"

        catalogSearchStatusLabel.font = OuroTheme.uiFont(size: 12)
        catalogSearchStatusLabel.textColor = .secondaryLabelColor
        catalogSearchStatusLabel.maximumNumberOfLines = 2
        catalogSearchStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        catalogSearchStatusLabel.setAccessibilityLabel("MCP search status")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowHeight = 42
        outline.intercellSpacing = .zero
        outline.style = .plain
        outline.indentationPerLevel = 16
        outline.autoresizesOutlineColumn = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(handleOutlineClick(_:))
        outline.semanticNodeIDForSelection = { [weak self] in
            self?.semanticNodeIDForSelectedOutlineRow()
        }
        outline.onSpace = { [weak self] nodeID in self?.showDetail(nodeID: nodeID) }
        outline.onPrimaryAction = { [weak self] nodeID in
            self?.performSelectedPrimarySessionAction(nodeID: nodeID)
        }
        outline.setAccessibilityLabel("Connections")
        outline.setAccessibilityHelp(
            "Browse Sessions or MCP. Use Left and Right Arrow to browse. Press Return for the selected primary action and Space for details."
        )

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = outline
        scroll.translatesAutoresizingMaskIntoConstraints = false

        sourceNotice.font = OuroTheme.uiFont(size: 12)
        sourceNotice.textColor = .systemOrange
        sourceNotice.maximumNumberOfLines = 3
        sourceNotice.isHidden = true
        sourceNotice.translatesAutoresizingMaskIntoConstraints = false

        retryButton.bezelStyle = .inline
        retryButton.font = OuroTheme.uiFont(size: 12, weight: .semibold)
        retryButton.target = self
        retryButton.action = #selector(retry(_:))
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        let notice = NSView()
        notice.translatesAutoresizingMaskIntoConstraints = false
        notice.addSubview(sourceNotice)
        notice.addSubview(retryButton)
        let noticeHeight = notice.heightAnchor.constraint(equalToConstant: 0)
        noticeHeightConstraint = noticeHeight

        let steering = makeSteeringPanel()
        steering.isHidden = true
        steeringPanel = steering
        let steeringHeight = steering.heightAnchor.constraint(equalToConstant: 0)
        steeringHeightConstraint = steeringHeight


        detailView.translatesAutoresizingMaskIntoConstraints = true
        detailView.isHidden = true
        detailView.onClose = { [weak self] in self?.hideDetail() }
        detailView.onComposerDraftChange = { [weak self] draft in
            guard let self else { return }
            self.messageField.stringValue = draft
            self.saveCurrentDraft()
            self.updateSteeringState()
        }
        detailView.onComposerSubmit = { [weak self] message in
            guard let self else { return }
            self.messageField.stringValue = message
            self.saveCurrentDraft()
            self.sendSteering(nil)
        }
        detailView.onAgentDraftChange = { [weak self] nodeID, draft in
            self?.saveAgentDraft(nodeID: nodeID, draft: draft)
        }
        detailView.onAgentSubmit = { [weak self] nodeID, message in
            self?.sendAgentSteering(nodeID: nodeID, message: message)
        }
        detailView.onAgentPrimaryAction = { [weak self] nodeID, action in
            self?.performAgentPrimaryAction(nodeID: nodeID, action: action)
        }
        detailView.onAgentDiscoveryRetry = { [weak self] in
            self?.retrySelectedAgentDiscovery()
        }

        root.addSubview(brand)
        root.addSubview(modeSelector)
        root.addSubview(catalogSearchField)
        root.addSubview(catalogSearchStatusLabel)
        root.addSubview(scroll)
        root.addSubview(notice)
        root.addSubview(steering)

        let catalogSearchHeight = catalogSearchField.heightAnchor.constraint(equalToConstant: 28)
        let catalogSearchStatusHeight = catalogSearchStatusLabel.heightAnchor.constraint(equalToConstant: 0)
        catalogSearchHeightConstraint = catalogSearchHeight
        catalogSearchStatusHeightConstraint = catalogSearchStatusHeight

        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 12),
            brand.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            modeSelector.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 9),
            modeSelector.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            modeSelector.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            modeSelector.heightAnchor.constraint(equalToConstant: 28),
            catalogSearchField.topAnchor.constraint(equalTo: modeSelector.bottomAnchor, constant: 8),
            catalogSearchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            catalogSearchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            catalogSearchHeight,
            catalogSearchStatusLabel.topAnchor.constraint(equalTo: catalogSearchField.bottomAnchor, constant: 4),
            catalogSearchStatusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 13),
            catalogSearchStatusLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -13),
            catalogSearchStatusHeight,
            scroll.topAnchor.constraint(equalTo: catalogSearchStatusLabel.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            scroll.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -6),

            notice.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            notice.bottomAnchor.constraint(equalTo: steering.topAnchor, constant: -6),
            noticeHeight,
            sourceNotice.leadingAnchor.constraint(equalTo: notice.leadingAnchor),
            sourceNotice.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -8),
            sourceNotice.centerYAnchor.constraint(equalTo: notice.centerYAnchor),
            retryButton.trailingAnchor.constraint(equalTo: notice.trailingAnchor),
            retryButton.centerYAnchor.constraint(equalTo: notice.centerYAnchor),

            steering.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            steering.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            steering.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10),
            steeringHeight,

        ])

        updateCatalogSearchPresentation()
        rebuildTree()
        applyAccessibilityAppearance()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAccessibilityAppearance()
        }
    }

    deinit {
        catalogSearchWorkItem?.cancel()
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        guard detailVisible else {
            super.cancelOperation(sender)
            return
        }
        hideDetail()
        view.window?.makeFirstResponder(outline)
    }

    func setSidebarExpanded(_ expanded: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard sidebarExpanded != expanded else { return }
        sidebarExpanded = expanded
        reconcileSourceObservation()
    }

    private func setSourceDisclosureExpanded(_ expanded: Bool) {
        // Disclosure affects presentation only. Observation is scoped to rail
        // visibility so switching modes cannot silently stop session polling.
    }

    private func reconcileSourceObservation() {
        // Observation follows the visibility of the navigator, not the
        // currently selected mode or an incidental disclosure triangle. A
        // Goose-style mode switch must not stop the fanout feed underneath it.
        let shouldObserve = sidebarExpanded
        guard observationActive != shouldObserve else { return }
        observationActive = shouldObserve
        if shouldObserve {
            _ = view
            observationGeneration &+= 1
            let generation = observationGeneration
            bindClient(generation: generation)
            for runtime in sources {
                guard runtime.isEnabled else {
                    runtime.status = "disabled"
                    runtime.detail = "Disabled · enable to connect"
                    runtime.projectionTrusted = false
                    runtime.adapter.stop()
                    continue
                }
                runtime.status = "starting"
                runtime.detail = "Refreshing while Connections is open"
                runtime.projectionTrusted = false
                runtime.adapter.resumeObservation()
            }
            requestGeneration += 1
            saveCurrentDraft()
            selectedTarget = nil
            selectedDraftKey = nil
            setSteeringVisible(false)
            hideNotice()
            rebuildTree()
        } else {
            deactivateSessionDetail()
            observationGeneration &+= 1
            requestGeneration += 1
            pendingTerminalActivationNodeID = nil
            pendingTerminalActivationGeneration = nil
            sources.forEach { runtime in
                runtime.adapter.pauseObservation()
                runtime.status = "paused"
                runtime.detail = "Observation resumes when Sessions opens"
                runtime.projectionTrusted = false
            }
            selectedTarget = nil
            selectedDraftKey = nil
            setSteeringVisible(false)
            hideDetail()
        }
    }

    func stopSources() {
        deactivateSessionDetail()
        sources.forEach { $0.adapter.stop() }
    }

    @objc func focusBrowser(_ sender: Any?) {
        view.window?.makeFirstResponder(outline)
        if outline.selectedRow < 0, outline.numberOfRows > 0 {
            outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    /// Keyboard destination for the exact agent represented by the focused
    /// terminal pane. The shortcut never writes into the PTY input stream.
    @objc func focusSteeringComposer(_ sender: Any?) {
        let runtime = sources.first(where: { $0.id == selectedSourceID })
        let outcome = SessionFocusedAgentComposerPolicy.resolve(
            hasFocusedBinding: focusedSessionPane != nil,
            focusedIdentityMatchesTarget: focusedSessionPane?.leaf == selectedTarget?.sessionIdentity
                && selectedTarget != nil,
            advertisesAfterTurn: selectedTarget?.modes.contains("after_turn") == true,
            projectionTrusted: runtime?.projectionTrusted == true,
            authenticatedTransportReady: runtime.map(hasVerifiedSteeringAuthority(for:)) == true
        )
        guard outcome == .focusComposer,
              steeringPresentation == .verifiedComposer,
              messageField.isEnabled else {
            let reason: String
            if case .unavailable(let message) = outcome {
                reason = message
            } else {
                reason = "The focused agent composer is not available"
            }
            showNotice(reason)
            sourceNotice.setAccessibilityLabel("Focused agent status")
            NSAccessibility.post(
                element: sourceNotice,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: reason,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
            NSSound.beep()
            return
        }
        hideNotice()
        view.window?.makeFirstResponder(messageField)
        NSAccessibility.post(element: messageField, notification: .focusedUIElementChanged)
    }

    func commandSnapshot(limit: Int) -> [CommandDescriptor] {
        let provider = commandProviderID
        let commands = sources.flatMap { runtime -> [CommandDescriptor] in
            let sourceTitle = runtime.displayName
            var sourceCommands = [
                CommandDescriptor(
                    id: CommandID(provider: provider, local: "source:\(runtime.id):sessions"),
                    title: "Open \(sourceTitle) Sessions",
                    subtitle: runtime.groups.isEmpty ? "No cached sessions" : "Cached fanout sessions",
                    keywords: ["mcp", "ouroboros", "agents", runtime.id],
                    section: .connections,
                    symbolName: "person.3",
                    rankHint: 70
                ),
                CommandDescriptor(
                    id: CommandID(provider: provider, local: "source:\(runtime.id):mcp"),
                    title: "Open \(sourceTitle) MCP",
                    subtitle: runtime.catalog.capabilities.isEmpty ? "MCP v2 capabilities" : runtime.catalog.capabilities.joined(separator: ", "),
                    keywords: ["tools", "resources", "prompts", "mcp v2", runtime.id],
                    section: .connections,
                    symbolName: "point.3.connected.trianglepath.dotted",
                    rankHint: 45
                ),
            ]
            sourceCommands.append(contentsOf: runtime.groups.map { group in
                CommandDescriptor(
                    id: CommandID(provider: provider, local: "session:\(runtime.id):\(group.sessionID)"),
                    title: group.title,
                    subtitle: "\(runtime.displayName) · \(group.status) · \(group.activity)",
                    keywords: ["session", "terminal", group.sessionID, group.executionID, group.suggestedTier ?? ""],
                    section: .sessions,
                    symbolName: group.status.lowercased() == "running" ? "rectangle.stack.fill" : "clock",
                    rankHint: group.status.lowercased() == "running" ? 110 : 10
                )
            })
            return sourceCommands
        }
        return Array(commands.prefix(max(0, limit)))
    }

    func perform(commandID: CommandID) -> CommandExecutionResult {
        guard commandID.provider == commandProviderID else {
            return .unavailable("The connections command is no longer available.")
        }
        let parts = commandID.local.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return .unavailable("That connection command is malformed.") }
        let sourceID = parts[1]
        guard sources.contains(where: { $0.id == sourceID }) else {
            return .unavailable("That MCP source is no longer connected.")
        }
        onRequestOpen?()
        if parts[0] == "source" {
            captureExpandedIDs(for: activeMode)
            let nextMode: SessionRailMode = parts[2] == "mcp" ? .mcp : .sessions
            clearCatalogSearchIfNeeded(from: activeMode, to: nextMode)
            activeMode = nextMode
            modeSelector.selectedSegment = activeMode == .mcp ? 1 : 0
            selectedNodeID = nil
            pendingTerminalActivationNodeID = nil
            pendingTerminalActivationGeneration = nil
            updateCatalogSearchPresentation()
            rebuildTree(captureCurrentExpansion: false)
            focusBrowser(nil)
            return .executed
        }
        guard parts[0] == "session", parts.count == 3 else {
            return .unavailable("That MCP command is no longer available.")
        }
        let sessionID = parts[2]
        guard let runtime = sources.first(where: { $0.id == sourceID }),
              runtime.groups.contains(where: { $0.sessionID == sessionID }) else {
            return .unavailable("That Ouroboros session is no longer cached.")
        }
        captureExpandedIDs(for: activeMode)
        clearCatalogSearchIfNeeded(from: activeMode, to: .sessions)
        activeMode = .sessions
        modeSelector.selectedSegment = 0
        updateCatalogSearchPresentation()
        selectedNodeID = "session:\(sourceID):\(sessionID)"
        rebuildTree(captureCurrentExpansion: false)
        if let node = findNode(id: selectedNodeID ?? ""), outline.row(forItem: node) >= 0 {
            let row = outline.row(forItem: node)
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            inspectSelection(node, announce: true)
            if let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) {
                showDetail(for: node, anchoredTo: cell)
            }
        }
        return .executed
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? MCPBrowserNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? MCPBrowserNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? MCPBrowserNode else { return false }
        if activeMode == .sessions, node.kind == .sessionGroup, node.sourceID != "terminal" {
            // Ouroboros agents render in the central multiplexer. Live
            // terminal-agent groups instead expand here so the user can drill
            // directly into an exact Claude/Codex child PTY.
            return false
        }
        if activeMode == .sessions, node.sourceID == "terminal" {
            return !node.children.isEmpty
        }
        let runtime = sources.first(where: { $0.id == node.sourceID })
        let isLazyCatalogCollection = node.kind == .collection
            && (node.title == "Tools" || node.title == "Resources" || node.title == "Prompts")
        return SessionRailExpandablePolicy.resolve(
            hasChildren: !node.children.isEmpty,
            isLazyCatalogCollection: isLazyCatalogCollection,
            isSessionGroup: node.kind == .sessionGroup,
            isProjectionTrusted: runtime?.projectionTrusted == true,
            isLive: SessionLifecycleCapabilityPolicy.isLive(node.status),
            hasExecutionIdentity: node.executionID != nil,
            hasSessionAdapter: runtime?.sessionAdapter != nil
        )
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? MCPBrowserNode else { return }
        // `reloadData` tears down and reconstructs AppKit disclosure state.
        // Those synthetic notifications are restoration, not human intent:
        // they must not start target discovery or mutate sidebar preference.
        guard !isRebuildingTree, !isOutlineReloadSettling else { return }
        if node.kind == .source {
            setSourceDisclosureExpanded(true)
        }
        if node.kind == .collection, node.id == "mode:sessions" {
            setSourceDisclosureExpanded(true)
        }
        if expansionWithoutTargetRefreshNodeID == node.id {
            expansionWithoutTargetRefreshNodeID = nil
        } else {
            requestExpandedContent(for: node)
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? MCPBrowserNode else { return }
        // A polling rebuild can briefly report the selected child as hidden.
        // Clearing semantic selection here closes the very multiplexer the
        // user is steering. Only an explicit, settled collapse may do that.
        guard !isRebuildingTree, !isOutlineReloadSettling else { return }
        if node.kind == .source {
            setSourceDisclosureExpanded(false)
        }
        if node.kind == .collection, node.id == "mode:sessions" {
            setSourceDisclosureExpanded(false)
        }
        guard let selectedNodeID,
              let selectedNode = findNode(id: selectedNodeID),
              outline.row(forItem: selectedNode) < 0 else { return }
        outline.deselectAll(nil)
        clearSelection()
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let node = item as? MCPBrowserNode else { return 42 }
        return rowPresentation(for: node).height
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        guard let node = item as? MCPBrowserNode else { return MCPSourceRowView() }
        let rowView = MCPSourceRowView()
        if isSessionDestination(node) {
            rowView.setAccessibilityElement(true)
            rowView.setAccessibilityRole(.button)
            rowView.setAccessibilityIdentifier(
                SessionRailSemanticActivation.accessibilityIdentifier(nodeID: node.id)
            )
            rowView.setAccessibilityLabel("\(node.title), \(rowState(node)), \(rowDetail(node))")
            rowView.setAccessibilityHelp(rowAccessibilityHelp(node))
            rowView.onAccessibilityPress = { [weak self] in
                self?.performAccessibilityPrimaryAction(nodeID: node.id) ?? false
            }
        }
        return rowView
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? MCPBrowserNode else { return nil }
        let cell = MCPSourceCellView()
        let title = NSTextField(labelWithString: visualTitle(node))
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let isPrivilegedSource = node.kind == .source && runtime.connectorClass == .privileged
        let detail = NSTextField(labelWithString: isPrivilegedSource
            ? "\(rowState(node)) · Privileged"
            : compactRowDetail(node))
        let stateLabel = rowState(node)
        let state = NSTextField(labelWithString: stateLabel)
        let color = stateLabel.hasSuffix("›")
            ? .controlAccentColor
            : stateColor(stateLabel.lowercased())

        let titleWeight: NSFont.Weight
        switch node.kind {
        case .source:
            titleWeight = .semibold
        case .collection, .sessionGroup:
            titleWeight = .medium
        case .item, .sessionLeaf:
            titleWeight = .regular
        }
        title.font = OuroTheme.uiFont(size: node.kind == .source ? 14 : 13, weight: titleWeight)
        title.textColor = .labelColor
        let presentation = rowPresentation(for: node)
        title.lineBreakMode = presentation.titleTruncation
        title.translatesAutoresizingMaskIntoConstraints = false
        detail.font = OuroTheme.uiFont(size: 12.5)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        state.font = OuroTheme.uiFont(size: 11.5, weight: stateLabel.hasSuffix("›") ? .semibold : .medium)
        state.textColor = color
        state.translatesAutoresizingMaskIntoConstraints = false
        SessionRailPresentationPolicy.configureTextPriority(title: title, state: state)
        SessionRailPresentationPolicy.configureTooltips(
            title: title,
            detail: detail,
            fullTitle: node.title,
            fullDetail: rowDetail(node)
        )

        title.setAccessibilityElement(false)
        detail.setAccessibilityElement(false)
        state.setAccessibilityElement(false)

        cell.addSubview(title)
        cell.addSubview(detail)
        cell.addSubview(state)
        cell.textField = title
        let trailingAnchor: NSLayoutXAxisAnchor
        if node.kind == .source {
            let toggle = NSSwitch()
            toggle.controlSize = .small
            toggle.state = runtime.isEnabled ? .on : .off
            toggle.identifier = NSUserInterfaceItemIdentifier(runtime.id)
            toggle.target = self
            toggle.action = #selector(sourceToggleChanged(_:))
            toggle.setAccessibilityLabel("Enable \(runtime.displayName) MCP")
            toggle.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(toggle)
            if runtime.connectorClass == .privileged {
                let scope = NSPopUpButton(frame: .zero, pullsDown: false)
                scope.addItems(withTitles: ["Ask", "Session", "Workspace", "Deny"])
                let current = privilegedApprovalStore.scope(sourceID: runtime.id)
                scope.selectItem(at: [.ask, .session, .workspace, .denied].firstIndex(of: current) ?? 0)
                scope.identifier = NSUserInterfaceItemIdentifier(runtime.id)
                scope.target = self
                scope.action = #selector(privilegedScopeChanged(_:))
                scope.controlSize = .mini
                scope.setAccessibilityLabel("Computer Use approval scope")
                scope.translatesAutoresizingMaskIntoConstraints = false
                cell.addSubview(scope)
                NSLayoutConstraint.activate([
                    toggle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                    toggle.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                    scope.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                    scope.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -4),
                    scope.widthAnchor.constraint(equalToConstant: 88),
                ])
                trailingAnchor = scope.leadingAnchor
            } else {
                NSLayoutConstraint.activate([
                    toggle.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -5),
                    toggle.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                ])
                trailingAnchor = toggle.leadingAnchor
            }
        } else {
            trailingAnchor = cell.trailingAnchor
        }
        if isPrivilegedSource {
            state.isHidden = true
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 5),
                title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -58),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
                detail.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -6),
            ])
        } else if presentation.usesTwoLines {
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 6),
                title.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                state.firstBaselineAnchor.constraint(equalTo: detail.firstBaselineAnchor),
                detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
                detail.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -6),
                detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1)
            ])
        } else {
            detail.isHidden = true
            NSLayoutConstraint.activate([
                title.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 3),
                title.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                title.trailingAnchor.constraint(lessThanOrEqualTo: state.leadingAnchor, constant: -6),
                state.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
                state.firstBaselineAnchor.constraint(equalTo: title.firstBaselineAnchor)
            ])
        }
        if isSessionDestination(node) {
            // The full-width row above is the one semantic target. Keeping a
            // second button here creates duplicate AX children with different
            // lifetimes and lets hit-testing activate the wrong outline item.
            cell.setAccessibilityElement(false)
        } else {
            // Sources and collections keep native outline semantics. Exposing
            // every catalog row as a button without a press action strands
            // VoiceOver users on controls that announce but cannot activate.
            cell.setAccessibilityElement(true)
            cell.setAccessibilityRole(.staticText)
            cell.setAccessibilityLabel("\(node.title), \(rowState(node)), \(rowDetail(node))")
            cell.setAccessibilityHelp(rowAccessibilityHelp(node))
        }
        return cell
    }

    private func isSessionDestination(_ node: MCPBrowserNode) -> Bool {
        isSessionsModeLink(node)
            || node.sourceID == "terminal"
            || node.kind == .sessionGroup
            || node.kind == .sessionLeaf
    }

    private func resolveCurrentActivationNode(nodeID: String) -> MCPBrowserNode? {
        var currentNode: MCPBrowserNode?
        let resolvedID = SessionRailSemanticActivation.resolve(
            requestedNodeID: nodeID,
            currentNodeIDExists: { [weak self] candidateID in
                currentNode = self?.findNode(id: candidateID)
                return currentNode != nil
            }
        )
        guard resolvedID == nodeID else { return nil }
        return currentNode
    }

    private func semanticNodeIDForSelectedOutlineRow() -> String? {
        let row = outline.selectedRow
        guard row >= 0,
              let node = outline.item(atRow: row) as? MCPBrowserNode else { return nil }
        return node.id
    }

    private func performAccessibilityPrimaryAction(nodeID: String) -> Bool {
        guard let node = resolveCurrentActivationNode(nodeID: nodeID) else { return false }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return false }
        isApplyingExplicitOutlineSelection = true
        defer { isApplyingExplicitOutlineSelection = false }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        inspectSelectionIfNeeded(node)
        performSelectedPrimarySessionAction(nodeID: node.id)
        return true
    }

    private func rowPresentation(for node: MCPBrowserNode) -> SessionRailRowPresentation {
        if isSessionsModeLink(node) {
            return SessionRailRowPresentation(
                height: 50,
                usesTwoLines: true,
                titleTruncation: .byTruncatingTail
            )
        }
        if node.kind == .source,
           let runtime = sources.first(where: { $0.id == node.sourceID }),
           runtime.connectorClass == .privileged {
            return SessionRailRowPresentation(
                height: 58,
                usesTwoLines: true,
                titleTruncation: .byTruncatingTail
            )
        }
        let role: SessionRailRowRole
        switch node.kind {
        case .source: role = .source
        case .collection: role = .collection
        case .sessionGroup: role = .sessionGroup
        case .sessionLeaf: role = .sessionLeaf
        case .item: role = .item
        }
        return SessionRailPresentationPolicy.row(
            role,
            emptySessionsCollection: node.kind == .collection
                && node.id.hasSuffix(":sessions:empty")
                && node.children.isEmpty
        )
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        switch SessionRailDetailFocusRestoration.outlineSelectionChangeResolution(
            isRebuildingTree: isRebuildingTree,
            isReloadSettling: isOutlineReloadSettling,
            isSessionWorkspaceVisible: detailVisible && detailUsesSessionWorkspace,
            hasRetainedSemanticSelection: selectedNodeID != nil,
            hasExplicitUserIntent: isApplyingExplicitOutlineSelection
                || outline.isHandlingExplicitSelectionInput
        ) {
        case .ignore:
            return
        case .restoreSemanticSelection:
            restoreSemanticOutlineSelection()
            return
        case .apply:
            break
        }
        // A workspace owns the active selection until an explicit row action
        // or Back. AppKit can emit a delayed selection notification after
        // `reloadData()` where the old row index temporarily points at a
        // collection (or another session) in the rebuilt tree. Applying that
        // incidental node would dismiss the workspace just as Activity
        // finishes loading. Real pointer/accessibility actions still flow
        // through `handleOutlineClick` / `performAccessibilityPrimaryAction`,
        // which inspect their exact semantic node directly.
        let row = outline.selectedRow
        guard row >= 0, let node = outline.item(atRow: row) as? MCPBrowserNode else {
            clearSelection()
            return
        }
        inspectSelectionIfNeeded(node)
    }

    private func restoreSemanticOutlineSelection() {
        guard let selectedNodeID,
              let node = findNode(id: selectedNodeID) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        if outline.selectedRow == row,
           let selected = outline.item(atRow: row) as? MCPBrowserNode,
           selected.id == selectedNodeID {
            return
        }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    /// A source-list row should behave as one target. Finder-sized disclosure
    /// triangles are too small to be the only mouse path into a session group,
    /// so a primary click on a collapsed expandable row reveals its children.
    /// Keyboard selection remains non-expanding; Right Arrow and the standard
    /// accessibility Expand action keep their native outline semantics.
    @objc private func handleOutlineClick(_ sender: NSOutlineView) {
        let row = sender.clickedRow
        guard row >= 0,
              let item = sender.item(atRow: row),
              let node = item as? MCPBrowserNode else { return }
        if MCPPrimaryClickActivation.shouldRequestSelection(
            selectedRow: sender.selectedRow,
            clickedRow: row
        ) {
            sender.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        // AppKit may deliver selectionDidChange before or after this action.
        // Inspecting is idempotent, while terminal entry remains an explicit
        // click action and can never be caused by arrow-key selection alone.
        inspectSelectionIfNeeded(node)

        // MCP is the first-run view, so the Ouroboros Sessions extension needs
        // an explicit bridge into the session navigator. A catalog descriptor
        // is not executable session control; this link is the honest, direct
        // destination for users who discover sessions from the MCP surface.
        if isSessionsModeLink(node) {
            activateMode(
                .sessions,
                preferredSourceID: node.sourceID,
                openSingleLiveSession: shouldOpenSingleLiveSession(from: node)
            )
            return
        }

        // Terminal tabs are represented directly in Sessions. A row click is
        // therefore navigation to that exact terminal, not selection followed
        // by a second Open action or a duplicate tab-strip interaction.
        if node.sourceID == "terminal", node.id.hasPrefix("live-terminal:") {
            performSelectedPrimarySessionAction(nodeID: node.id)
            return
        }

        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let hasPrimaryTerminalAction = terminalEntryAffordance(
            for: node,
            runtime: runtime
        ).isPrimaryAction
        if hasPrimaryTerminalAction {
            performPrimarySessionAction(node)
        }
        if !hasPrimaryTerminalAction,
           sender.isExpandable(item),
           !sender.isItemExpanded(item) {
            sender.expandItem(item)
            if node.kind == .collection, node.title == "Sessions" {
                // One familiar click reveals useful work, not another layer of
                // closed folders. Earlier history stays collapsed by design.
                for child in node.children where child.title == "Live sessions" || child.title == "Recent history" {
                    sender.expandItem(child)
                }
            }
        }
        let isDetailRow = node.kind == .sessionGroup || node.kind == .sessionLeaf || node.kind == .item
        if MCPPrimaryClickActivation.shouldPresentDetail(
            isDetailRow: isDetailRow,
            hasPrimaryTerminalAction: hasPrimaryTerminalAction
        ),
           let anchor = sender.view(atColumn: 0, row: row, makeIfNecessary: false) {
            showDetail(for: node, anchoredTo: anchor)
        }
    }

    private func inspectSelectionIfNeeded(_ node: MCPBrowserNode) {
        guard MCPPrimaryClickActivation.shouldApplySelection(
            activeNodeID: selectedNodeID,
            incomingNodeID: node.id
        ) else { return }
        inspectSelection(node, announce: false)
    }

    private func inspectSelection(_ node: MCPBrowserNode, announce: Bool) {
        if let inFlightNodeID = terminalActivationInFlightNodeID,
           inFlightNodeID != node.id {
            terminalActivationInFlightNodeID = nil
            reloadVisibleRow(nodeID: inFlightNodeID)
        }
        requestGeneration &+= 1
        saveCurrentDraft()
        selectedFromPaneFocus = false
        selectedNodeID = node.id
        pendingTerminalActivationNodeID = nil
        pendingTerminalActivationGeneration = nil
        if activeMode == .mcp, !catalogSearchQuery.isEmpty {
            catalogSearchRetainedNodeID = node.id
        }
        applySelectionState(node, announce: announce)
    }

    /// Projects focused terminal identity into the navigator without moving
    /// first responder away from the terminal or sending any message.
    func focusSessionPane(_ focus: SessionPaneSteeringFocus?) {
        dispatchPrecondition(condition: .onQueue(.main))
        focusedSessionPane = focus
        pendingFocusedPaneLeaf = focus?.leaf
        guard let focus else {
            if selectedFromPaneFocus {
                saveCurrentDraft()
                selectedFromPaneFocus = false
                selectedTarget = nil
                setSteeringVisible(false)
                updateSteeringState()
            }
            return
        }
        if selectedFromPaneFocus {
            saveCurrentDraft()
            selectedTarget = nil
            setSteeringVisible(false)
            updateSteeringState()
        }
        if activeMode != .sessions || selectedSourceID != focus.leaf.sourceID {
            activateMode(
                .sessions,
                preferredSourceID: focus.leaf.sourceID,
                openSingleLiveSession: false
            )
        }
        selectPendingFocusedPaneIfPresent()
    }

    private func selectPendingFocusedPaneIfPresent() {
        guard let identity = pendingFocusedPaneLeaf else { return }
        func path(
            to target: OuroborosSessionAttemptIdentityV1,
            in nodes: [MCPBrowserNode]
        ) -> [MCPBrowserNode]? {
            for node in nodes {
                if node.kind == .sessionLeaf, node.sessionIdentity == target {
                    return [node]
                }
                if let childPath = path(to: target, in: node.children) {
                    return [node] + childPath
                }
            }
            return nil
        }
        guard let nodePath = path(to: identity, in: roots),
              let node = nodePath.last,
              node.kind == .sessionLeaf else { return }
        for ancestor in nodePath.dropLast() {
            outline.expandItem(ancestor)
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        pendingFocusedPaneLeaf = nil
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        inspectSelection(node, announce: false)
        selectedFromPaneFocus = true
    }

    private func performSelectedPrimarySessionAction(nodeID: String) {
        guard let node = resolveCurrentActivationNode(nodeID: nodeID) else { return }
        if node.sourceID == "terminal", node.kind == .sessionGroup {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node)
            } else {
                outline.expandItem(node)
            }
            return
        }
        if node.sourceID == "terminal",
           node.id.hasPrefix("live-terminal:"),
           let id = UUID(uuidString: String(node.id.dropFirst("live-terminal:".count))) {
            if onRequestActivateLiveTerminal?(id) == true {
                selectedNodeID = node.id
                announceStatus()
            }
            return
        }
        if isSessionsModeLink(node) {
            activateMode(
                .sessions,
                preferredSourceID: node.sourceID,
                openSingleLiveSession: shouldOpenSingleLiveSession(from: node)
            )
            return
        }
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        if node.kind == .sessionGroup {
            showDetail(nodeID: node.id)
            if SessionLifecycleCapabilityPolicy.isLive(node.status) {
                let executionIDs: [String]
                if let executionID = node.executionID {
                    executionIDs = [executionID]
                } else if let sessionID = node.sessionID {
                    executionIDs = runtime.groups
                        .filter { $0.sessionID == sessionID }
                        .map(\.executionID)
                } else {
                    executionIDs = []
                }
                for executionID in executionIDs {
                    startAgentDiscovery(executionID: executionID, runtime: runtime)
                }
            }
            return
        }
        if terminalEntryAffordance(for: node, runtime: runtime).isPrimaryAction {
            performPrimarySessionAction(node)
        } else if node.kind == .sessionLeaf {
            showDetail(nodeID: node.id)
        }
    }

    private func performPrimarySessionAction(_ node: MCPBrowserNode) {
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let terminalEntry = terminalEntryPresentation(for: node, runtime: runtime)
        guard SessionTerminalEntryAffordancePolicy.resolve(
            entry: terminalEntry,
            isGroup: node.kind == .sessionGroup,
            status: node.status,
            isProjectionTrusted: runtime.projectionTrusted
        ).isPrimaryAction else { return }
        guard terminalActivationInFlightNodeID != node.id else { return }

        // Steering metadata must never override the visible terminal action.
        // Promote one exact headless attempt only while the group itself is
        // explicitly presented as Activity, never for Terminal or Choose.
        if let childIndex = SessionGroupPrimaryAttemptPolicy.soleSteerableIndex(
            entry: terminalEntry,
            isGroup: node.kind == .sessionGroup,
            status: node.status,
            isProjectionTrusted: runtime.projectionTrusted,
            steerableChildren: node.children.map(\.canSteer)
        ) {
            let child = node.children[childIndex]
            if !outline.isItemExpanded(node) {
                expansionWithoutTargetRefreshNodeID = node.id
                outline.expandItem(node)
                // Defensive cleanup for an outline that declined expansion.
                if !outline.isItemExpanded(node) {
                    expansionWithoutTargetRefreshNodeID = nil
                }
            }
            let childRow = outline.row(forItem: child)
            guard childRow >= 0 else { return }
            outline.selectRowIndexes(IndexSet(integer: childRow), byExtendingSelection: false)
            inspectSelectionIfNeeded(child)
            performPrimarySessionAction(child)
            return
        }

        // Every explicit entry request gets a new generation. Async broker or
        // target-discovery callbacks from an earlier click cannot take over a
        // terminal after the user has moved elsewhere.
        requestGeneration &+= 1
        pendingTerminalActivationNodeID = nil
        pendingTerminalActivationGeneration = nil
        terminalActivationFailureNodeID = nil
        terminalActivationFailure = nil

        switch terminalEntry {
        case .openSession(let readOnly):
            // Opening a live headless Ouroboros run is also the explicit
            // request to discover its exact agent attempts. This is read-only
            // discovery; it does not grant a PTY lease or steering authority.
            if !readOnly, node.target == nil, let executionID = node.executionID {
                if SessionTerminalActivationIntentPolicy.shouldArm(
                    isGroup: node.kind == .sessionGroup,
                    status: node.status,
                    entry: terminalEntry
                ) {
                    pendingTerminalActivationNodeID = node.id
                    pendingTerminalActivationGeneration = requestGeneration
                    runtime.sessionAdapter?.requestTargets(
                        executionID: executionID,
                        intentGeneration: requestGeneration
                    )
                } else {
                    runtime.sessionAdapter?.requestTargets(executionID: executionID)
                }
            }
            showDetail(nodeID: node.id)
        case .openSingle:
            if node.kind == .sessionGroup {
                showDetail(nodeID: node.id)
                if let executionID = node.executionID, node.children.isEmpty {
                    startAgentDiscovery(executionID: executionID, runtime: runtime)
                }
            } else {
                hideDetail()
                requestTerminalActivation(for: node)
            }
        case .revealAgents, .revealRuns:
            guard node.kind == .sessionGroup else { return }
            if !outline.isItemExpanded(node) { outline.expandItem(node) }
            showDetail(nodeID: node.id)
            if let executionID = node.executionID, node.children.isEmpty {
                startAgentDiscovery(executionID: executionID, runtime: runtime)
            }
        case .none:
            return
        case .readOnlyHistory, .attachmentUnavailable:
            return
        }
        selectedTerminalStatus = terminalStatus(for: node, runtime: runtime)
        updateSteeringState()
        announceStatus()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            sendSteering(nil)
            return true
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        if let field = obj.object as? NSSearchField, field === catalogSearchField {
            scheduleCatalogSearch(field.stringValue)
            return
        }
        saveCurrentDraft()
        updateSteeringState()
    }

    private func scheduleCatalogSearch(_ rawQuery: String) {
        guard activeMode == .mcp else { return }
        let bounded = String(rawQuery.prefix(MCPCatalogSearchPolicy.maximumQueryCharacters))
        if bounded != catalogSearchField.stringValue {
            catalogSearchField.stringValue = bounded
        }
        catalogSearchWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.applyCatalogSearch(bounded)
        }
        catalogSearchWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(MCPCatalogSearchPolicy.debounceMilliseconds),
            execute: workItem
        )
    }

    private func applyCatalogSearch(_ rawQuery: String) {
        guard activeMode == .mcp else { return }
        let normalized = MCPCatalogSearchPolicy.normalizedQuery(rawQuery)
        guard normalized != catalogSearchQuery else { return }
        if catalogSearchQuery.isEmpty, !normalized.isEmpty {
            captureExpandedIDs(for: .mcp)
            catalogSearchRetainedNodeID = selectedNodeID
        } else if !catalogSearchQuery.isEmpty,
                  let selectedNodeID {
            catalogSearchRetainedNodeID = selectedNodeID
        }
        catalogSearchQuery = normalized
        if normalized.isEmpty {
            selectedNodeID = catalogSearchRetainedNodeID ?? selectedNodeID
            catalogSearchRetainedNodeID = nil
        }
        rebuildTree(captureCurrentExpansion: false)
    }

    @objc private func retry(_ sender: Any?) {
        sourceNotice.stringValue = ""
        sourceNotice.isHidden = true
        retryButton.title = "Reconnecting…"
        retryButton.isEnabled = false
        (sources.first { $0.id == selectedSourceID } ?? primarySource).adapter.retry()
    }

    @objc private func privilegedScopeChanged(_ sender: NSPopUpButton) {
        guard let sourceID = sender.identifier?.rawValue else { return }
        let scopes: [PrivilegedMCPApprovalScope] = [.ask, .session, .workspace, .denied]
        guard scopes.indices.contains(sender.indexOfSelectedItem) else { return }
        privilegedApprovalStore.setScope(scopes[sender.indexOfSelectedItem], sourceID: sourceID)
        rebuildTree()
        announceStatus()
    }

    @objc private func sourceToggleChanged(_ sender: NSSwitch) {
        guard let sourceID = sender.identifier?.rawValue,
              let runtime = sources.first(where: { $0.id == sourceID }) else { return }
        let enabled = sender.state == .on
        guard runtime.isEnabled != enabled else { return }
        runtime.isEnabled = enabled
        sourceEnablementStore.setEnabled(
            enabled,
            sourceID: sourceID,
            allSourceIDs: sources.map(\.id)
        )
        runtime.groups = []
        runtime.projectionTrusted = false
        runtime.catalog = MCPSourceCatalog(serverName: runtime.displayName)
        if enabled {
            runtime.status = "starting"
            runtime.detail = "Connecting to the local MCP endpoint"
            if observationActive { runtime.adapter.resumeObservation() }
        } else {
            runtime.adapter.stop()
            runtime.status = "disabled"
            runtime.detail = "Disabled · enable to connect"
            if selectedSourceID == sourceID { clearSelection() }
        }
        rebuildTree()
        announceStatus()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        let nextMode: SessionRailMode = sender.selectedSegment == 1 ? .mcp : .sessions
        activateMode(nextMode)
    }

    private func activateMode(
        _ nextMode: SessionRailMode,
        preferredSourceID: String? = nil,
        openSingleLiveSession: Bool = false
    ) {
        guard nextMode != activeMode || preferredSourceID != nil else { return }
        captureExpandedIDs(for: activeMode)
        saveCurrentDraft()
        hideDetail()
        deactivateSessionDetail()
        if let preferredSourceID {
            selectedSourceID = preferredSourceID
        }
        selectedNodeID = nil
        selectedTarget = nil
        selectedDraftKey = nil
        setSteeringVisible(false)
        clearCatalogSearchIfNeeded(from: activeMode, to: nextMode)
        activeMode = nextMode
        modeSelector.selectedSegment = nextMode == .mcp ? 1 : 0
        updateCatalogSearchPresentation()
        pendingTerminalActivationNodeID = nil
        pendingTerminalActivationGeneration = nil
        outline.deselectAll(nil)
        outline.setAccessibilityHelp(SessionRailModePresentationPolicy.accessibilityHelp(for: nextMode))
        rebuildTree(captureCurrentExpansion: false)
        focusBrowser(nil)

        // A cross-link should land in useful work, not merely switch the
        // segmented control while leaving the user staring at a source row.
        // Selection remains inspection-only; the user still performs the
        // explicit row action to attach a terminal or open activity.
        guard nextMode == .sessions, preferredSourceID != nil else { return }
        guard let preferredSourceID,
              let landing = SessionCrossLinkLandingPolicy.resolve(
                preferredSourceID: preferredSourceID,
                candidates: sessionCrossLinkCandidates(roots)
              ),
              let target = findNode(id: landing.destinationID) else { return }
        expandedIDsByMode[.sessions, default: []].formUnion(
            landing.ancestorIDsToExpand
        )
        for ancestorID in landing.ancestorIDsToExpand {
            if let ancestor = findNode(id: ancestorID) {
                outline.expandItem(ancestor)
            }
        }
        guard outline.row(forItem: target) >= 0 else { return }
        let row = outline.row(forItem: target)
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
        inspectSelectionIfNeeded(target)
        if openSingleLiveSession {
            performPrimarySessionAction(target)
        }
    }

    private func shouldOpenSingleLiveSession(from node: MCPBrowserNode) -> Bool {
        guard isSessionsModeLink(node),
              let runtime = sources.first(where: { $0.id == node.sourceID }) else { return false }
        return runtime.groups.filter {
            let status = $0.status.lowercased()
            return status == "running" || status == "active"
        }.count == 1
    }

    private func flattenNodes(_ nodes: [MCPBrowserNode]) -> [MCPBrowserNode] {
        nodes.flatMap { [$0] + flattenNodes($0.children) }
    }

    private func sessionCrossLinkCandidates(
        _ nodes: [MCPBrowserNode],
        ancestorIDs: [String] = []
    ) -> [SessionCrossLinkCandidate] {
        nodes.flatMap { node -> [SessionCrossLinkCandidate] in
            var candidates: [SessionCrossLinkCandidate] = []
            if node.kind == .sessionGroup {
                candidates.append(SessionCrossLinkCandidate(
                    id: node.id,
                    sourceID: node.sourceID,
                    status: node.status,
                    kind: .sessionGroup,
                    ancestorIDs: ancestorIDs
                ))
            } else if node.kind == .collection,
                      node.id.hasSuffix(":sessions:empty") {
                candidates.append(SessionCrossLinkCandidate(
                    id: node.id,
                    sourceID: node.sourceID,
                    status: node.status,
                    kind: .emptyState,
                    ancestorIDs: ancestorIDs
                ))
            }
            candidates.append(contentsOf: sessionCrossLinkCandidates(
                node.children,
                ancestorIDs: ancestorIDs + [node.id]
            ))
            return candidates
        }
    }

    private func clearCatalogSearchIfNeeded(from oldMode: SessionRailMode, to newMode: SessionRailMode) {
        guard MCPCatalogSearchPolicy.shouldClearQuery(from: oldMode, to: newMode) else { return }
        catalogSearchWorkItem?.cancel()
        catalogSearchWorkItem = nil
        catalogSearchQuery = ""
        catalogSearchRetainedNodeID = nil
        catalogSearchField.stringValue = ""
        catalogSearchStatusLabel.stringValue = ""
    }

    private func updateCatalogSearchPresentation() {
        let isMCP = activeMode == .mcp
        catalogSearchField.isHidden = !isMCP
        catalogSearchStatusLabel.isHidden = !isMCP || catalogSearchStatusLabel.stringValue.isEmpty
        catalogSearchHeightConstraint?.constant = isMCP ? 28 : 0
        catalogSearchStatusHeightConstraint?.constant = isMCP && !catalogSearchStatusLabel.stringValue.isEmpty ? 30 : 0
    }

    @objc private func sendSteering(_ sender: Any?) {
        if selectedFromPaneFocus,
           focusedSessionPane?.leaf != selectedTarget?.sessionIdentity {
            receiptLabel.stringValue = "Read-only · focused pane no longer matches this agent"
            updateSteeringState()
            announceStatus()
            return
        }
        guard let runtime = sources.first(where: { $0.id == selectedSourceID }),
              hasVerifiedSteeringAuthority(for: runtime),
              runtime.projectionTrusted,
              let adapter = runtime.sessionAdapter,
              let target = selectedTarget else {
            receiptLabel.stringValue = steeringAuthorityExplanation()
            announceStatus()
            return
        }
        let message = messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        requestGeneration += 1
        guard let draftKey = targetKey(target, sourceID: selectedSourceID) else {
            receiptLabel.stringValue = "Read-only · exact attempt identity is unavailable"
            updateSteeringState()
            return
        }
        draftsByTarget[draftKey] = message
        retainSteeringTargetKey(draftKey)
        sendButton.isEnabled = false
        messageField.isEnabled = false
        receiptsByTarget[draftKey] = "Submitting · not yet queued"
        receiptLabel.stringValue = receiptsByTarget[draftKey] ?? ""
        announceStatus()
        adapter.steer(target: target, message: message) { [weak self] result in
            guard let self else { return }
            let isCurrentTarget = self.selectedDraftKey == draftKey
            switch result {
            case .success(let receipt):
                self.draftsByTarget[draftKey] = nil
                self.recordSteeringReceipt(receipt, draftKey: draftKey)
                if isCurrentTarget {
                    self.messageField.stringValue = ""
                    self.receiptLabel.stringValue = self.receiptsByTarget[draftKey] ?? ""
                }
                self.pollSteeringReceipt(
                    receipt,
                    draftKey: draftKey,
                    adapter: adapter
                )
            case .failure(let error):
                let reason = error.localizedDescription
                self.receiptsByTarget[draftKey] = "Not queued · \(reason)"
                if isCurrentTarget {
                    self.receiptLabel.stringValue = self.receiptsByTarget[draftKey] ?? ""
                }
                if reason.localizedCaseInsensitiveContains("target_lost") ||
                    reason.localizedCaseInsensitiveContains("attempt") ||
                    reason.localizedCaseInsensitiveContains("stale") {
                    self.selectedTarget = nil
                    runtime.projectionTrusted = false
                    runtime.status = "limited"
                    runtime.detail = reason
                    self.setSteeringVisible(false)
                    self.rebuildTree()
                    self.hideDetail()
                    if LaunchConfiguration.demoMode == "rejected" {
                        self.showNotice("Agent run ended · captured state; draft preserved")
                    } else {
                        self.showNotice("Agent run ended · refreshing now; draft preserved")
                        runtime.adapter.retry()
                    }
                }
            }
            if isCurrentTarget {
                self.messageField.isEnabled = true
                self.announceStatus()
                self.updateSteeringState()
            }
        }
    }

    private func saveAgentDraft(nodeID: String, draft: String) {
        guard let node = findNode(id: nodeID),
              let draftKey = exactDraftKey(for: node) else { return }
        if draft.isEmpty {
            draftsByTarget[draftKey] = nil
        } else {
            retainSteeringTargetKey(draftKey)
            draftsByTarget[draftKey] = draft
        }
    }

    /// Executes the card's visible primary action without changing the rail
    /// selection. A PTY-backed child enters its exact broker terminal; a
    /// headless child keeps the group workspace open and focuses its local
    /// composer in `SessionAgentCardView`.
    private func performAgentPrimaryAction(
        nodeID: String,
        action: SessionAgentPrimaryAction
    ) {
        guard let groupID = selectedNodeID,
              let group = findNode(id: groupID),
              group.kind == .sessionGroup,
              detailVisible,
              detailUsesSessionWorkspace,
              let child = group.children.first(where: { $0.id == nodeID }),
              child.kind == .sessionLeaf else { return }

        switch action {
        case .messageAgent:
            guard child.canSteer else { return }
            NSAccessibility.post(
                element: detailView,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: "Message \(child.title)",
                    .priority: NSAccessibilityPriorityLevel.low.rawValue,
                ]
            )
        case .enterTerminal:
            requestAgentTerminalActivation(child: child, groupID: groupID)
        case .none:
            break
        }
    }

    /// Activates a child while the selected row remains its parent group. The
    /// exact identity and group context are revalidated both before broker
    /// work and at completion so a reload, selection change, or reused node id
    /// cannot hand keyboard focus to a sibling attempt.
    private func requestAgentTerminalActivation(
        child: MCPBrowserNode,
        groupID: String
    ) {
        guard child.advertisesLiveTerminal,
              let exactIdentity = child.sessionIdentity,
              child.terminalIdentity == exactIdentity,
              let runtime = sources.first(where: { $0.id == child.sourceID }),
              runtime.projectionTrusted,
              let onRequestActivateTerminal else { return }

        requestGeneration &+= 1
        let activationGeneration = requestGeneration
        let childID = child.id
        terminalActivationInFlightNodeID = childID
        terminalActivationFailureNodeID = nil
        terminalActivationFailure = nil
        refreshAgentMultiplexer()

        let contextIsCurrent = { [weak self] in
            guard let self,
                  let currentGroup = self.findNode(id: groupID),
                  currentGroup.kind == .sessionGroup else {
                return false
            }
            let currentChild = currentGroup.children.first(where: { $0.id == childID })
            let identityStillMatches = currentChild?.sessionIdentity == exactIdentity
                && currentChild?.terminalIdentity == exactIdentity
                && currentChild?.advertisesLiveTerminal == true
            return SessionAgentMultiplexerPolicy.terminalActivationIsCurrent(
                expectedGeneration: activationGeneration,
                currentGeneration: self.requestGeneration,
                expectedGroupID: groupID,
                selectedGroupID: self.selectedNodeID,
                expectedChildID: childID,
                currentChildID: currentChild?.id,
                detailWorkspaceVisible: self.detailVisible && self.detailUsesSessionWorkspace,
                exactIdentityStillMatches: identityStillMatches
            )
        }

        onRequestActivateTerminal(
            exactIdentity,
            terminalBindingsSnapshot(),
            contextIsCurrent
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .activated:
                // `showTab` intentionally closes the borrowed workspace and
                // projects the focused PTY back into the rail before invoking
                // this completion. That transition increments the rail's
                // request generation, so the correct postcondition is the
                // exact focused pane identity rather than the old workspace
                // generation captured before the broker round trip.
                guard self.focusedSessionPane?.leaf == exactIdentity else { return }
                self.terminalActivationInFlightNodeID = nil
                if self.detailVisible { self.hideDetail() }
            case .unavailable(let failure):
                // Failures do not leave the workspace. Re-check the full
                // pre-activation context before attaching an error to a card;
                // stale or replaced children remain silent and fail closed.
                guard contextIsCurrent() else { return }
                self.terminalActivationInFlightNodeID = nil
                self.terminalActivationFailureNodeID = childID
                self.terminalActivationFailure = failure
                if let key = self.exactDraftKey(for: child) {
                    self.retainSteeringTargetKey(key)
                    self.receiptsByTarget[key] = "Terminal unavailable · \(failure.summary)"
                }
                self.refreshAgentMultiplexer()
                NSAccessibility.post(
                    element: self.detailView,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: failure.summary,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue,
                    ]
                )
            }
        }
    }

    /// Sends from the exact card identity instead of borrowing the rail's
    /// global `selectedTarget`. This is the critical multiplexer invariant: a
    /// click or reload elsewhere cannot redirect Agent A's draft to Agent B.
    private func sendAgentSteering(nodeID: String, message rawMessage: String) {
        let message = rawMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty,
              let node = findNode(id: nodeID),
              node.kind == .sessionLeaf,
              let runtime = sources.first(where: { $0.id == node.sourceID }),
              hasVerifiedSteeringAuthority(for: runtime),
              runtime.projectionTrusted,
              node.canSteer,
              let adapter = runtime.sessionAdapter,
              let target = node.target,
              let draftKey = targetKey(target, sourceID: node.sourceID),
              draftKey == exactDraftKey(for: node) else {
            if let node = findNode(id: nodeID), let key = exactDraftKey(for: node) {
                retainSteeringTargetKey(key)
                receiptsByTarget[key] = "Not queued · exact live steering authority is unavailable"
                refreshAgentMultiplexer()
            }
            return
        }

        requestGeneration &+= 1
        retainSteeringTargetKey(draftKey)
        draftsByTarget[draftKey] = message
        receiptsByTarget[draftKey] = "Submitting · not yet queued"
        refreshAgentMultiplexer()
        adapter.steer(target: target, message: message) { [weak self, weak runtime] result in
            guard let self else { return }
            switch result {
            case .success(let receipt):
                self.draftsByTarget[draftKey] = nil
                self.recordSteeringReceipt(receipt, draftKey: draftKey)
                self.pollSteeringReceipt(
                    receipt,
                    draftKey: draftKey,
                    adapter: adapter
                )
            case .failure(let error):
                let reason = error.localizedDescription
                self.receiptsByTarget[draftKey] = "Not queued · \(reason)"
                if reason.localizedCaseInsensitiveContains("target_lost")
                    || reason.localizedCaseInsensitiveContains("attempt")
                    || reason.localizedCaseInsensitiveContains("stale") {
                    runtime?.projectionTrusted = false
                    runtime?.status = "limited"
                    runtime?.detail = reason
                    self.rebuildTree()
                    if LaunchConfiguration.demoMode != "rejected" {
                        runtime?.adapter.retry()
                    }
                }
            }
            self.refreshAgentMultiplexer()
            NSAccessibility.post(element: self.detailView, notification: .valueChanged)
        }
    }

    private func bindClient(generation: UInt64) {
        for runtime in sources {
            runtime.adapter.onStateChange = { [weak self, weak runtime] state in
                guard let self, let runtime,
                      runtime.isEnabled,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                switch state {
                case .starting:
                    runtime.status = "starting"
                    runtime.detail = "Connecting to the local MCP endpoint"
                    runtime.projectionTrusted = false
                    if runtime === self.primarySource {
                        self.invalidateSteering("Connecting · sessions are read-only until verified")
                    }
                case .connected(let version):
                    runtime.status = "connected"
                    runtime.detail = "\(runtime.displayName) \(version) · MCP v2"
                    self.retryButton.isEnabled = true
                case .offline(let reason):
                    runtime.status = "offline"
                    runtime.detail = reason
                    runtime.projectionTrusted = false
                    if runtime === self.primarySource { self.invalidateSteering(self.offlineNotice) }
                }
                if runtime === self.primarySource { self.updateNotice() }
                self.publishSessionTerminalBindings()
                self.rebuildTree()
                self.announceStatus()
            }
            runtime.adapter.onCatalogChange = { [weak self, weak runtime] catalog in
                guard let self, let runtime,
                      runtime.isEnabled,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                runtime.catalog = catalog
                self.rebuildTree()
            }
            runtime.sessionDetailAdapter?.onSessionDetailChange = { [weak self, weak runtime] state in
                guard let self, let runtime,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                if state == .idle {
                    // An adapter deactivated for Agent 1 may publish idle after
                    // Agent 2 (or another source) is already active.
                    guard self.activeSessionActivation == nil else { return }
                } else {
                    guard runtime.id == state.activation?.sourceID else { return }
                }
                if let activation = state.activation,
                   activation != self.activeSessionActivation { return }
                self.sessionDetailState = state
                if self.detailVisible,
                   let id = self.selectedNodeID,
                   let node = self.findNode(id: id) {
                    self.updateShownDetail(for: node)
                }
            }
            if let routingAdapter = runtime.adapter as? MCPRoutingSourceAdapter {
                routingAdapter.onRoutingContractChange = { [weak self, weak runtime] state in
                    guard let self, let runtime,
                          self.observationActive,
                          self.observationGeneration == generation else { return }
                    runtime.routingState = state
                    self.rebuildTree()
                    if self.detailVisible,
                       let id = self.selectedNodeID,
                       let node = self.findNode(id: id) {
                        self.updateShownDetail(for: node)
                    }
                }
            }
            guard let sessionAdapter = runtime.sessionAdapter else { continue }
            sessionAdapter.onAuthenticatedSteeringChange = { [weak self, weak runtime] state in
                guard let self, let runtime,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                runtime.authenticatedSteeringState = state
                if state.isReady {
                    self.resumeSteeringReceiptPolling(adapter: sessionAdapter)
                }
                self.updateSteeringState()
                if self.detailVisible,
                   let id = self.selectedNodeID,
                   let node = self.findNode(id: id) {
                    self.updateShownDetail(for: node)
                }
            }
            sessionAdapter.onSessionsChange = { [weak self, weak runtime] groups in
                guard let self, let runtime,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                runtime.groups = groups
                runtime.lastSuccessfulRefresh = Date()
                self.publishSessionTerminalBindings()
                self.rebuildTree()
                if runtime === self.primarySource { self.updateNotice() }
            }
            sessionAdapter.onTargetDiscovery = { [weak self, weak runtime] result in
                guard let self, let runtime,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                self.handleTargetDiscovery(result, for: runtime)
            }
            sessionAdapter.onProjectionIssue = { [weak self, weak runtime] reason in
                guard let self, let runtime,
                      self.observationActive,
                      self.observationGeneration == generation else { return }
                if let reason {
                    runtime.status = "limited"
                    runtime.detail = reason
                    runtime.projectionTrusted = false
                    if runtime === self.primarySource {
                        self.invalidateSteering("Session data unavailable · retrying while Sessions is open")
                    }
                } else {
                    runtime.status = "connected"
                    runtime.detail = "\(runtime.displayName) \(runtime.catalog.serverVersion) · MCP v2"
                    runtime.projectionTrusted = true
                    if runtime === self.primarySource { self.hideNotice() }

                }
                self.retryButton.isEnabled = true
                if runtime === self.primarySource { self.updateNotice() }
                self.publishSessionTerminalBindings()
                self.rebuildTree()
                self.announceStatus()
            }
        }
    }

    private func captureExpandedIDs(for mode: SessionRailMode) {
        guard outline.numberOfRows > 0 else { return }
        expandedIDsByMode[mode] = Set((0..<outline.numberOfRows).compactMap { row -> String? in
            guard let node = outline.item(atRow: row) as? MCPBrowserNode,
                  outline.isItemExpanded(node) else { return nil }
            return node.id
        })
    }

    private func rebuildTree(captureCurrentExpansion: Bool = true) {
        let stableSelectedNodeID = selectedNodeID
        outlineReloadSettlingGeneration &+= 1
        let settlingGeneration = outlineReloadSettlingGeneration
        isRebuildingTree = true
        isOutlineReloadSettling = true
        defer {
            isRebuildingTree = false
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.outlineReloadSettlingGeneration == settlingGeneration else { return }
                self.isOutlineReloadSettling = false
            }
        }
        let selectedNodeKind = selectedNodeID.flatMap { findNode(id: $0)?.kind }
        let shouldKeepInspector = detailVisible
            && (selectedNodeKind == .sessionGroup || selectedNodeKind == .sessionLeaf)
        if captureCurrentExpansion,
           !(activeMode == .mcp && !catalogSearchQuery.isEmpty) {
            captureExpandedIDs(for: activeMode)
        }
        let unfilteredRoots = makeRoots(for: activeMode)
        if activeMode == .mcp, !catalogSearchQuery.isEmpty {
            let projection = MCPCatalogSearchPolicy.project(
                records: catalogSearchRecords(from: unfilteredRoots),
                query: catalogSearchQuery
            )
            roots = filteredCatalogNodes(unfilteredRoots, visibleIDs: projection.visibleIDs)
            updateCatalogSearchStatus(projection)
        } else {
            roots = unfilteredRoots
            updateCatalogSearchStatus(nil)
        }
        outline.reloadData()

        let defaultExpanded: Set<String>
        if activeMode == .sessions {
            // Sessions are terminal-like top-level destinations. Expand only
            // provider wrappers; agent attempts render in the main workspace
            // multiplexer after the session is opened.
            defaultExpanded = Set(roots.filter { $0.kind == .source }.map(\.id))
        } else {
            defaultExpanded = Set(roots.filter { $0.kind == .source }.map(\.id))
        }
        var expansionIDs = expandedIDsByMode[activeMode] ?? defaultExpanded
        if activeMode == .sessions {
            expansionIDs.formUnion(
                SessionRailExpansionPolicy.requiredExpansionIDs(
                    roots: roots,
                    selectedNodeID: stableSelectedNodeID,
                    id: \.id,
                    children: \.children,
                    isLiveBucket: { _ in false }
                )
            )
        } else if activeMode == .mcp {
            // Catalog negotiation can populate source children after the first
            // empty tree. Keep the source itself open across that rebuild so
            // MCP-first never regresses to a lone, unexplained provider row.
            expansionIDs.formUnion(roots.filter { $0.kind == .source }.map(\.id))
        }
        expand(nodes: roots, ids: expansionIDs)

        let hadPendingPaneFocus = pendingFocusedPaneLeaf != nil
        selectPendingFocusedPaneIfPresent()
        if hadPendingPaneFocus, pendingFocusedPaneLeaf == nil { return }

        guard let stableSelectedNodeID else { return }
        if let node = findNode(id: stableSelectedNodeID) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                applySelectionState(node, announce: false)
                if shouldKeepInspector {
                    updateShownDetail(for: node)
                }
            } else if detailVisible && detailUsesSessionWorkspace {
                // Status hydration may temporarily move the selected session
                // below a collapsed bucket. The open workspace is still the
                // authoritative user destination; keep it until an explicit
                // Back or another semantic row action.
                return
            } else {
                clearSelection()
            }
        } else if activeMode == .mcp, !catalogSearchQuery.isEmpty {
            clearSelection()
        } else if detailVisible && detailUsesSessionWorkspace {
            // Incremental session refreshes may briefly omit a group between
            // compact discovery and authoritative status projection. Do not
            // destroy a readable Activity surface because of that transient
            // transport state.
            return
        } else {
            clearSelection(notice: "Session ended · choose another live session")
        }
    }

    private func makeRoots(for mode: SessionRailMode) -> [MCPBrowserNode] {
        if mode == .sessions {
            return LiveAgentSessionProjectionPolicy.resolve(liveTerminalSessions).compactMap { projection in
                let terminalNodes = liveTerminalNodes(projection.terminals)
                if terminalNodes.count == 1 { return terminalNodes[0] }
                guard !terminalNodes.isEmpty else { return nil }
                return MCPBrowserNode(
                    id: "live-agent:\(projection.id)",
                    kind: .sessionGroup,
                    title: projection.title,
                    detail: projection.detail,
                    status: projection.status,
                    source: "Terminal",
                    sourceID: "terminal",
                    children: terminalNodes
                )
            }
        }
        return sources.map { runtime in
            makeSourceNode(
                runtime,
                includeSessions: false,
                includeMCP: true,
                mode: mode
            )
        }
    }

    private func liveTerminalNodes(
        _ terminals: [LiveTerminalSession]
    ) -> [MCPBrowserNode] {
        func makeNode(_ projection: LiveTerminalSessionTreeNode) -> MCPBrowserNode {
            let terminal = projection.terminal
            return MCPBrowserNode(
                id: "live-terminal:\(terminal.id.uuidString)",
                kind: .sessionLeaf,
                title: terminal.title,
                detail: terminal.detail,
                status: terminal.status,
                source: "Terminal",
                sourceID: "terminal",
                sessionIdentity: terminal.binding?.leaf,
                surface: terminal.binding.map { .pty($0.surface) } ?? .unbound(.notAdvertised),
                children: projection.children.map(makeNode)
            )
        }

        return LiveTerminalSessionTreePolicy.resolve(terminals).map(makeNode)
    }

    private func catalogSearchRecords(from nodes: [MCPBrowserNode]) -> [MCPCatalogSearchRecord] {
        var records: [MCPCatalogSearchRecord] = []
        records.reserveCapacity(min(MCPCatalogSearchPolicy.maximumRecordsExamined, 512))

        func append(_ candidates: [MCPBrowserNode], ancestry: [String]) {
            guard records.count <= MCPCatalogSearchPolicy.maximumRecordsExamined else { return }
            for node in candidates {
                guard records.count <= MCPCatalogSearchPolicy.maximumRecordsExamined else { return }
                records.append(MCPCatalogSearchRecord(
                    id: node.id,
                    ancestry: ancestry,
                    searchableText: "\(node.title) \(node.detail) \(node.status) \(node.source)"
                ))
                append(node.children, ancestry: ancestry + [node.id])
            }
        }
        append(nodes, ancestry: [])
        return records
    }

    private func filteredCatalogNodes(
        _ nodes: [MCPBrowserNode],
        visibleIDs: Set<String>
    ) -> [MCPBrowserNode] {
        nodes.compactMap { node in
            let visibleChildren = filteredCatalogNodes(node.children, visibleIDs: visibleIDs)
            guard visibleIDs.contains(node.id) || !visibleChildren.isEmpty else { return nil }
            node.children = visibleChildren
            return node
        }
    }

    private func updateCatalogSearchStatus(_ projection: MCPCatalogSearchProjection?) {
        let status: String
        if let projection, !projection.hasMatches {
            status = "No MCP matches"
        } else if projection?.reachedWorkLimit == true {
            status = "More results may exist"
        } else {
            status = ""
        }
        guard catalogSearchStatusLabel.stringValue != status else { return }
        catalogSearchStatusLabel.stringValue = status
        updateCatalogSearchPresentation()
        if !status.isEmpty {
            NSAccessibility.post(element: catalogSearchStatusLabel, notification: .valueChanged)
        }
    }

    private func makeSourceNode(
        _ runtime: MCPSourceRuntime,
        includeSessions: Bool = true,
        includeMCP: Bool = true,
        mode: SessionRailMode? = nil
    ) -> MCPBrowserNode {
        var children: [MCPBrowserNode] = []
        let catalog = runtime.catalog
        let sessionGroups = runtime.groups.map { group in
            let groupDetail: String
            if let decision = latestRoutingDecision(for: group.executionID, runtime: runtime) {
                groupDetail = "\(group.activity) · \(decision.actual.provider)/\(decision.actual.model) · \(decision.actual.effort)"
            } else if let tier = group.suggestedTier {
                groupDetail = "\(group.activity) · Suggested route: \(tier)"
            } else {
                groupDetail = group.activity
            }
            return MCPBrowserNode(
                id: "execution:\(runtime.id):\(group.executionID)",
                kind: .sessionGroup,
                title: group.title,
                detail: groupDetail,
                status: group.status,
                source: runtime.catalog.serverName,
                sourceID: runtime.id,
                sessionID: group.sessionID,
                executionID: group.executionID,
                children: group.tabs.map { tab in
                    let usableTarget = runtime.projectionTrusted && tab.target?.modes.contains("after_turn") == true ? tab.target : nil
                    return MCPBrowserNode(
                        id: "session:\(runtime.id):\(group.executionID):\(tab.id)",
                        kind: .sessionLeaf,
                        title: tab.label,
                        detail: tab.detail,
                        status: tab.status,
                        source: runtime.catalog.serverName,
                        sourceID: runtime.id,
                        sessionID: group.sessionID,
                        executionID: group.executionID,
                        target: usableTarget,
                        sessionIdentity: tab.sessionIdentity,
                        surface: tab.surface
                    )
                }
            )
        }
        if includeSessions, runtime.isEnabled, runtime.sessionAdapter != nil {
            if sessionGroups.isEmpty {
                let empty = SessionCollectionEmptyPresentationPolicy.resolve(
                    sourceStatus: runtime.status
                )
                children.append(MCPBrowserNode(
                    id: "collection:\(runtime.id):sessions:empty",
                    kind: .collection,
                    title: empty.title,
                    detail: empty.detail,
                    status: runtime.status,
                    source: runtime.catalog.serverName,
                    sourceID: runtime.id
                ))
            } else {
                children.append(contentsOf: makeSessionDestinations(
                    sessionGroups,
                    source: runtime.catalog.serverName,
                    sourceID: runtime.id
                ))
            }
        }

        // MCP mode is a connection manager, not a protocol inspector. Raw
        // tools/resources/prompts remain available to the gateway and agents,
        // but the sidebar presents only source health and enablement.

        let capabilityText = catalog.capabilities.isEmpty ? "Negotiating capabilities" : catalog.capabilities.joined(separator: ", ")
        let sourcePresentationDetail: String
        if mode == .sessions {
            if runtime.status == "limited" || runtime.status == "offline" {
                sourcePresentationDetail = statusSummary(runtime)
            } else if sessionGroups.isEmpty {
                sourcePresentationDetail = "No sessions yet"
            } else {
                let liveCount = sessionGroups.filter { $0.status.lowercased() == "running" }.count
                sourcePresentationDetail = liveCount > 0 ? "\(liveCount) active" : "Recent activity"
            }
        } else if !runtime.isEnabled {
            sourcePresentationDetail = "Disabled"
        } else if runtime.connectorClass == .privileged {
            let permissions = runtime.requiredMacOSPermissions.joined(separator: ", ")
            sourcePresentationDetail = permissions.isEmpty
                ? "Privileged connector"
                : "Privileged · \(permissions)"
        } else {
            sourcePresentationDetail = capabilityText
        }
        return MCPBrowserNode(
            id: "source:\(runtime.id):\(mode?.rawValue.lowercased() ?? "legacy")",
            kind: .source,
            title: runtime.displayName,
            detail: LaunchConfiguration.demoMode != nil
                ? "Captured fixture · \(capabilityText)"
                : sourcePresentationDetail,
            status: runtime.status,
            source: catalog.serverName,
            sourceID: runtime.id,
            children: children
        )
    }

    private func isSessionsModeLink(_ node: MCPBrowserNode) -> Bool {
        node.kind == .item && MCPSessionsLinkPresentationPolicy.matches(
            nodeID: node.id,
            sourceID: node.sourceID
        )
    }

    private func makeSessionDestinations(
        _ groups: [MCPBrowserNode],
        source: String,
        sourceID: String
    ) -> [MCPBrowserNode] {
        let nodesByExecutionID = Dictionary(uniqueKeysWithValues: groups.compactMap { node in
            node.executionID.map { ($0, node) }
        })
        let projections = SessionWorkspaceProjectionPolicy.resolve(groups.compactMap { node in
            guard let sessionID = node.sessionID, let executionID = node.executionID else { return nil }
            return SessionWorkspaceExecution(
                sessionID: sessionID,
                executionID: executionID,
                status: node.status,
                sortKey: node.detail,
                agentIDs: node.children.map(\.id)
            )
        })
        return projections.compactMap { projection in
            let entries = projection.executionIDs.compactMap { nodesByExecutionID[$0] }
            guard let primary = entries.first else { return nil }
            let agentsByID = Dictionary(uniqueKeysWithValues: entries.flatMap(\.children).map { ($0.id, $0) })
            let agentLeaves = projection.agentIDs.compactMap { agentsByID[$0] }
            let title = primary.title.hasPrefix("Session ·")
                ? "Ouroboros · \(shortSessionID(projection.sessionID))"
                : primary.title
            return MCPBrowserNode(
                id: "session:\(sourceID):\(projection.sessionID)",
                kind: .sessionGroup,
                title: title,
                detail: entries.count == 1 ? primary.detail : "\(entries.count) runs · \(agentLeaves.count) agents",
                status: projection.status,
                source: source,
                sourceID: sourceID,
                sessionID: projection.sessionID,
                executionID: entries.count == 1 ? primary.executionID : nil,
                children: agentLeaves
            )
        }
    }

    private func shortSessionID(_ sessionID: String) -> String {
        sessionID.count <= 18
            ? sessionID
            : String(sessionID.prefix(8)) + "…" + String(sessionID.suffix(6))
    }

    /// Updates local inspection/composer state only. Terminal attachment,
    /// target discovery, and detail loading each have their own explicit user
    /// action so keyboard and VoiceOver browsing remain side-effect free.
    private func applySelectionState(_ node: MCPBrowserNode, announce: Bool) {
        selectedSourceID = node.sourceID
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let trustedTarget = runtime.projectionTrusted
            && node.canSteer
            && node.sessionIdentity != nil
            ? node.target
            : nil
        let exactAttemptIdentity = node.kind == .sessionLeaf ? node.sessionIdentity : nil
        selectedTarget = trustedTarget
        if node.kind == .sessionLeaf,
           let sessionID = node.sessionID,
           let executionID = node.executionID {
            let draftKey = SessionSteeringDraftKeyPolicy.key(
                sourceID: node.sourceID,
                sessionID: sessionID,
                executionID: executionID,
                exactAttempt: exactAttemptIdentity.map {
                    SessionSteeringDraftIdentity(
                        executionID: $0.executionID,
                        scopeID: $0.scopeID,
                        attemptID: $0.attemptID
                    )
                }
            )
            selectedDraftKey = draftKey
            selectedLabel.stringValue = node.title
            messageField.stringValue = draftsByTarget[draftKey] ?? ""
            selectedTerminalStatus = terminalStatus(for: node, runtime: runtime)
            receiptLabel.stringValue = receiptsByTarget[draftKey]
                ?? priorExecutionReceiptText(executionID: executionID)
                ?? steeringAuthorityExplanation()
            setSteeringVisible(true)
        } else {
            selectedDraftKey = nil
            selectedTerminalStatus = nil
            messageField.stringValue = ""
            receiptLabel.stringValue = ""
            setSteeringVisible(false)
        }
        updateSteeringState()
        let isSessionNode = node.kind == .sessionGroup || node.kind == .sessionLeaf
        if detailVisible, detailUsesSessionWorkspace, !isSessionNode {
            hideDetail()
        }
        if detailVisible { updateShownDetail(for: node) }
        if announce { announceStatus() }
    }

    private func requestTerminalActivation(for node: MCPBrowserNode) {
        let terminalNode = node.kind == .sessionGroup
            ? node.children.first(where: { $0.terminalIdentity != nil }) ?? node
            : node
        guard let identity = terminalNode.sessionIdentity else {
            applyTerminalActivationResult(.unavailable(.noVerifiedBinding), nodeID: node.id)
            return
        }
        let activationGeneration = requestGeneration
        let activationNodeID = node.id
        terminalActivationFailureNodeID = nil
        terminalActivationFailure = nil
        guard let onRequestActivateTerminal else {
            applyTerminalActivationResult(
                .unavailable(.noCurrentBrokerGeneration),
                nodeID: activationNodeID
            )
            return
        }
        terminalActivationInFlightNodeID = activationNodeID
        reloadVisibleRow(nodeID: activationNodeID)
        let requestIsCurrent = { [weak self] in
            guard let self else { return false }
            return self.requestGeneration == activationGeneration
                && self.selectedNodeID == activationNodeID
        }
        onRequestActivateTerminal(
            identity,
            terminalBindingsSnapshot(),
            requestIsCurrent
        ) { [weak self] activationResult in
            guard let self,
                  self.requestGeneration == activationGeneration,
                  self.selectedNodeID == activationNodeID else { return }
            self.applyTerminalActivationResult(
                activationResult,
                nodeID: activationNodeID
            )
        }
    }

    private func handleTargetDiscovery(
        _ result: MCPSessionTargetDiscoveryResult,
        for runtime: MCPSourceRuntime
    ) {
        if agentDiscoveryIntentByExecutionID[result.executionID] == result.intentGeneration {
            agentDiscoveryIntentByExecutionID[result.executionID] = nil
            agentDiscoveryOutcomeByExecutionID[result.executionID] = result.outcome
            if detailVisible,
               detailUsesSessionWorkspace,
               let selectedNodeID,
               let selected = findNode(id: selectedNodeID),
               selected.executionID == result.executionID {
                updateShownDetail(for: selected)
                announceStatus()
            }
        }
        guard let pendingNodeID = pendingTerminalActivationNodeID,
              let node = findNode(id: pendingNodeID),
              SessionTargetDiscoveryIntentPolicy.accepts(
                result,
                pendingExecutionID: node.executionID,
                pendingGeneration: pendingTerminalActivationGeneration,
                selectionStillMatches: selectedNodeID == pendingNodeID && node.sourceID == runtime.id
              ) else { return }

        switch result.outcome {
        case .discovered(let count) where count > 0:
            resolvePendingTerminalActivation(for: runtime)
        case .discovered, .empty:
            pendingTerminalActivationNodeID = nil
            pendingTerminalActivationGeneration = nil
            selectedTerminalStatus = "No live terminal is available yet"
            updateSteeringState()
            showNotice("No live terminal is available for this session yet.")
            announceStatus()
        case .unavailable:
            pendingTerminalActivationNodeID = nil
            pendingTerminalActivationGeneration = nil
            selectedTerminalStatus = "Could not verify a live terminal"
            updateSteeringState()
            showNotice("Couldn’t check live terminals. Try again.", allowsRetry: true)
            announceStatus()
        }
    }

    private func startAgentDiscovery(executionID: String, runtime: MCPSourceRuntime) {
        guard let adapter = runtime.sessionAdapter,
              agentDiscoveryIntentByExecutionID[executionID] == nil else { return }
        nextAgentDiscoveryGeneration &+= 1
        if nextAgentDiscoveryGeneration == 0 { nextAgentDiscoveryGeneration = 1 }
        let generation = nextAgentDiscoveryGeneration
        agentDiscoveryIntentByExecutionID[executionID] = generation
        agentDiscoveryOutcomeByExecutionID[executionID] = nil
        adapter.requestTargets(executionID: executionID, intentGeneration: generation)
        if detailVisible,
           let selectedNodeID,
           let selected = findNode(id: selectedNodeID),
           selected.executionID == executionID {
            updateShownDetail(for: selected)
        }
    }

    private func retrySelectedAgentDiscovery() {
        guard detailVisible,
              detailUsesSessionWorkspace,
              let selectedNodeID,
              let node = findNode(id: selectedNodeID),
              node.kind == .sessionGroup,
              node.children.isEmpty,
              let executionID = node.executionID,
              let runtime = sources.first(where: { $0.id == node.sourceID }) else {
            NSSound.beep()
            return
        }
        startAgentDiscovery(executionID: executionID, runtime: runtime)
    }

    private func resolvePendingTerminalActivation(for runtime: MCPSourceRuntime) {
        guard let pendingTerminalActivationNodeID,
              selectedNodeID == pendingTerminalActivationNodeID,
              let node = findNode(id: pendingTerminalActivationNodeID),
              node.sourceID == runtime.id else { return }
        let entry = terminalEntryPresentation(for: node, runtime: runtime)
        switch SessionTerminalActivationIntentPolicy.resolve(
            hasPendingIntent: true,
            selectionMatchesIntent: true,
            entry: entry
        ) {
        case .activate:
            self.pendingTerminalActivationNodeID = nil
            self.pendingTerminalActivationGeneration = nil
            hideDetail()
            requestTerminalActivation(for: node)
        case .revealRuns:
            self.pendingTerminalActivationNodeID = nil
            self.pendingTerminalActivationGeneration = nil
            outline.expandItem(node)
        case .none:
            self.pendingTerminalActivationNodeID = nil
            self.pendingTerminalActivationGeneration = nil
        case .wait:
            // The explicit discovery request completed but yielded no
            // actionable verified surface. Never leave Choose intent armed.
            self.pendingTerminalActivationNodeID = nil
            self.pendingTerminalActivationGeneration = nil
            selectedTerminalStatus = "No verified live terminal was found"
            updateSteeringState()
            showNotice("No verified live terminal was found. Try again.")
            announceStatus()
            return
        }
        selectedTerminalStatus = terminalStatus(for: node, runtime: runtime)
        updateSteeringState()
        if detailVisible { updateShownDetail(for: node) }
        announceStatus()
    }

    private func applyTerminalActivationResult(
        _ result: TerminalSessionActivationResult,
        nodeID: String
    ) {
        if terminalActivationInFlightNodeID == nodeID {
            terminalActivationInFlightNodeID = nil
        }
        switch result {
        case .activated:
            terminalActivationFailureNodeID = nil
            terminalActivationFailure = nil
        case .unavailable(let failure):
            terminalActivationFailureNodeID = nodeID
            terminalActivationFailure = failure
        }
        outline.reloadData()
        if selectedNodeID == nodeID,
           let row = outline.selectedRowIndexes.first,
           let node = outline.item(atRow: row) as? MCPBrowserNode {
            let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
            selectedTerminalStatus = terminalStatus(for: node, runtime: runtime)
            updateSteeringState()
            if detailVisible { updateShownDetail(for: node) }
        }
    }

    private func clearSelection(notice: String? = nil) {
        requestGeneration += 1
        saveCurrentDraft()
        deactivateSessionDetail()
        selectedNodeID = nil
        pendingTerminalActivationNodeID = nil
        pendingTerminalActivationGeneration = nil
        terminalActivationInFlightNodeID = nil
        selectedTarget = nil
        selectedTerminalStatus = nil
        selectedDraftKey = nil
        messageField.stringValue = ""
        receiptLabel.stringValue = ""
        setSteeringVisible(false)
        hideDetail()
        updateSteeringState()
        if let notice { showNotice(notice) }
    }

    private func terminalBindingsSnapshot() -> [TerminalSessionBinding] {
        sources.flatMap { runtime -> [TerminalSessionBinding] in
            guard runtime.projectionTrusted else { return [] }
            return runtime.groups.flatMap { group in
                guard SessionLifecycleCapabilityPolicy.isLive(group.status) else {
                    return [] as [TerminalSessionBinding]
                }
                return group.tabs.compactMap { tab in
                    guard SessionLifecycleCapabilityPolicy.permitsInteraction(
                        parentStatus: group.status,
                        childStatus: tab.status
                    ) else { return nil }
                    return TerminalSessionBinding(
                        surfaceResolution: tab.surface,
                        label: tab.label,
                        status: tab.status,
                        depth: tab.depth
                    )
                }
            }
        }
    }

    private func terminalEntryPresentation(
        for node: MCPBrowserNode,
        runtime: MCPSourceRuntime
    ) -> SessionTerminalEntryPresentation {
        guard node.kind == .sessionGroup || node.kind == .sessionLeaf else { return .none }
        let advertisedTerminalCount = node.kind == .sessionGroup
            ? node.children.reduce(into: 0) { count, child in
                if child.advertisesLiveTerminal { count += 1 }
            }
            : (node.terminalIdentity == nil ? 0 : 1)
        let normalizedStatus = node.status.lowercased()
        let isCompleted = normalizedStatus != "running" && normalizedStatus != "active"
        // A live fanout group is a navigator before it is an activity page.
        // The count may be zero before lazy exact-target discovery; expanding
        // the group triggers that discovery through the ordinary outline
        // lifecycle. This makes individual headless agents directly enterable
        // without pretending that they are PTYs.
        if let agentEntry = SessionAgentEntryPolicy.resolve(
            isGroup: node.kind == .sessionGroup,
            isProjectionTrusted: runtime.projectionTrusted,
            isCompleted: isCompleted,
            advertisedTerminalCount: advertisedTerminalCount,
            exactAgentCount: node.children.count
        ) {
            return agentEntry
        }
        return SessionTerminalEntryPolicy.resolve(
            isGroup: node.kind == .sessionGroup,
            isProjectionTrusted: runtime.projectionTrusted,
            advertisedTerminalCount: advertisedTerminalCount,
            isCompleted: isCompleted
        )
    }

    private func terminalEntryAffordance(
        for node: MCPBrowserNode,
        runtime: MCPSourceRuntime
    ) -> SessionTerminalEntryAffordance {
        SessionTerminalEntryAffordancePolicy.resolve(
            entry: terminalEntryPresentation(for: node, runtime: runtime),
            isGroup: node.kind == .sessionGroup,
            status: node.status,
            isProjectionTrusted: runtime.projectionTrusted
        )
    }

    private func terminalStatus(for node: MCPBrowserNode, runtime: MCPSourceRuntime) -> String {
        if terminalActivationFailureNodeID == node.id {
            return terminalActivationFailure?.summary ?? "Terminal unavailable"
        }
        switch terminalEntryPresentation(for: node, runtime: runtime) {
        case .openSession(let readOnly):
            return readOnly ? "Run ended · Read-only history" : "Live activity · Headless (no PTY)"
        case .openSingle: return "Terminal available"
        case .revealAgents(let count):
            return count > 0 ? "\(count) live agents · Choose one" : "Finding live agents"
        case .revealRuns(let count): return "\(count) terminals available"
        case .readOnlyHistory: return "Run ended · No live terminal"
        case .attachmentUnavailable(let reason): return reason
        case .none: return "No live terminal"
        }
    }

    private func publishSessionTerminalBindings() {
        onSessionTerminalBindingsChange?(terminalBindingsSnapshot())
    }

    private func activateSessionDetail(for node: MCPBrowserNode, runtime: MCPSourceRuntime) {
        guard observationActive,
              let sessionID = node.sessionID,
              let executionID = node.executionID,
              let adapter = runtime.sessionDetailAdapter else {
            deactivateSessionDetail()
            return
        }
        let exactIdentity = node.kind == .sessionLeaf ? node.sessionIdentity : nil
        let requiresExactAttempt = node.kind == .sessionLeaf
        if let exactIdentity,
           exactIdentity.sourceID != node.sourceID
            || exactIdentity.sessionID != sessionID
            || exactIdentity.executionID != executionID {
            deactivateSessionDetail()
            return
        }
        if let activeSessionActivation,
           activeSessionActivation.sourceID == node.sourceID,
           activeSessionActivation.sessionID == sessionID,
           activeSessionActivation.executionID == executionID,
           activeSessionActivation.scopeID == exactIdentity?.scopeID,
           activeSessionActivation.attemptID == exactIdentity?.attemptID,
           activeSessionActivation.requiresExactAttempt == requiresExactAttempt {
            return
        }
        deactivateSessionDetail()
        nextSessionActivationGeneration &+= 1
        if nextSessionActivationGeneration == 0 { nextSessionActivationGeneration = 1 }
        let activation = MCPSessionActivation(
            sourceID: node.sourceID,
            sessionID: sessionID,
            executionID: executionID,
            scopeID: exactIdentity?.scopeID,
            attemptID: exactIdentity?.attemptID,
            requiresExactAttempt: requiresExactAttempt,
            generation: nextSessionActivationGeneration
        )
        activeSessionActivation = activation
        sessionDetailState = .loading(activation)
        adapter.activateSession(activation)
    }

    private func deactivateSessionDetail() {
        guard let activation = activeSessionActivation else {
            sessionDetailState = .idle
            return
        }
        activeSessionActivation = nil
        sessionDetailState = .idle
        sources.first(where: { $0.id == activation.sourceID })?
            .sessionDetailAdapter?.deactivateSession(activation)
    }

    private func requestExpandedContent(for node: MCPBrowserNode) {
        guard observationActive,
              let runtime = sources.first(where: { $0.id == node.sourceID }) else { return }
        if node.kind == .sessionGroup, let executionID = node.executionID {
            runtime.sessionAdapter?.requestTargets(executionID: executionID)
            return
        }
        guard node.kind == .collection,
              let adapter = runtime.adapter as? MCPLazyCatalogSourceAdapter else { return }
        switch node.title {
        case "Tools": adapter.requestCollection(.tools)
        case "Resources": adapter.requestCollection(.resources)
        case "Prompts": adapter.requestCollection(.prompts)
        default: break
        }
    }

    private func selectionNote(_ node: MCPBrowserNode, live: Bool, runtime: MCPSourceRuntime) -> String {
        if node.kind == .sessionGroup || node.kind == .sessionLeaf {
            if terminalActivationFailureNodeID == node.id {
                return "Terminal attachment expired. Refresh Sessions to discover the current terminal. Steering remains separate and may still be unavailable."
            }
            switch terminalEntryPresentation(for: node, runtime: runtime) {
            case .openSession(let readOnly):
                return readOnly
                    ? "Run ended · no live terminal is attached. Review the activity below as read-only history."
                    : "This is a live headless run, not a terminal. Review its activity and choose an exact agent attempt for steering when available."
            case .openSingle:
                return live
                    ? "Terminal available. Send a message after this agent finishes its current turn."
                    : "Terminal available. Steering is unavailable until broker authority is verified."
            case .revealAgents(let count):
                if count > 0 {
                    return "Choose one of the \(count) exact live agent attempts below. Click a headless card to message that agent, or a verified PTY card to enter its terminal."
                }
                guard let executionID = node.executionID else {
                    return "No exact agent identity is available for this session."
                }
                if agentDiscoveryIntentByExecutionID[executionID] != nil {
                    return "Looking for exact live attempts… This is bounded MCP discovery and does not create another PTY."
                }
                switch agentDiscoveryOutcomeByExecutionID[executionID] {
                case .empty:
                    return "No exact attempts are active right now. Refresh agents to check again; completed attempts remain read-only history."
                case .unavailable(let reason):
                    return "Couldn’t discover exact attempts: \(reason). Refresh agents to retry."
                case .discovered:
                    return "The discovered attempts changed before they could be shown. Refresh agents to resolve the current generation."
                case nil:
                    return "Refresh agents to discover exact live attempts. Headless agents use guarded MCP messages; verified PTY agents accept terminal input."
                }
            case .revealRuns(let count):
                return "\(count) agent terminals are available. Expand this run and choose the agent you want to open."
            case .readOnlyHistory:
                return "Run ended · no live terminal is attached. Review the activity below as read-only history."
            case .attachmentUnavailable(let reason):
                return "\(reason). Refresh Sessions to discover the current terminal."
            case .none:
                return "No verified live terminal is attached. Review the activity below as read-only history."
            }
        }
        if live { return "Send a message after this agent finishes its current turn." }
        if let executionID = node.executionID,
           let decision = latestRoutingDecision(for: executionID, runtime: runtime) {
            let score = Int((decision.assessment.score * 100).rounded())
            let confidence = Int((decision.assessment.confidence * 100).rounded())
            let reasons = decision.reasonCodes.prefix(3).joined(separator: ", ")
            return "Signed route · \(decision.actual.provider)/\(decision.actual.model) · \(decision.actual.effort) · complexity \(score)% · confidence \(confidence)%\(reasons.isEmpty ? "" : " · \(reasons)")"
        }
        switch node.kind {
        case .source:
            if runtime.status == "connected" {
                return runtime.sessionAdapter == nil
                    ? "Transport and negotiated standard MCP capabilities are shown here."
                    : "Transport and negotiated capabilities are shown here; Sessions is a source extension."
            }
            return runtime.sessionAdapter == nil
                ? "Choose Retry to reconnect this source."
                : "\(recoveryDetail) Sessions remain read-only until verified."
        case .collection:
            if node.title == "Sessions", runtime.status == "limited" || runtime.status == "offline" {
                return "Session data is unavailable. Ourocode will retry while Sessions is open."
            }
            if node.title == "Sessions", node.children.isEmpty {
                return "This source currently advertises no sessions."
            }
            return "Use the disclosure control or the Left and Right Arrow keys to browse this collection."
        case .item:
            return "This is a standard MCP descriptor. Invoking tools or reading resources is not enabled in this bootstrap build."
        case .sessionGroup:
            return "Expand this session to see its individual agent runs."
        case .sessionLeaf:
            return "This agent run is read-only."
        }
    }

    private func latestRoutingDecision(
        for executionID: String,
        runtime: MCPSourceRuntime
    ) -> OuroborosRoutingDecision? {
        guard case .ready(let batch) = runtime.routingState else { return nil }
        return batch.events.reversed().compactMap { event in
            guard case .decided(_, let decision) = event,
                  decision.assessment.executionID == executionID else { return nil }
            return decision
        }.first
    }

    private func routingStateSummary(_ state: OuroborosRoutingContractState) -> String {
        switch state {
        case .unavailable:
            return "Routing receipts not advertised"
        case .loading:
            return "Loading signed routing receipts"
        case .ready(let batch):
            return "\(batch.events.count) signed routing receipt\(batch.events.count == 1 ? "" : "s")"
        case .rejected(let failure):
            return "Routing receipt rejected (\(failure.rawValue))"
        }
    }

    private func expand(nodes: [MCPBrowserNode], ids: Set<String>) {
        for node in nodes {
            if ids.contains(node.id) {
                outline.expandItem(node)
            }
            expand(nodes: node.children, ids: ids)
        }
    }

    private func findNode(id: String) -> MCPBrowserNode? {
        func search(_ nodes: [MCPBrowserNode]) -> MCPBrowserNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = search(node.children) { return found }
            }
            return nil
        }
        return search(roots)
    }

    private func rowDetail(_ node: MCPBrowserNode) -> String {
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        if node.kind == .source, !runtime.isEnabled {
            return "Disabled · enable to connect"
        }
        if node.kind == .source, runtime.connectorClass == .privileged {
            let permissions = runtime.requiredMacOSPermissions.joined(separator: ", ")
            return permissions.isEmpty
                ? "Privileged connector · session approval required"
                : "Privileged connector · \(permissions) · session approval required"
        }
        if node.kind == .source, runtime.status == "limited" || runtime.status == "offline" {
            return statusSummary(runtime)
        }
        if !runtime.projectionTrusted, node.kind == .sessionGroup || node.kind == .sessionLeaf {
            return "Last observed · \(sessionOutcomeLabel(node.status)) · \(node.detail)"
        }
        if node.kind == .sessionGroup || node.kind == .sessionLeaf {
            let outcome = sessionOutcomeLabel(node.status)
            return outcome == "Live" ? node.detail : "\(outcome) · \(node.detail)"
        }
        return node.detail
    }

    private func sessionOutcomeLabel(_ status: String) -> String {
        switch status.lowercased() {
        case "running", "active": return "Live"
        case "failed", "error", "rejected": return "Failed"
        case "cancelled", "canceled", "aborted": return "Cancelled"
        case "completed", "complete", "idle": return "Completed"
        default: return status.capitalized
        }
    }

    private func compactRowDetail(_ node: MCPBrowserNode) -> String {
        switch node.kind {
        case .source:
            return ""
        case .sessionGroup:
            let detail = rowDetail(node)
            return detail.components(separatedBy: " · Suggested route:").first ?? detail
        case .collection:
            return node.id.hasSuffix(":sessions:empty")
                && node.children.isEmpty
                ? rowDetail(node)
                : ""
        case .sessionLeaf:
            return rowDetail(node)
        case .item:
            if node.sourceID == "terminal" { return rowDetail(node) }
            return isSessionsModeLink(node) ? rowDetail(node) : ""
        }
    }

    private func rowState(_ node: MCPBrowserNode) -> String {
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        if terminalActivationFailureNodeID == node.id {
            return "Retry ›"
        }
        if terminalActivationInFlightNodeID == node.id {
            return "Opening…"
        }
        if pendingTerminalActivationNodeID == node.id {
            return "Checking…"
        }
        if isSessionsModeLink(node) {
            return sessionsLinkPresentation(for: node)?.stateLabel
                ?? "Browse sessions ›"
        }
        if node.id == "mode:sessions" {
            let liveCount = sources.flatMap(\.groups).filter { $0.status.lowercased() == "running" }.count
            return liveCount > 0 ? "\(liveCount) active" : ""
        }
        if node.id == "mode:mcp" { return "" }
        if node.kind == .source, !runtime.isEnabled { return "Off" }
        if node.kind == .source, LaunchConfiguration.demoMode != nil { return "Fixture" }
        if node.sourceID == "terminal" { return node.status.capitalized }
        if node.status.lowercased() == "checking",
           node.kind == .sessionGroup || node.kind == .sessionLeaf { return "Checking…" }
        if !runtime.projectionTrusted, node.kind == .sessionGroup || node.kind == .sessionLeaf { return "Unverified" }
        if (node.kind == .sessionGroup || node.kind == .sessionLeaf),
           let label = terminalEntryAffordance(for: node, runtime: runtime).stateLabel {
            return label
        }
        if node.kind == .sessionLeaf, node.canSteer && runtime.projectionTrusted { return "Live" }
        switch node.kind {
        case .sessionGroup:
            // Completion is the quiet default in a conversation history. Only
            // states that ask for attention earn a persistent trailing label.
            switch node.status.lowercased() {
            case "completed", "complete", "idle": return ""
            case "running", "active": return "Live"
            default: return node.status.capitalized
            }
        case .collection:
            if node.title == "MCP" { return "" }
            if node.title == "Sessions", node.children.isEmpty { return "" }
            return node.children.isEmpty ? "" : "\(node.children.count)"
        case .item:
            return ""
        default:
            return node.status.capitalized
        }
    }

    private func visualTitle(_ node: MCPBrowserNode) -> String {
        guard node.kind == .item, node.title.hasPrefix("ouroboros_") else { return node.title }
        return String(node.title.dropFirst("ouroboros_".count))
    }

    private func rowAccessibilityHelp(_ node: MCPBrowserNode) -> String {
        if isSessionsModeLink(node) {
            return sessionsLinkPresentation(for: node)?.accessibilityHelp
                ?? "Open this source’s session browser."
        }
        if terminalActivationFailureNodeID == node.id {
            return "The terminal could not be opened. Click or press Return to retry. Press Space for session details."
        }
        if terminalActivationInFlightNodeID == node.id {
            return "Opening this terminal. Press Space for session details."
        }
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        if let help = terminalEntryAffordance(for: node, runtime: runtime).accessibilityHelp {
            let status = node.status.lowercased()
            if node.kind == .sessionGroup || node.kind == .sessionLeaf,
               status != "running", status != "active" {
                return "\(sessionOutcomeLabel(node.status)). \(help)"
            }
            return help
        }
        return node.kind == .item
            ? "Click to select. Press Space for details."
            : "Press Space for details."
    }

    private func sessionsLinkPresentation(
        for node: MCPBrowserNode
    ) -> MCPSessionsLinkPresentation? {
        guard isSessionsModeLink(node) else { return nil }
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let liveCount = runtime.groups.filter {
            let status = $0.status.lowercased()
            return status == "running" || status == "active"
        }.count
        return MCPSessionsLinkPresentationPolicy.resolve(
            hasSessionsExtension: runtime.sessionAdapter != nil,
            liveCount: liveCount,
            totalCount: runtime.groups.count
        )
    }

    private func reloadVisibleRow(nodeID: String) {
        guard let node = findNode(id: nodeID) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.reloadData(
            forRowIndexes: IndexSet(integer: row),
            columnIndexes: IndexSet(integer: 0)
        )
    }

    private func showDetail(nodeID: String) {
        guard let node = resolveCurrentActivationNode(nodeID: nodeID) else { return }
        let row = outline.row(forItem: node)
        guard row >= 0,
              let anchor = outline.view(atColumn: 0, row: row, makeIfNecessary: false) else { return }
        showDetail(for: node, anchoredTo: anchor)
    }

    private func showDetail(for node: MCPBrowserNode, anchoredTo anchor: NSView) {
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let isSession = node.kind == .sessionGroup || node.kind == .sessionLeaf
        if isSession {
            activateSessionDetail(for: node, runtime: runtime)
        } else {
            deactivateSessionDetail()
        }
        updateShownDetail(for: node)
        // A workspace is a session-only work plane. If selection moves to an
        // MCP catalog item while it is visible, dismiss it before presenting
        // the item's compact inspector rather than leaving stale session
        // activity over the new selection.
        if detailVisible, detailUsesSessionWorkspace, !isSession {
            hideDetail()
        }
        if detailVisible {
            if detailUsesSessionWorkspace {
                detailView.window?.makeFirstResponder(detailView)
                detailView.announceCurrentState()
                return
            }
            detailPopover?.positioningRect = anchor.bounds
            detailPopover?.contentSize = detailView.preferredContentSize
            detailView.window?.makeFirstResponder(detailView)
            detailView.announceCurrentState()
            return
        }
        detailPreviousFirstResponder = view.window?.firstResponder
        detailPreviousNodeID = selectedNodeID
        detailFocusGeneration &+= 1
        detailVisible = true
        detailView.isHidden = false
        if isSession, let presentWorkspace = onRequestPresentSessionWorkspace {
            detailUsesSessionWorkspace = true
            applySteeringPresentation()
            presentWorkspace(detailView)
            NSAccessibility.post(element: view, notification: .layoutChanged)
            detailView.window?.makeFirstResponder(detailView)
            detailView.announceCurrentState()
            return
        }
        detailUsesSessionWorkspace = false
        let availableWindowWidth = view.window?.contentLayoutRect.width
            ?? SessionDetailSurfacePolicy.preferredReadingWidth
        let readingWidth = SessionDetailSurfacePolicy.readingWidth(
            availableWindowWidth: availableWindowWidth
        )
        detailView.configureReadingSurface(width: readingWidth)

        let contentController = NSViewController()
        contentController.view = detailView
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.contentViewController = contentController
        popover.contentSize = detailView.preferredContentSize
        detailPopover = popover
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
        NSAccessibility.post(element: view, notification: .layoutChanged)
        detailView.window?.makeFirstResponder(detailView)
        detailView.announceCurrentState()
    }

    private func hideDetail() {
        guard detailVisible else { return }
        let detailOwnedFocusAtDismissal = detailOwnsFocus(detailView.window?.firstResponder)
        detailFocusGeneration &+= 1
        let focusGeneration = detailFocusGeneration
        let previousResponder = detailPreviousFirstResponder
        let previousNodeID = detailPreviousNodeID
        detailPreviousFirstResponder = nil
        detailPreviousNodeID = nil
        detailVisible = false
        if detailUsesSessionWorkspace {
            onRequestDismissSessionWorkspace?(detailView)
            detailUsesSessionWorkspace = false
            applySteeringPresentation()
        } else {
            detailPopover?.close()
            detailPopover = nil
        }
        detailView.isHidden = true
        NSAccessibility.post(element: view, notification: .layoutChanged)
        DispatchQueue.main.async { [weak self, weak previousResponder] in
            guard let self else { return }
            let currentResponder = self.view.window?.firstResponder
            guard
                  SessionRailDetailFocusRestoration.shouldRestore(
                    detailOwnedFocusAtDismissal: detailOwnedFocusAtDismissal,
                    focusIsUnclaimedOrStillInDetail: currentResponder == nil
                        || currentResponder === self.view.window
                        || self.detailOwnsFocus(currentResponder)
                        || currentResponder === previousResponder,
                    requestGeneration: focusGeneration,
                    currentGeneration: self.detailFocusGeneration,
                    detailIsVisible: self.detailVisible
                  ) else { return }
            self.restoreDetailFocus(previousResponder: previousResponder, nodeID: previousNodeID)
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closedPopover = notification.object as? NSPopover,
              closedPopover === detailPopover,
              detailVisible else { return }
        hideDetail()
    }

    private func detailOwnsFocus(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder === detailView { return true }
        guard let responderView = responder as? NSView else { return false }
        return responderView === detailView || responderView.isDescendant(of: detailView)
    }

    private func restoreDetailFocus(previousResponder: NSResponder?, nodeID: String?) {
        guard let window = view.window else { return }
        if let previousView = previousResponder as? NSView,
           previousView !== detailView,
           previousView.window === window {
            window.makeFirstResponder(previousView)
            return
        }
        if let nodeID,
           let node = findNode(id: nodeID) {
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                outline.scrollRowToVisible(row)
            }
        }
        window.makeFirstResponder(outline)
    }

    private func updateShownDetail(for node: MCPBrowserNode) {
        detailView.update(selectionDetail(for: node))
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        detailView.updateAgentMultiplexer(
            agentMultiplexerPresentation(for: node, runtime: runtime)
        )
        detailView.updateSteeringHistory(
            node.executionID.map { steeringReceiptLedger.receipts(executionID: $0) } ?? []
        )
        updateAgentDiscoveryAction(for: node, runtime: runtime)
        if detailVisible, !detailUsesSessionWorkspace {
            detailPopover?.contentSize = detailView.preferredContentSize
        }
    }

    private func updateAgentDiscoveryAction(
        for node: MCPBrowserNode,
        runtime: MCPSourceRuntime
    ) {
        guard node.kind == .sessionGroup,
              SessionLifecycleCapabilityPolicy.isLive(node.status),
              node.children.isEmpty,
              let executionID = node.executionID else {
            detailView.updateAgentDiscoveryAction(
                visible: false,
                enabled: false,
                title: "Refresh agents",
                help: ""
            )
            return
        }
        let isLoading = agentDiscoveryIntentByExecutionID[executionID] != nil
        let title: String
        switch agentDiscoveryOutcomeByExecutionID[executionID] {
        case .empty: title = "Check again"
        case .unavailable: title = "Retry agent discovery"
        case .discovered: title = "Refresh changed agents"
        case nil: title = isLoading ? "Finding agents…" : "Refresh agents"
        }
        detailView.updateAgentDiscoveryAction(
            visible: true,
            enabled: !isLoading && runtime.sessionAdapter != nil,
            title: isLoading ? "Finding agents…" : title,
            help: "Discover exact live attempts for this session. This does not create a terminal or send a message."
        )
    }

    private func refreshAgentMultiplexer() {
        guard detailVisible,
              detailUsesSessionWorkspace,
              let selectedNodeID,
              let node = findNode(id: selectedNodeID) else { return }
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        detailView.updateAgentMultiplexer(
            agentMultiplexerPresentation(for: node, runtime: runtime)
        )
        detailView.updateSteeringHistory(
            node.executionID.map { steeringReceiptLedger.receipts(executionID: $0) } ?? []
        )
    }

    private func agentMultiplexerPresentation(
        for node: MCPBrowserNode,
        runtime: MCPSourceRuntime
    ) -> SessionAgentMultiplexerPresentation {
        guard node.kind == .sessionGroup,
              SessionLifecycleCapabilityPolicy.isLive(node.status) else { return .hidden }
        let authorityReady = runtime.projectionTrusted
            && hasVerifiedSteeringAuthority(for: runtime)
        let terminalBindings = terminalBindingsSnapshot()
        let candidates = node.children.compactMap { child -> SessionAgentMultiplexerCandidate? in
            guard child.kind == .sessionLeaf,
                  let identity = child.sessionIdentity,
                  identity.sourceID == child.sourceID,
                  identity.sessionID == child.sessionID,
                  identity.executionID == child.executionID else { return nil }
            let key = exactDraftKey(for: child)
            let exactTargetMatches = child.target.flatMap {
                targetKey($0, sourceID: child.sourceID)
            } == key
            let storedReceipt = key.flatMap { receiptsByTarget[$0] }
            let priorExecutionReceipt = priorExecutionReceiptText(
                executionID: identity.executionID
            )
            let isSubmitting = storedReceipt?.hasPrefix("Submitting") == true
            let canSteer = authorityReady && child.canSteer && exactTargetMatches && !isSubmitting
            let hasPTY = child.terminalIdentity != nil
            let canEnterTerminal = runtime.projectionTrusted
                && child.advertisesLiveTerminal
                && terminalBindings.contains(where: { $0.leaf == identity })
            let unavailableReason: String
            if isSubmitting {
                unavailableReason = "Submitting · waiting for MCP acknowledgement"
            } else if !runtime.projectionTrusted {
                unavailableReason = "View only · session projection is not verified"
            } else if !hasVerifiedSteeringAuthority(for: runtime) {
                unavailableReason = runtime.authenticatedSteeringState.composerExplanation
            } else {
                unavailableReason = "View only · this exact attempt does not advertise after-turn delivery"
            }
            return SessionAgentMultiplexerCandidate(
                id: child.id,
                title: child.title,
                status: child.status,
                summary: boundedDetail(child.detail),
                executionID: identity.executionID,
                scopeID: identity.scopeID,
                attemptID: identity.attemptID,
                hasPTY: hasPTY,
                canEnterTerminal: canEnterTerminal,
                canSteer: canSteer,
                draft: key.flatMap { draftsByTarget[$0] } ?? "",
                receipt: storedReceipt
                    ?? priorExecutionReceipt
                    ?? (canSteer
                        ? "Ready · queues after current turn"
                        : (canEnterTerminal
                            ? "Terminal ready · MCP messaging unavailable"
                            : unavailableReason)),
                unavailableReason: unavailableReason
            )
        }
        return SessionAgentMultiplexerPolicy.resolve(candidates)
    }

    private func selectionDetail(for node: MCPBrowserNode) -> MCPSelectionDetail {
        let runtime = sources.first(where: { $0.id == node.sourceID }) ?? primarySource
        let trustedTarget = runtime.projectionTrusted
            && node.canSteer
            && node.sessionIdentity != nil
            ? node.target
            : nil
        let detail: String
        if node.kind == .source {
            let sessionSummary: String
            if runtime.sessionAdapter == nil {
                sessionSummary = "This source does not advertise the Ourocode Sessions extension."
            } else {
                sessionSummary = runtime.lastSuccessfulRefresh.map {
                    "Last session refresh: \(timeFormatter.string(from: $0))."
                } ?? "No successful session refresh yet."
            }
            let caps = runtime.catalog.capabilities.isEmpty
                ? "Capabilities are still being negotiated."
                : "Capabilities: \(runtime.catalog.capabilities.joined(separator: ", "))."
            let recovery = runtime.status == "offline" || runtime.status == "limited"
                ? " Choose Retry to reconnect."
                : ""
            detail = "\(runtime.detail)\n\(runtime.catalog.endpoint)\nProtocol \(runtime.catalog.protocolVersion). \(caps) \(routingStateSummary(runtime.routingState)). \(sessionSummary)\(recovery)"
        } else {
            detail = node.detail
        }
        let recentEvents: MCPRecentEventsPresentation
        if (node.kind == .sessionGroup || node.kind == .sessionLeaf),
           let activation = activeSessionActivation,
           activation.sourceID == node.sourceID,
           activation.sessionID == node.sessionID,
           activation.executionID == node.executionID,
           activation.scopeID == (node.kind == .sessionLeaf ? node.sessionIdentity?.scopeID : nil),
           activation.attemptID == (node.kind == .sessionLeaf ? node.sessionIdentity?.attemptID : nil),
           activation.requiresExactAttempt == (node.kind == .sessionLeaf) {
            switch sessionDetailState {
            case .idle:
                recentEvents = .loading
            case .loading(let stateActivation) where stateActivation == activation:
                recentEvents = .loading
            case .ready(let stateActivation, let snapshot) where stateActivation == activation:
                recentEvents = .ready(
                    snapshot.events,
                    moreAvailable: snapshot.moreAvailable,
                    runProjection: snapshot.runProjection
                )
            case .unavailable(let stateActivation, let reason) where stateActivation == activation:
                recentEvents = .unavailable(reason)
            default:
                recentEvents = .loading
            }
        } else {
            recentEvents = .none
        }
        let terminalEntry: SessionTerminalEntryPresentation
        if terminalActivationFailureNodeID == node.id {
            terminalEntry = .attachmentUnavailable(
                terminalActivationFailure?.summary ?? "Terminal unavailable"
            )
        } else {
            terminalEntry = terminalEntryPresentation(for: node, runtime: runtime)
        }
        return MCPSelectionDetail(
            source: node.source,
            title: node.title,
            detail: detail,
            status: node.status,
            isLive: trustedTarget != nil,
            terminalEntry: terminalEntry,
            note: selectionNote(node, live: trustedTarget != nil, runtime: runtime),
            recentEvents: recentEvents
        )
    }

    private func targetKey(_ target: OuroborosSignalTarget, sourceID: String) -> String? {
        guard let identity = target.sessionIdentity,
              identity.sourceID == sourceID,
              identity.executionID == target.executionID,
              identity.scopeID == target.scopeID,
              identity.attemptID == target.attemptID else { return nil }
        return SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: sourceID,
            sessionID: identity.sessionID,
            executionID: target.executionID,
            scopeID: target.scopeID,
            attemptID: target.attemptID
        )
    }

    private func exactDraftKey(for node: MCPBrowserNode) -> String? {
        guard let identity = node.sessionIdentity,
              identity.sourceID == node.sourceID,
              identity.sessionID == node.sessionID,
              identity.executionID == node.executionID else { return nil }
        return SessionSteeringDraftKeyPolicy.exactKey(
            sourceID: identity.sourceID,
            sessionID: identity.sessionID,
            executionID: identity.executionID,
            scopeID: identity.scopeID,
            attemptID: identity.attemptID
        )
    }

    private func saveCurrentDraft() {
        guard let selectedDraftKey else { return }
        let draft = messageField.stringValue
        if draft.isEmpty {
            draftsByTarget[selectedDraftKey] = nil
        } else {
            retainSteeringTargetKey(selectedDraftKey)
            draftsByTarget[selectedDraftKey] = draft
        }
    }

    private func statusSummary(_ runtime: MCPSourceRuntime) -> String {
        guard runtime.sessionAdapter != nil else { return boundedDetail(runtime.detail) }
        return runtime.status == "limited" ? "Sessions unavailable" : offlineNotice
    }

    private func makeSteeringPanel() -> NSView {
        let panel = SolidPanelView(cornerRadius: 7)
        panel.translatesAutoresizingMaskIntoConstraints = false

        steeringCaption.font = OuroTheme.uiFont(size: 12, weight: .semibold)
        steeringCaption.textColor = .secondaryLabelColor
        steeringCaption.translatesAutoresizingMaskIntoConstraints = false
        steeringExplanation.font = OuroTheme.uiFont(size: 11.5)
        steeringExplanation.textColor = .tertiaryLabelColor
        steeringExplanation.translatesAutoresizingMaskIntoConstraints = false
        selectedLabel.font = OuroTheme.uiFont(size: 12, weight: .medium)
        selectedLabel.textColor = .labelColor
        selectedLabel.alignment = .right
        selectedLabel.maximumNumberOfLines = 1
        selectedLabel.lineBreakMode = .byTruncatingMiddle
        selectedLabel.translatesAutoresizingMaskIntoConstraints = false
        messageField.placeholderString = "Message to agent"
        messageField.font = OuroTheme.uiFont(size: 13)
        messageField.setAccessibilityLabel("Agent steering message")
        messageField.setAccessibilityHelp(
            "Queue a guarded message after the exact selected live attempt finishes its current turn. This is not terminal input."
        )
        messageField.delegate = self
        messageField.isEnabled = false
        messageField.translatesAutoresizingMaskIntoConstraints = false
        sendButton.target = self
        sendButton.action = #selector(sendSteering(_:))
        sendButton.bezelStyle = .push
        sendButton.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        sendButton.setAccessibilityLabel("Queue agent steering message")
        sendButton.setAccessibilityHelp("Queue this message after the exact selected live attempt's current turn.")
        sendButton.isEnabled = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        receiptLabel.font = OuroTheme.uiFont(size: 12)
        receiptLabel.textColor = .secondaryLabelColor
        receiptLabel.maximumNumberOfLines = 2
        receiptLabel.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStatusLabel.font = OuroTheme.uiFont(size: 12.5, weight: .medium)
        readOnlyStatusLabel.textColor = .secondaryLabelColor
        readOnlyStatusLabel.maximumNumberOfLines = 2
        readOnlyStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        readOnlyStatusLabel.setAccessibilityLabel("Session messaging status")

        composerControls = [steeringCaption, steeringExplanation, selectedLabel, messageField, sendButton, receiptLabel]
        (composerControls + [readOnlyStatusLabel]).forEach(panel.addSubview)
        let verticalConstraints = [
            steeringCaption.topAnchor.constraint(equalTo: panel.topAnchor, constant: 8),
            steeringExplanation.topAnchor.constraint(equalTo: steeringCaption.bottomAnchor, constant: 2),
            messageField.topAnchor.constraint(equalTo: steeringExplanation.bottomAnchor, constant: 5),
            messageField.heightAnchor.constraint(equalToConstant: 28),
            receiptLabel.topAnchor.constraint(equalTo: messageField.bottomAnchor, constant: 5),
            receiptLabel.bottomAnchor.constraint(lessThanOrEqualTo: panel.bottomAnchor, constant: -7)
        ]
        verticalConstraints.forEach { $0.priority = .defaultHigh }
        composerVerticalConstraints = verticalConstraints
        NSLayoutConstraint.activate([
            steeringCaption.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            selectedLabel.leadingAnchor.constraint(greaterThanOrEqualTo: steeringCaption.trailingAnchor, constant: 8),
            selectedLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            selectedLabel.firstBaselineAnchor.constraint(equalTo: steeringCaption.firstBaselineAnchor),
            steeringExplanation.leadingAnchor.constraint(equalTo: steeringCaption.leadingAnchor),
            steeringExplanation.trailingAnchor.constraint(lessThanOrEqualTo: panel.trailingAnchor, constant: -10),
            messageField.leadingAnchor.constraint(equalTo: steeringCaption.leadingAnchor),
            messageField.trailingAnchor.constraint(equalTo: sendButton.leadingAnchor, constant: -6),
            sendButton.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            sendButton.centerYAnchor.constraint(equalTo: messageField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 104),
            receiptLabel.leadingAnchor.constraint(equalTo: steeringCaption.leadingAnchor),
            receiptLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            readOnlyStatusLabel.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 10),
            readOnlyStatusLabel.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -10),
            readOnlyStatusLabel.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        ])
        panel.setAccessibilityLabel("Agent steering")
        return panel
    }

    private func setSteeringVisible(_ visible: Bool) {
        hasSteeringSelection = visible
        applySteeringPresentation()
    }

    private func applySteeringPresentation() {
        let runtime = sources.first(where: { $0.id == selectedSourceID })
        let presentation = SessionComposerPresentationPolicy.resolve(
            hasSessionSelection: hasSteeringSelection,
            hasVerifiedAuthority: runtime.map(hasVerifiedSteeringAuthority(for:)) ?? false,
            // A managed MCP connection is only the transport authority. The
            // composer is meaningful after this exact live attempt has also
            // been discovered and selected; completed/headless history must
            // stay visibly read-only even while the service is authenticated.
            hasExactTarget: selectedTarget != nil
        )
        let presentationChanged = steeringPresentation != presentation
        steeringPresentation = presentation
        steeringPanel?.isHidden = presentation == .hidden || detailUsesSessionWorkspace
        composerControls.forEach { $0.isHidden = presentation != .verifiedComposer }
        composerVerticalConstraints.forEach { $0.isActive = presentation == .verifiedComposer }
        readOnlyStatusLabel.isHidden = presentation != .passiveReadOnly
        if presentation == .passiveReadOnly {
            let hasDraft = !messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let authorityExplanation = selectedTarget == nil
                ? "No exact live attempt is available"
                : steeringAuthorityExplanation()
            readOnlyStatusLabel.stringValue = SessionComposerPresentationPolicy.passiveStatus(
                hasDraft: hasDraft,
                authorityExplanation: authorityExplanation,
                terminalStatus: selectedTerminalStatus
            )
            readOnlyStatusLabel.toolTip = SessionComposerPresentationPolicy.passiveStatusHelp(
                hasDraft: hasDraft,
                authorityExplanation: authorityExplanation,
                terminalStatus: selectedTerminalStatus
            )
            readOnlyStatusLabel.setAccessibilityHelp(readOnlyStatusLabel.toolTip)
        }
        steeringHeightConstraint?.constant = detailUsesSessionWorkspace ? 0 : presentation.height
        let enabled = messageField.isEnabled && selectedTarget != nil
        detailView.updateSessionComposer(
            visible: presentation == .verifiedComposer,
            enabled: enabled,
            target: selectedLabel.stringValue,
            draft: messageField.stringValue,
            explanation: steeringExplanation.stringValue,
            receipt: receiptLabel.stringValue
        )
        if presentationChanged { animateLayout() }
    }

    private func showNotice(_ text: String, allowsRetry: Bool = false) {
        sourceNotice.stringValue = text
        sourceNotice.isHidden = text.isEmpty
        retryButton.isHidden = !(allowsRetry || sourceStatus == "limited" || sourceStatus == "offline")
        retryButton.title = retryButton.isHidden ? "Retry" : "Reconnect"
        noticeHeightConstraint?.constant = (text.isEmpty && !retryButton.isHidden) ? 34 : 48
        animateLayout()
    }

    private func hideNotice() {
        sourceNotice.isHidden = true
        retryButton.isHidden = true
        noticeHeightConstraint?.constant = 0
        animateLayout()
    }

    private func updateNotice() {
        switch sourceStatus {
        case "limited", "offline":
            // The source row already carries Offline/Reconnecting state. Keep
            // one quiet action at the bottom instead of repeating the same
            // diagnosis in a second warning banner.
            showNotice("", allowsRetry: true)
        case "starting": hideNotice()
        default: hideNotice()
        }
    }

    private var offlineNotice: String {
        LaunchConfiguration.mcpURL != nil
            ? "Reconnecting…"
            : "Ouroboros is offline"
    }

    private var recoveryDetail: String {
        LaunchConfiguration.mcpURL != nil
            ? "Ourocode reconnects while Sessions is open."
            : "Choose Retry to reconnect."
    }

    private func invalidateSteering(_ message: String) {
        requestGeneration += 1
        saveCurrentDraft()
        selectedTarget = nil
        selectedDraftKey = nil
        setSteeringVisible(false)
        showNotice(message)
        if detailVisible, let id = selectedNodeID, let node = findNode(id: id) {
            updateShownDetail(for: node)
        }
    }

    private func updateSteeringState() {
        let runtime = sources.first(where: { $0.id == selectedSourceID })
        let paneMatchesTarget = !selectedFromPaneFocus
            || focusedSessionPane?.leaf == selectedTarget?.sessionIdentity
        let enabled = runtime.map(hasVerifiedSteeringAuthority(for:)) == true
            && runtime?.projectionTrusted == true
            && selectedTarget != nil
            && paneMatchesTarget
        messageField.isEnabled = enabled
        sendButton.isEnabled = enabled && !messageField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        messageField.placeholderString = enabled ? "Message to agent" : "Read-only until authority is verified"
        if !enabled, steeringPanel?.isHidden == false, receiptsByTarget[selectedDraftKey ?? ""] == nil {
            receiptLabel.stringValue = steeringAuthorityExplanation()
        }
        applySteeringPresentation()
    }

    private func hasVerifiedSteeringAuthority(for runtime: MCPSourceRuntime) -> Bool {
        // The current send path is Ouroboros MCP `after_turn` delivery. A
        // broker gateway descriptor alone is intentionally not enough to
        // enable this composer until the gateway transport is wired here.
        runtime.authenticatedSteeringState.isReady
    }

    private func steeringAuthorityExplanation() -> String {
        guard let runtime = sources.first(where: { $0.id == selectedSourceID }) else {
            return "Read-only · Session source is unavailable"
        }
        return runtime.authenticatedSteeringState.composerExplanation
    }

    private func animateLayout() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            view.layoutSubtreeIfNeeded()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            view.animator().layoutSubtreeIfNeeded()
        }
    }

    private func applyAccessibilityAppearance() {
        (steeringPanel as? SolidPanelView)?.refreshStyle()
        detailView.applyAccessibilityAppearance()
        outline.reloadData()
    }

    private func announceStatus() {
        if steeringPanel?.isHidden == false, !receiptLabel.stringValue.isEmpty {
            NSAccessibility.post(element: receiptLabel, notification: .valueChanged)
        }
        if !sourceNotice.isHidden, !sourceNotice.stringValue.isEmpty {
            NSAccessibility.post(element: sourceNotice, notification: .valueChanged)
        }
    }

    private func recordSteeringReceipt(
        _ receipt: OuroborosSteeringReceipt,
        draftKey: String
    ) {
        retainSteeringTargetKey(draftKey)
        latestSteeringReceiptByTarget[draftKey] = receipt
        steeringReceiptLedger.record(receipt)
        receiptsByTarget[draftKey] = OuroborosSteeringReceiptPresentation.text(
            receipt,
            priorCount: steeringReceiptLedger.priorMessageCount(for: receipt)
        )
        if let activation = activeSessionActivation,
           activation.executionID == receipt.target?.executionID {
            sources.first(where: { $0.id == activation.sourceID })?
                .sessionDetailAdapter?.refreshSession(activation)
        }
    }

    private func pollSteeringReceipt(
        _ receipt: OuroborosSteeringReceipt,
        draftKey: String,
        adapter: MCPSessionSourceAdapter,
        attempt: Int = 0
    ) {
        guard let signalID = receipt.signalID else { return }
        guard receipt.canRefreshLifecycle,
              attempt < OuroborosSteeringReceiptPollingPolicy.maximumAttempts else {
            steeringReceiptPolls[signalID]?.cancel()
            steeringReceiptPolls[signalID] = nil
            steeringReceiptPollGeneration[signalID] = nil
            return
        }
        guard !steeringReceiptPollsInFlight.contains(signalID) else { return }
        steeringReceiptPolls[signalID]?.cancel()
        let pollGeneration = (steeringReceiptPollGeneration[signalID] ?? 0) &+ 1
        steeringReceiptPollGeneration[signalID] = pollGeneration
        let delay = OuroborosSteeringReceiptPollingPolicy.delay(at: attempt)
        let work = DispatchWorkItem { [weak self, weak adapter] in
            guard let self, let adapter,
                  self.steeringReceiptPollGeneration[signalID] == pollGeneration,
                  self.latestSteeringReceiptByTarget[draftKey]?.signalID == signalID,
                  let latest = self.latestSteeringReceiptByTarget[draftKey],
                  latest.canRefreshLifecycle else { return }
            self.steeringReceiptPollsInFlight.insert(signalID)
            adapter.refreshSteering(receipt: latest) { [weak self, weak adapter] result in
                guard let self else { return }
                self.steeringReceiptPollsInFlight.remove(signalID)
                guard let adapter,
                      self.steeringReceiptPollGeneration[signalID] == pollGeneration,
                      self.latestSteeringReceiptByTarget[draftKey]?.signalID == signalID else {
                    return
                }
                switch result {
                case .success(let refreshed):
                    guard refreshed.signalID == signalID else { return }
                    self.recordSteeringReceipt(refreshed, draftKey: draftKey)
                    if self.selectedDraftKey == draftKey {
                        self.receiptLabel.stringValue = self.receiptsByTarget[draftKey] ?? ""
                        self.announceStatus()
                    }
                    self.refreshAgentMultiplexer()
                    if refreshed.canRefreshLifecycle {
                        self.pollSteeringReceipt(
                            refreshed,
                            draftKey: draftKey,
                            adapter: adapter,
                            attempt: attempt + 1
                        )
                    } else {
                        self.steeringReceiptPolls[signalID] = nil
                        self.steeringReceiptPollGeneration[signalID] = nil
                    }
                case .failure(let error):
                    // A failed projection refresh does not rewrite the last
                    // authoritative delivery state or manufacture a rejection.
                    let current = self.receiptsByTarget[draftKey]
                        ?? OuroborosSteeringReceiptPresentation.text(latest)
                    self.receiptsByTarget[draftKey] = "\(current) · Status check paused: \(error.localizedDescription)"
                    if self.selectedDraftKey == draftKey {
                        self.receiptLabel.stringValue = self.receiptsByTarget[draftKey] ?? ""
                    }
                    self.refreshAgentMultiplexer()
                    self.steeringReceiptPolls[signalID] = nil
                    self.steeringReceiptPollGeneration[signalID] = nil
                }
            }
        }
        steeringReceiptPolls[signalID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func resumeSteeringReceiptPolling(adapter: MCPSessionSourceAdapter) {
        for (draftKey, receipt) in latestSteeringReceiptByTarget
            where receipt.canRefreshLifecycle {
            pollSteeringReceipt(receipt, draftKey: draftKey, adapter: adapter)
        }
    }

    private func priorExecutionReceiptText(executionID: String) -> String? {
        let history = steeringReceiptLedger.receipts(executionID: executionID)
        guard let latest = history.last else { return nil }
        return "Earlier attempt · " + OuroborosSteeringReceiptPresentation.text(
            latest,
            priorCount: max(0, history.count - 1)
        )
    }

    private func retainSteeringTargetKey(_ key: String) {
        for evicted in steeringTargetKeyRetention.touch(key) {
            draftsByTarget[evicted] = nil
            receiptsByTarget[evicted] = nil
            if let signalID = latestSteeringReceiptByTarget[evicted]?.signalID {
                steeringReceiptPolls[signalID]?.cancel()
                steeringReceiptPolls[signalID] = nil
                steeringReceiptPollGeneration[signalID] = nil
                steeringReceiptPollsInFlight.remove(signalID)
            }
            latestSteeringReceiptByTarget[evicted] = nil
        }
    }

    private func boundedDetail(_ value: String) -> String {
        let oneLine = value.replacingOccurrences(of: "\n", with: " ")
        if oneLine.count <= 480 { return oneLine }
        return String(oneLine.prefix(479)) + "…"
    }

    private func stateColor(_ status: String) -> NSColor {
        switch status {
        case "running", "connected", "available", "live": return .systemMint
        case "failed", "cancelled", "limited", "offline", "unverified":
            return NSColor.systemOrange.withAlphaComponent(0.82)
        default: return .secondaryLabelColor
        }
    }

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .medium
        formatter.dateStyle = .none
        return formatter
    }()
}
