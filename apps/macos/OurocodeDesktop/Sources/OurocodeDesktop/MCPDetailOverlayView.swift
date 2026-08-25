import AppKit

/// A focused reading surface for one Connections item. The compact rail keeps
/// browsing density; this view is shown from the selected row only while the
/// user is reading details.
final class MCPDetailOverlayView: NSView, NSTextFieldDelegate {
    var onClose: (() -> Void)?
    var onComposerDraftChange: ((String) -> Void)?
    var onComposerSubmit: ((String) -> Void)?
    var onAgentDraftChange: ((String, String) -> Void)?
    var onAgentSubmit: ((String, String) -> Void)?
    var onAgentPrimaryAction: ((String, SessionAgentPrimaryAction) -> Void)?
    var onAgentDiscoveryRetry: (() -> Void)?

    private let sourceLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let availabilityLabel = NSTextField(wrappingLabelWithString: "")
    private let recentHeader = NSTextField(labelWithString: "Activity")
    private let steeringHistoryHeader = NSTextField(labelWithString: "Steering history")
    private let steeringHistoryLabel = NSTextField(wrappingLabelWithString: "")
    private let recentText = NSTextView()
    private let recentScroll = NSScrollView()
    private let composerPanel = NSView()
    private let composerTitle = NSTextField(labelWithString: "Message agent")
    private let composerTarget = NSTextField(labelWithString: "")
    private let composerExplanation = NSTextField(labelWithString: "Sent after this agent's current turn")
    private let composerField = NSTextField(string: "")
    private let composerButton = NSButton(title: "Send", target: nil, action: nil)
    private let composerReceipt = NSTextField(wrappingLabelWithString: "")
    private let agentMultiplexer = SessionAgentMultiplexerView(frame: .zero)
    private let agentDiscoveryButton = NSButton(title: "Refresh agents", target: nil, action: nil)
    private let contentStack = NSStackView()
    private let closeButton = NSButton()
    private let backButton = NSButton()
    private var recentHeightConstraint: NSLayoutConstraint?
    private var workspaceRecentMinimumHeightConstraint: NSLayoutConstraint?
    private var sourceTopConstraint: NSLayoutConstraint?
    private var widthConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var presentationWidth: CGFloat = SessionDetailSurfacePolicy.preferredReadingWidth
    private var usesExternalSize = false
    private var isSessionWorkspace = false
    private var currentAccessibilitySummary = ""
    private var currentRecentPresentation: MCPRecentEventsPresentation = .none
    private var composerRequestedVisible = false
    private var multiplexerPresentation = SessionAgentMultiplexerPresentation.hidden
    private var isLiveSession = false

    private(set) var preferredContentSize = NSSize(
        width: SessionDetailSurfacePolicy.preferredReadingWidth,
        height: 316
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccessibilityAppearance()
    }

    override func cancelOperation(_ sender: Any?) {
        onClose?()
    }

    /// Called by the rail after the inline inspector becomes visible. Updates
    /// that arrived while the inspector was hidden are intentionally announced
    /// here, once, after focus has a real accessibility destination.
    func announceCurrentState() {
        guard !isHidden, !currentAccessibilitySummary.isEmpty else { return }
        currentAccessibilitySummaryAnnouncement()
    }

    func configureReadingSurface(width: CGFloat) {
        precondition(width > 0)
        isSessionWorkspace = false
        composerPanel.isHidden = true
        agentMultiplexer.isHidden = true
        steeringHistoryHeader.isHidden = true
        steeringHistoryLabel.isHidden = true
        presentationWidth = width
        usesExternalSize = true
        workspaceRecentMinimumHeightConstraint?.isActive = false
        recentHeightConstraint?.isActive = true
        widthConstraint?.isActive = false
        heightConstraint?.isActive = false
        detailLabel.maximumNumberOfLines = 6
        availabilityLabel.maximumNumberOfLines = 4
        contentStack.spacing = 10
        recentHeightConstraint?.constant = 132
        applyReadingTypography()
        configureCloseButtonForInspector()
        updateRecentEvents(currentRecentPresentation)
        preferredContentSize.width = width
        frame.size = preferredContentSize
        translatesAutoresizingMaskIntoConstraints = true
        applyAccessibilityAppearance()
    }

    /// Turns the transient inspector into the primary reading surface for a
    /// headless MCP session. The terminal renderer stays retained underneath;
    /// this view only borrows the work area and therefore adds no second PTY,
    /// terminal model, or glyph atlas.
    func configureSessionWorkspace() {
        isSessionWorkspace = true
        composerPanel.isHidden = !composerRequestedVisible
        agentMultiplexer.isHidden = !multiplexerPresentation.isVisible
        let hasSteeringHistory = !steeringHistoryLabel.stringValue.isEmpty
        steeringHistoryHeader.isHidden = !hasSteeringHistory
        steeringHistoryLabel.isHidden = !hasSteeringHistory
        usesExternalSize = false
        widthConstraint?.isActive = false
        heightConstraint?.isActive = false
        recentHeightConstraint?.isActive = false
        if workspaceRecentMinimumHeightConstraint == nil {
            workspaceRecentMinimumHeightConstraint = recentScroll.heightAnchor
                .constraint(greaterThanOrEqualToConstant: 220)
        }
        workspaceRecentMinimumHeightConstraint?.isActive = true
        detailLabel.maximumNumberOfLines = 8
        availabilityLabel.maximumNumberOfLines = 5
        contentStack.spacing = 18
        applyWorkspaceTypography()
        configureCloseButtonForWorkspace()
        updateRecentEvents(currentRecentPresentation)
        translatesAutoresizingMaskIntoConstraints = false
        applyAccessibilityAppearance()
        updateAccessibilityExitDescription()
    }

    func updateSessionComposer(
        visible: Bool,
        enabled: Bool,
        target: String,
        draft: String,
        explanation: String,
        receipt: String
    ) {
        composerRequestedVisible = visible
        composerPanel.isHidden = !isSessionWorkspace || !visible
        composerTarget.stringValue = target
        if composerField.currentEditor() == nil, composerField.stringValue != draft {
            composerField.stringValue = draft
        }
        composerExplanation.stringValue = explanation
        composerReceipt.stringValue = receipt
        composerField.isEnabled = enabled
        composerButton.isEnabled = enabled
            && !composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        composerField.placeholderString = enabled ? "Message this agent" : "Messaging unavailable"
        composerPanel.setAccessibilityLabel("Steer \(target)")
        composerPanel.setAccessibilityHelp(explanation)
        if !composerPanel.isHidden {
            NSAccessibility.post(element: composerPanel, notification: .layoutChanged)
        }
        updateWorkspaceKeyLoop()
    }

    func updateAgentMultiplexer(_ presentation: SessionAgentMultiplexerPresentation) {
        multiplexerPresentation = presentation
        agentMultiplexer.update(presentation)
        if isSessionWorkspace {
            // A four-card grid is a parallel work surface, not terminal
            // history. Keep the activity reader available but let it yield
            // vertical space on compact windows.
            workspaceRecentMinimumHeightConstraint?.constant = presentation.isVisible ? 128 : 220
        }
        updateWorkspaceKeyLoop()
    }

    func updateAgentDiscoveryAction(
        visible: Bool,
        enabled: Bool,
        title: String,
        help: String
    ) {
        agentDiscoveryButton.isHidden = !isSessionWorkspace || !visible
        agentDiscoveryButton.isEnabled = enabled
        agentDiscoveryButton.title = title
        agentDiscoveryButton.toolTip = help
        agentDiscoveryButton.setAccessibilityLabel(title)
        agentDiscoveryButton.setAccessibilityHelp(help)
        updateWorkspaceKeyLoop()
    }

    func updateSteeringHistory(_ receipts: [OuroborosSteeringReceipt]) {
        steeringHistoryLabel.stringValue = OuroborosSteeringReceiptPresentation.historyText(receipts) ?? ""
        let visible = OuroborosSteeringReceiptPresentation.shouldShowHistory(
            inSessionWorkspace: isSessionWorkspace,
            receiptCount: receipts.count
        )
        steeringHistoryHeader.isHidden = !visible
        steeringHistoryLabel.isHidden = !visible
        steeringHistoryLabel.setAccessibilityLabel("Steering history")
        steeringHistoryLabel.setAccessibilityHelp(
            "Each line includes the exact attempt, immutable signal, lifecycle state, and application proof."
        )
        if visible {
            NSAccessibility.post(element: steeringHistoryLabel, notification: .valueChanged)
        }
    }

    func update(_ detail: MCPSelectionDetail) {
        // Protocol/version details belong in diagnostics. The workspace is a
        // human reading surface, so its eyebrow names the source only.
        sourceLabel.stringValue = detail.source
        isLiveSession = detail.isLive
        titleLabel.stringValue = detail.title
        switch detail.terminalEntry {
        case .openSession(let readOnly):
            statusLabel.stringValue = readOnly
                ? "Read-only history"
                : "Live session · Streaming"
            statusLabel.textColor = readOnly ? .secondaryLabelColor : OuroTheme.mint
        case .openSingle:
            statusLabel.stringValue = detail.isLive
                ? "Live session · Terminal available"
                : "Terminal available"
            statusLabel.textColor = detail.isLive ? OuroTheme.mint : .systemGreen
        case .revealAgents(let count):
            statusLabel.stringValue = count > 0
                ? "Live session · \(count) agents"
                : "Live session · Finding agents"
            statusLabel.textColor = OuroTheme.mint
        case .revealRuns(let count):
            statusLabel.stringValue = "Live session · \(count) terminals"
            statusLabel.textColor = OuroTheme.mint
        case .readOnlyHistory:
            statusLabel.stringValue = "Run ended · No live terminal"
            statusLabel.textColor = .secondaryLabelColor
        case .attachmentUnavailable(let reason):
            statusLabel.stringValue = reason
            statusLabel.textColor = .systemOrange
        case .none:
            statusLabel.stringValue = detail.isLive ? "Live" : detail.status.capitalized
            statusLabel.textColor = detail.isLive ? .systemGreen : statusColor(detail.status)
        }
        detailLabel.stringValue = detail.detail
        // Keep the narrow inspector actionable without sacrificing the full
        // explanation, which remains available through the tooltip/AX help.
        availabilityLabel.stringValue = compactAvailability(
            detail.note,
            recentEvents: detail.recentEvents
        )
        titleLabel.toolTip = detail.title
        detailLabel.toolTip = detail.detail
        availabilityLabel.toolTip = detail.note
        availabilityLabel.setAccessibilityHelp(compactAvailability(
            detail.note,
            recentEvents: detail.recentEvents
        ))
        updateRecentEvents(detail.recentEvents)
        setAccessibilityLabel("\(detail.title), \(statusLabel.stringValue)")
        updateAccessibilityExitDescription()
        let nextAccessibilitySummary = "\(detail.title), \(statusLabel.stringValue). \(activityAccessibilitySummary(detail.recentEvents))"
        let summaryChanged = nextAccessibilitySummary != currentAccessibilitySummary
        currentAccessibilitySummary = nextAccessibilitySummary
        if !isHidden {
            NSAccessibility.post(element: self, notification: .valueChanged)
            NSAccessibility.post(element: self, notification: .layoutChanged)
            if summaryChanged { currentAccessibilitySummaryAnnouncement() }
        }
    }

    func applyAccessibilityAppearance() {
        wantsLayer = true
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (isSessionWorkspace
                ? OuroTheme.canvas
                : NSColor.windowBackgroundColor).cgColor
            layer?.cornerRadius = isSessionWorkspace ? 0 : 10
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
            layer?.borderWidth = isSessionWorkspace ? 0 : 0.5
        }
    }

    private func build() {
        frame.size = preferredContentSize

        sourceLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.translatesAutoresizingMaskIntoConstraints = false
        sourceLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byWordWrapping
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        statusLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        detailLabel.font = NSFont.systemFont(ofSize: 13)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 6
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        availabilityLabel.font = NSFont.systemFont(ofSize: 12)
        availabilityLabel.textColor = .secondaryLabelColor
        availabilityLabel.maximumNumberOfLines = 4
        availabilityLabel.lineBreakMode = .byTruncatingTail
        availabilityLabel.translatesAutoresizingMaskIntoConstraints = false

        recentHeader.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        recentHeader.textColor = .secondaryLabelColor
        recentHeader.alignment = .left

        steeringHistoryHeader.font = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        steeringHistoryHeader.textColor = .secondaryLabelColor
        steeringHistoryHeader.translatesAutoresizingMaskIntoConstraints = false
        steeringHistoryLabel.font = OuroTheme.uiFont(size: 11.5)
        steeringHistoryLabel.textColor = .secondaryLabelColor
        steeringHistoryLabel.maximumNumberOfLines = 4
        steeringHistoryLabel.lineBreakMode = .byTruncatingMiddle
        steeringHistoryLabel.translatesAutoresizingMaskIntoConstraints = false
        steeringHistoryHeader.isHidden = true
        steeringHistoryLabel.isHidden = true

        recentText.isEditable = false
        recentText.isSelectable = true
        recentText.drawsBackground = false
        recentText.textContainerInset = NSSize(width: 0, height: 6)
        recentText.textContainer?.lineFragmentPadding = 0
        recentText.font = OuroTheme.uiFont(size: 13)
        recentText.textColor = .labelColor
        recentText.setAccessibilityRole(.staticText)
        recentText.setAccessibilityLabel("Session activity")
        recentText.setAccessibilityHelp("Read the available event history for the selected session.")

        composerPanel.wantsLayer = true
        composerPanel.layer?.cornerRadius = 9
        composerPanel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.72).cgColor
        composerPanel.translatesAutoresizingMaskIntoConstraints = false
        composerPanel.isHidden = true
        composerPanel.setAccessibilityElement(true)
        composerPanel.setAccessibilityRole(.group)

        agentMultiplexer.onDraftChange = { [weak self] id, draft in
            self?.onAgentDraftChange?(id, draft)
        }
        agentMultiplexer.onSubmit = { [weak self] id, message in
            self?.onAgentSubmit?(id, message)
        }
        agentMultiplexer.onPrimaryAction = { [weak self] id, action in
            self?.onAgentPrimaryAction?(id, action)
        }

        agentDiscoveryButton.bezelStyle = .rounded
        agentDiscoveryButton.font = OuroTheme.uiFont(size: 12.5, weight: .semibold)
        agentDiscoveryButton.target = self
        agentDiscoveryButton.action = #selector(retryAgentDiscovery(_:))
        agentDiscoveryButton.isHidden = true
        agentDiscoveryButton.translatesAutoresizingMaskIntoConstraints = false

        composerTitle.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        composerTitle.textColor = .labelColor
        composerTitle.translatesAutoresizingMaskIntoConstraints = false
        composerTarget.font = OuroTheme.uiFont(size: 12, weight: .medium)
        composerTarget.textColor = .secondaryLabelColor
        composerTarget.alignment = .right
        composerTarget.lineBreakMode = .byTruncatingMiddle
        composerTarget.translatesAutoresizingMaskIntoConstraints = false
        composerExplanation.font = OuroTheme.uiFont(size: 12)
        composerExplanation.textColor = .secondaryLabelColor
        composerExplanation.translatesAutoresizingMaskIntoConstraints = false
        composerField.font = OuroTheme.uiFont(size: 14)
        composerField.placeholderString = "Message this agent"
        composerField.delegate = self
        composerField.target = self
        composerField.action = #selector(submitComposer(_:))
        composerField.setAccessibilityLabel("Message this agent")
        composerField.setAccessibilityHelp("Queue a message after this exact agent finishes its current turn.")
        composerField.translatesAutoresizingMaskIntoConstraints = false
        composerButton.bezelStyle = .push
        composerButton.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        composerButton.target = self
        composerButton.action = #selector(submitComposer(_:))
        composerButton.setAccessibilityLabel("Send steering message")
        composerButton.translatesAutoresizingMaskIntoConstraints = false
        composerReceipt.font = OuroTheme.uiFont(size: 12)
        composerReceipt.textColor = .secondaryLabelColor
        composerReceipt.maximumNumberOfLines = 2
        composerReceipt.translatesAutoresizingMaskIntoConstraints = false
        [composerTitle, composerTarget, composerExplanation, composerField, composerButton, composerReceipt]
            .forEach(composerPanel.addSubview)

        NSLayoutConstraint.activate([
            composerTitle.topAnchor.constraint(equalTo: composerPanel.topAnchor, constant: 12),
            composerTitle.leadingAnchor.constraint(equalTo: composerPanel.leadingAnchor, constant: 14),
            composerTarget.leadingAnchor.constraint(greaterThanOrEqualTo: composerTitle.trailingAnchor, constant: 10),
            composerTarget.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -14),
            composerTarget.firstBaselineAnchor.constraint(equalTo: composerTitle.firstBaselineAnchor),
            composerExplanation.topAnchor.constraint(equalTo: composerTitle.bottomAnchor, constant: 3),
            composerExplanation.leadingAnchor.constraint(equalTo: composerTitle.leadingAnchor),
            composerExplanation.trailingAnchor.constraint(lessThanOrEqualTo: composerPanel.trailingAnchor, constant: -14),
            composerField.topAnchor.constraint(equalTo: composerExplanation.bottomAnchor, constant: 8),
            composerField.leadingAnchor.constraint(equalTo: composerTitle.leadingAnchor),
            composerField.trailingAnchor.constraint(equalTo: composerButton.leadingAnchor, constant: -8),
            composerField.heightAnchor.constraint(equalToConstant: 30),
            composerButton.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -12),
            composerButton.centerYAnchor.constraint(equalTo: composerField.centerYAnchor),
            composerButton.widthAnchor.constraint(equalToConstant: 72),
            composerReceipt.topAnchor.constraint(equalTo: composerField.bottomAnchor, constant: 6),
            composerReceipt.leadingAnchor.constraint(equalTo: composerTitle.leadingAnchor),
            composerReceipt.trailingAnchor.constraint(equalTo: composerPanel.trailingAnchor, constant: -14),
            composerReceipt.bottomAnchor.constraint(lessThanOrEqualTo: composerPanel.bottomAnchor, constant: -9),
            composerPanel.heightAnchor.constraint(greaterThanOrEqualToConstant: 116)
        ])

        configureCloseButtonForInspector()
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close Details (Esc)"
        closeButton.setAccessibilityLabel("Close details")
        closeButton.setAccessibilityHelp("Hide session details and return focus to Connections.")
        closeButton.target = self
        closeButton.action = #selector(closeDetails(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        backButton.title = "Sessions"
        backButton.image = NSImage(
            systemSymbolName: "chevron.backward",
            accessibilityDescription: "Back"
        )
        backButton.imagePosition = .imageLeading
        backButton.imageScaling = .scaleProportionallyDown
        backButton.bezelStyle = .inline
        backButton.isBordered = false
        backButton.contentTintColor = .secondaryLabelColor
        backButton.font = OuroTheme.uiFont(size: 13, weight: .medium)
        backButton.toolTip = "Back to Sessions (Esc)"
        backButton.setAccessibilityLabel("Back to Sessions")
        backButton.setAccessibilityHelp("Return to the Sessions list.")
        backButton.keyEquivalent = "\u{1b}"
        backButton.target = self
        backButton.action = #selector(closeDetails(_:))
        backButton.isHidden = true
        backButton.translatesAutoresizingMaskIntoConstraints = false

        recentScroll.documentView = recentText
        recentScroll.drawsBackground = false
        recentScroll.borderType = .noBorder
        recentScroll.hasVerticalScroller = true
        recentScroll.autohidesScrollers = true
        recentScroll.translatesAutoresizingMaskIntoConstraints = false
        let recentHeight = recentScroll.heightAnchor.constraint(equalToConstant: 96)
        recentHeightConstraint = recentHeight
        recentHeight.isActive = true

        contentStack.orientation = .vertical
        // AppKit's `.width` alignment can place intrinsically-sized labels at
        // the trailing edge in a narrow vertical stack. Pin text and activity
        // to the reading edge while explicitly stretching only the surfaces
        // that need the full inspector width.
        contentStack.alignment = .leading
        contentStack.distribution = .fill
        contentStack.spacing = 10
        contentStack.addArrangedSubview(detailLabel)
        contentStack.addArrangedSubview(recentHeader)
        contentStack.addArrangedSubview(recentScroll)
        contentStack.addArrangedSubview(availabilityLabel)
        contentStack.addArrangedSubview(steeringHistoryHeader)
        contentStack.addArrangedSubview(steeringHistoryLabel)
        contentStack.addArrangedSubview(agentDiscoveryButton)
        contentStack.addArrangedSubview(agentMultiplexer)
        contentStack.addArrangedSubview(composerPanel)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(sourceLabel)
        addSubview(titleLabel)
        addSubview(statusLabel)
        addSubview(contentStack)
        addSubview(closeButton)
        addSubview(backButton)

        let width = widthAnchor.constraint(equalToConstant: preferredContentSize.width)
        let height = heightAnchor.constraint(equalToConstant: preferredContentSize.height)
        let sourceTop = sourceLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12)
        widthConstraint = width
        heightConstraint = height
        sourceTopConstraint = sourceTop
        NSLayoutConstraint.activate([
            width,
            height,

            sourceTop,
            sourceLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            sourceLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),

            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.widthAnchor.constraint(equalToConstant: 24),
            closeButton.heightAnchor.constraint(equalToConstant: 24),

            backButton.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            backButton.widthAnchor.constraint(equalToConstant: 96),
            backButton.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.topAnchor.constraint(equalTo: sourceLabel.bottomAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: sourceLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            contentStack.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 7),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            detailLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            recentHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            recentScroll.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            availabilityLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            steeringHistoryHeader.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            steeringHistoryLabel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            agentDiscoveryButton.heightAnchor.constraint(equalToConstant: 30),
            agentMultiplexer.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            composerPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close details") { [weak self] in
                guard let self else { return false }
                self.onClose?()
                return true
            }
        ])
        applyAccessibilityAppearance()
        updateRecentEvents(.none)
    }

    private func applyReadingTypography() {
        sourceLabel.font = OuroTheme.uiFont(size: 12, weight: .medium)
        titleLabel.font = OuroTheme.uiFont(size: 15, weight: .semibold)
        statusLabel.font = OuroTheme.uiFont(size: 12, weight: .medium)
        detailLabel.font = OuroTheme.uiFont(size: 13)
        availabilityLabel.font = OuroTheme.uiFont(size: 12)
        recentHeader.font = OuroTheme.uiFont(size: 11.5, weight: .semibold)
        recentText.font = OuroTheme.uiFont(size: 13)
    }

    private func applyWorkspaceTypography() {
        sourceLabel.font = OuroTheme.uiFont(size: 12.5, weight: .medium)
        titleLabel.font = OuroTheme.uiFont(size: 21, weight: .semibold)
        statusLabel.font = OuroTheme.uiFont(size: 13, weight: .medium)
        detailLabel.font = OuroTheme.uiFont(size: 15)
        availabilityLabel.font = OuroTheme.uiFont(size: 13)
        recentHeader.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        recentText.font = OuroTheme.uiFont(size: 14)
    }

    private func configureCloseButtonForInspector() {
        backButton.isHidden = true
        closeButton.isHidden = false
        sourceTopConstraint?.constant = 12
        closeButton.title = ""
        closeButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Close details"
        )
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .tertiaryLabelColor
        closeButton.toolTip = "Close Details (Esc)"
        closeButton.setAccessibilityLabel("Close details")
        closeButton.setAccessibilityHelp("Hide details and return focus to Connections.")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Close details") { [weak self] in
                guard let self else { return false }
                self.onClose?()
                return true
            }
        ])
    }

    private func configureCloseButtonForWorkspace() {
        closeButton.isHidden = true
        backButton.isHidden = false
        sourceTopConstraint?.constant = 52
        updateWorkspaceKeyLoop()
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Back to Sessions") { [weak self] in
                guard let self else { return false }
                self.onClose?()
                return true
            }
        ])
    }

    override func becomeFirstResponder() -> Bool {
        guard isSessionWorkspace else { return true }
        return window?.makeFirstResponder(backButton) ?? false
    }

    private func updateRecentEvents(_ presentation: MCPRecentEventsPresentation) {
        let previousPresentation = currentRecentPresentation
        let clipView = recentScroll.contentView
        let previousOrigin = clipView.bounds.origin
        let previousMaximumY = max(0, recentText.bounds.height - clipView.bounds.height)
        let wasFollowingLatest = previousMaximumY - previousOrigin.y <= 24
        currentRecentPresentation = presentation
        switch presentation {
        case .none:
            recentHeader.stringValue = "Activity"
            recentHeader.textColor = .secondaryLabelColor
            recentHeader.isHidden = true
            recentScroll.isHidden = true
            recentText.string = ""
            postRecentActivityValueChanged()
            setPreferredSize(NSSize(width: presentationWidth, height: usesExternalSize ? 228 : 258))
        case .loading:
            recentHeader.stringValue = isLiveSession ? "Live activity · Connecting…" : "Activity"
            recentHeader.textColor = isLiveSession ? OuroTheme.mint : .secondaryLabelColor
            recentHeader.isHidden = false
            recentScroll.isHidden = false
            recentText.string = "Loading activity…"
            recentHeightConstraint?.constant = 132
            workspaceRecentMinimumHeightConstraint?.constant = 220
            recentScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
            recentScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            postRecentActivityValueChanged()
            setPreferredSize(NSSize(width: presentationWidth, height: usesExternalSize ? 360 : 320))
        case .unavailable(let reason):
            recentHeader.stringValue = "Activity"
            recentHeader.textColor = .secondaryLabelColor
            recentHeader.isHidden = false
            recentScroll.isHidden = false
            recentText.string = "Unavailable\n\(reason)"
            // An unavailable activity stream is an inline notice, not an
            // empty dashboard. Keep it compact so the message composer stays
            // in the first viewport instead of being pushed to the bottom by
            // a minimum-height scroll region.
            recentHeightConstraint?.constant = 72
            workspaceRecentMinimumHeightConstraint?.constant = 88
            recentScroll.setContentHuggingPriority(.required, for: .vertical)
            recentScroll.setContentCompressionResistancePriority(.required, for: .vertical)
            postRecentActivityValueChanged()
            setPreferredSize(NSSize(width: presentationWidth, height: usesExternalSize ? 280 : 268))
        case .ready(let events, let moreAvailable, let runProjection):
            if let runProjection {
                recentHeader.stringValue = isLiveSession
                    ? "Live activity · \(runProjection.counts.steps) steps · \(events.count) events"
                    : "Activity · \(runProjection.counts.steps) steps · \(events.count) events"
            } else {
                recentHeader.stringValue = isLiveSession
                    ? "Live activity · \(events.count) events"
                    : (events.isEmpty ? "Activity" : "Activity · \(events.count) events")
            }
            recentHeader.textColor = isLiveSession ? OuroTheme.mint : .secondaryLabelColor
            recentHeader.isHidden = false
            recentScroll.isHidden = false
            recentHeightConstraint?.constant = 132
            workspaceRecentMinimumHeightConstraint?.constant = 220
            recentScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
            recentScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
            recentText.textStorage?.setAttributedString(
                activityText(
                    events: events,
                    runProjection: runProjection,
                    moreAvailable: moreAvailable
                )
            )
            let hadReadyPresentation: Bool
            if case .ready = previousPresentation {
                hadReadyPresentation = true
            } else {
                hadReadyPresentation = false
            }
            let shouldAutoFollow = SessionStreamRefreshPolicy.shouldAutoFollow(
                hadReadyPresentation: hadReadyPresentation,
                isLive: isLiveSession,
                wasFollowingLatest: wasFollowingLatest,
                hasStructuredProjection: runProjection != nil
            )
            if shouldAutoFollow {
                recentText.scrollToEndOfDocument(nil)
            } else if !hadReadyPresentation {
                recentText.scrollToBeginningOfDocument(nil)
            } else {
                let maximumY = max(0, recentText.bounds.height - clipView.bounds.height)
                clipView.scroll(to: NSPoint(x: 0, y: min(previousOrigin.y, maximumY)))
                recentScroll.reflectScrolledClipView(clipView)
            }
            postRecentActivityValueChanged()
            setPreferredSize(NSSize(width: presentationWidth, height: usesExternalSize ? 360 : 320))
        }
        updateWorkspaceKeyLoop()
    }

    /// Keep keyboard traversal inside the visible session work plane. The
    /// composer is optional (only an exact live attempt with verified
    /// authority gets it), so a static loop would strand keyboard users on a
    /// hidden field or make steering unreachable by Tab.
    private func updateWorkspaceKeyLoop() {
        guard isSessionWorkspace else { return }
        var visible: [NSView] = [backButton]
        if !recentScroll.isHidden { visible.append(recentScroll) }
        if !agentDiscoveryButton.isHidden { visible.append(agentDiscoveryButton) }
        if !agentMultiplexer.isHidden { visible.append(contentsOf: agentMultiplexer.keyViews) }
        if !composerPanel.isHidden {
            visible.append(composerField)
            visible.append(composerButton)
        }
        for (index, view) in visible.enumerated() {
            let next = visible[(index + 1) % visible.count]
            view.nextKeyView = next
        }
    }

    @objc private func closeDetails(_ sender: Any?) {
        onClose?()
    }

    @objc private func retryAgentDiscovery(_ sender: Any?) {
        onAgentDiscoveryRetry?()
    }

    @objc private func submitComposer(_ sender: Any?) {
        let message = composerField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard composerField.isEnabled, !message.isEmpty else { return }
        onComposerSubmit?(message)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === composerField else { return }
        composerButton.isEnabled = field.isEnabled
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onComposerDraftChange?(field.stringValue)
    }

    private func activityAccessibilitySummary(_ presentation: MCPRecentEventsPresentation) -> String {
        switch presentation {
        case .none:
            return "No activity panel"
        case .loading:
            return "Activity is loading"
        case .unavailable:
            return "Activity is unavailable"
        case .ready(let events, _, let runProjection):
            if let runProjection {
                return "Run overview is ready with \(runProjection.counts.steps) steps and \(events.count) activity events"
            }
            return events.isEmpty ? "No recent activity" : "Activity is ready"
        }
    }

    private func compactAvailability(
        _ note: String,
        recentEvents: MCPRecentEventsPresentation? = nil
    ) -> String {
        if note.hasPrefix("Expand this session to see its individual agent runs") {
            return "Expand for agent runs"
        }
        if note.hasPrefix("This is a live headless run, not a terminal") {
            if case .unavailable = recentEvents {
                return "Activity is unavailable for this run. No terminal is attached."
            }
            return "This session is running without a terminal. Follow its activity here."
        }
        if note.hasPrefix("Run ended · no live terminal is attached") {
            return "This run has ended. You can review its activity here."
        }
        return note
    }

    private func updateAccessibilityExitDescription() {
        let destination = isSessionWorkspace
            ? "Press Escape or choose Back to Sessions to return to the Sessions list."
            : "Press Escape or activate Close details to return to Connections."
        setAccessibilityHelp(
            "\(detailLabel.stringValue) \(compactAvailability(availabilityLabel.stringValue)) \(destination)"
        )
    }

    private func currentAccessibilitySummaryAnnouncement() {
        NSAccessibility.post(
            element: self,
            notification: .announcementRequested,
            userInfo: [
                .announcement: currentAccessibilitySummary,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func postRecentActivityValueChanged() {
        guard !isHidden, !recentScroll.isHidden else { return }
        NSAccessibility.post(element: recentText, notification: .valueChanged)
    }

    private func friendlyEventTitle(
        _ type: OuroborosSessionDetailProjectionV0511.EventType
    ) -> String {
        switch type {
        case .sessionStarted: "Started"
        case .attemptDispatched: "Agent started"
        case .acCompleted: "Check completed"
        case .executionTerminal: "Run finished"
        case .sessionCompleted: "Completed"
        case .sessionFailed: "Failed"
        }
    }

    private func friendlyEventSummary(
        _ event: OuroborosSessionDetailProjectionV0511.Event
    ) -> String {
        let summary = event.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty, summary.first != "{", summary.first != "[" {
            let singleLine = summary.replacingOccurrences(of: "\n", with: " ")
            return String(singleLine.prefix(280))
        }
        switch event.type {
        case .sessionStarted: return "Ouroboros began this session."
        case .attemptDispatched: return "An agent began its assigned work."
        case .acCompleted: return "The acceptance check finished."
        case .executionTerminal: return "This run reached its final state."
        case .sessionCompleted: return "The session finished successfully."
        case .sessionFailed: return "The session stopped before completion."
        }
    }

    private func friendlyTimestamp(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let normalized = value.hasSuffix("Z") ? value : "\(value)Z"
        guard let date = formatter.date(from: normalized) else {
            return String(value.prefix(16)).replacingOccurrences(of: "T", with: " ")
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func setPreferredSize(_ size: NSSize) {
        preferredContentSize = size
        if usesExternalSize { frame.size = size }
        if !usesExternalSize {
            widthConstraint?.constant = size.width
            heightConstraint?.constant = size.height
        }
        needsLayout = true
    }

    private func activityText(
        events: [OuroborosSessionDetailProjectionV0511.Event],
        runProjection: OuroborosRunProjectionV0516.Snapshot?,
        moreAvailable: Bool
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let headerParagraph = NSMutableParagraphStyle()
        headerParagraph.lineSpacing = 1
        headerParagraph.paragraphSpacing = 3
        let bodyParagraph = NSMutableParagraphStyle()
        bodyParagraph.lineSpacing = 2
        bodyParagraph.paragraphSpacing = 14

        // The MCP decoder already caps this collection at 64 events and every
        // summary at 180 characters. Do not silently throw away 59 of those
        // events at the last UI boundary: a session inspector must be useful,
        // not merely prove that a run existed.
        func append(_ text: String, font: NSFont, color: NSColor, paragraphStyle: NSMutableParagraphStyle? = nil) {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color,
            ]
            if let paragraphStyle { attributes[.paragraphStyle] = paragraphStyle }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        func countLabel(_ count: Int, _ singular: String) -> String {
            "\(count) \(singular)\(count == 1 ? "" : "s")"
        }

        if let runProjection {
            append(
                "Overview\n",
                font: OuroTheme.uiFont(size: isSessionWorkspace ? 14 : 12.5, weight: .semibold),
                color: NSColor.labelColor,
                paragraphStyle: headerParagraph
            )
            let goal = runProjection.run.goal
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !goal.isEmpty {
                append(
                    "\(String(goal.prefix(360)))\n",
                    font: OuroTheme.uiFont(size: isSessionWorkspace ? 15 : 13),
                    color: NSColor.secondaryLabelColor,
                    paragraphStyle: bodyParagraph
                )
            }
            let counts = runProjection.counts
            append(
                "\(countLabel(counts.steps, "step")) · \(countLabel(counts.stages, "stage")) · \(countLabel(counts.verdicts, "check"))\n",
                font: OuroTheme.uiFont(size: isSessionWorkspace ? 13 : 12),
                color: NSColor.tertiaryLabelColor,
                paragraphStyle: bodyParagraph
            )
            let visibleSteps = Array(runProjection.steps.suffix(64))
            let groupedSteps = Dictionary(grouping: visibleSteps) { step in
                humanStepLabel(name: step.name, kind: step.kind.rawValue)
            }
            for label in groupedSteps.keys.sorted() {
                let steps = groupedSteps[label] ?? []
                guard let step = steps.last else { continue }
                let marker: String
                let color: NSColor
                switch step.ok {
                case .some(true): marker = "✓"; color = .systemGreen
                case .some(false): marker = "!"; color = .systemOrange
                case .none: marker = "•"; color = NSColor.secondaryLabelColor
                }
                let repetition = steps.count > 1 ? " · \(steps.count) times" : ""
                append(
                    "\(marker) \(label)\(repetition)\n",
                    font: OuroTheme.uiFont(size: isSessionWorkspace ? 13.5 : 12.5),
                    color: color,
                    paragraphStyle: bodyParagraph
                )
            }
            if runProjection.steps.count > visibleSteps.count {
                append(
                    "Showing the latest \(visibleSteps.count) steps.\n\n",
                    font: OuroTheme.uiFont(size: 12),
                    color: NSColor.tertiaryLabelColor,
                    paragraphStyle: bodyParagraph
                )
            }
            append(
                "Activity\n",
                font: OuroTheme.uiFont(size: isSessionWorkspace ? 14 : 12.5, weight: .semibold),
                color: NSColor.labelColor,
                paragraphStyle: headerParagraph
            )
        }

        for event in events {
            if result.length > 0 { result.append(NSAttributedString(string: "\n")) }
            result.append(NSAttributedString(
                string: "\(friendlyEventTitle(event.type))  \(friendlyTimestamp(event.timestamp))\n",
                attributes: [
                    .font: OuroTheme.uiFont(size: isSessionWorkspace ? 13.5 : 12.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: headerParagraph,
                ]
            ))
            result.append(NSAttributedString(
                string: friendlyEventSummary(event),
                attributes: [
                    .font: OuroTheme.uiFont(size: isSessionWorkspace ? 14 : 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                    .paragraphStyle: bodyParagraph,
                ]
            ))
        }
        if result.length == 0 {
            result.append(NSAttributedString(
                string: "No recent activity",
                attributes: [
                    .font: OuroTheme.uiFont(size: 13),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            ))
        }
        if moreAvailable {
            result.append(NSAttributedString(
                string: "\n\nOlder activity is available in Ouroboros",
                attributes: [
                    .font: OuroTheme.uiFont(size: 12),
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: bodyParagraph,
                ]
            ))
        }
        return result
    }

    private func humanStepLabel(name: String, kind: String) -> String {
        let normalizedName = name
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedKind = kind
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedName.lowercased() == "typed evidence" {
            return "Evidence check"
        }
        if normalizedName.isEmpty {
            return normalizedKind.isEmpty ? "Run step" : normalizedKind.capitalized
        }
        return normalizedName.prefix(1).uppercased() + normalizedName.dropFirst()
    }

    private func statusColor(_ status: String) -> NSColor {
        switch status.lowercased() {
        case "running", "connected", "available": return .systemGreen
        case "failed", "cancelled", "limited", "offline", "unverified": return .systemOrange
        default: return .secondaryLabelColor
        }
    }
}
