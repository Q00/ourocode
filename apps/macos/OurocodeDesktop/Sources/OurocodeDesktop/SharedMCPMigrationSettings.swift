import AppKit
import Foundation

private enum SharedMCPMigrationHost: CaseIterable, Hashable {
    case codexUser
    case claudeUser

    var title: String {
        switch self {
        case .codexUser: return "Codex"
        case .claudeUser: return "Claude Code"
        }
    }

    var registration: SharedMCPHostRegistration {
        switch self {
        case .codexUser: return .codex
        case .claudeUser: return .claude(scope: .user)
        }
    }

    var symbolName: String {
        switch self {
        case .codexUser: return "chevron.left.forwardslash.chevron.right"
        case .claudeUser: return "text.bubble"
        }
    }
}

private final class SharedMCPMigrationHostCard: NSView {
    private let statusLabel = NSTextField(labelWithString: "Waiting for verification")
    private let detailLabel = NSTextField(wrappingLabelWithString: "No configuration has been read.")
    private let diffLabel = NSTextField(wrappingLabelWithString: "")
    let previewButton = NSButton(title: "Preview change", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply…", target: nil, action: nil)
    let rollbackButton = NSButton(title: "Restore…", target: nil, action: nil)

    init(host: SharedMCPMigrationHost, configPath: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let surface = SolidPanelView(cornerRadius: 10)
        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        let image = NSImageView(image: NSImage(
            systemSymbolName: host.symbolName,
            accessibilityDescription: nil
        ) ?? NSImage())
        image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        image.contentTintColor = OuroTheme.muted
        image.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: host.title)
        title.font = OuroTheme.uiFont(size: 14, weight: .semibold)
        title.textColor = OuroTheme.text

        let path = NSTextField(labelWithString: configPath)
        path.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        path.textColor = OuroTheme.muted
        path.lineBreakMode = .byTruncatingMiddle
        path.setAccessibilityLabel(host.title + " user configuration path")
        path.setAccessibilityValue(configPath)

        let identity = NSStackView(views: [title, path])
        identity.orientation = .vertical
        identity.alignment = .leading
        identity.spacing = 2

        let header = NSStackView(views: [image, identity])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 9

        statusLabel.font = OuroTheme.uiFont(size: 12, weight: .medium)
        statusLabel.textColor = OuroTheme.text
        detailLabel.font = OuroTheme.uiFont(size: 11.5)
        detailLabel.textColor = OuroTheme.muted
        detailLabel.maximumNumberOfLines = 2
        diffLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        diffLabel.textColor = OuroTheme.tabText
        diffLabel.maximumNumberOfLines = 3
        diffLabel.isHidden = true

        for button in [previewButton, applyButton, rollbackButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
        }
        applyButton.keyEquivalent = ""
        applyButton.isHidden = true
        rollbackButton.isHidden = true

        let actionSpacer = NSView()
        actionSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let actions = NSStackView(views: [previewButton, actionSpacer, applyButton, rollbackButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8

        let content = NSStackView(views: [header, statusLabel, detailLabel, diffLabel, actions])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(content)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(host.title + " shared MCP migration")
        previewButton.setAccessibilityLabel("Preview " + host.title + " shared MCP change")
        applyButton.setAccessibilityLabel("Apply " + host.title + " shared MCP change")
        applyButton.setAccessibilityHelp("Requires typing the displayed confirmation phrase.")
        rollbackButton.setAccessibilityLabel("Restore " + host.title + " MCP registration")
        rollbackButton.setAccessibilityHelp("Requires typing the displayed restore phrase.")

        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.widthAnchor.constraint(equalToConstant: 24),
            image.heightAnchor.constraint(equalToConstant: 24),
            content.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: surface.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: content.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            detailLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            diffLabel.widthAnchor.constraint(equalTo: content.widthAnchor),
            actions.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func render(
        status: String,
        detail: String,
        diff: SharedMCPHostMigrationDiff?,
        statusColor: NSColor = OuroTheme.text,
        previewEnabled: Bool,
        applyVisible: Bool,
        applyEnabled: Bool,
        rollbackVisible: Bool,
        rollbackEnabled: Bool
    ) {
        statusLabel.stringValue = status
        statusLabel.textColor = statusColor
        detailLabel.stringValue = detail
        if let diff {
            diffLabel.stringValue = "BEFORE  \(diff.before)\nAFTER   \(diff.after)\nKEPT    \(diff.preservedSiblingServerCount) sibling server(s)"
            diffLabel.isHidden = false
        } else {
            diffLabel.stringValue = ""
            diffLabel.isHidden = true
        }
        previewButton.isEnabled = previewEnabled
        previewButton.title = diff == nil ? "Preview change" : "Refresh preview"
        applyButton.isHidden = !applyVisible
        applyButton.isEnabled = applyEnabled
        rollbackButton.isHidden = !rollbackVisible
        rollbackButton.isEnabled = rollbackEnabled
        setAccessibilityValue(status + ". " + detail)
    }
}

private final class SharedMCPPhraseField: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func controlTextDidChange(_ notification: Notification) {
        onChange?(stringValue)
    }
}

/// Read-only service verification plus explicit, phrase-gated host migration.
/// Merely constructing or presenting this controller never calls apply or
/// rollback. The executor sees a config only after the user selects Preview.
final class SharedMCPMigrationSettingsViewController: NSViewController {
    private enum HostState {
        case awaitingEndpoint
        case available
        case working(String)
        case unavailable(String)
        case preview(SharedMCPHostMigrationPreview)
        case applied(diff: SharedMCPHostMigrationDiff, token: SharedMCPHostRollbackToken)
        case restoreUnavailable(
            diff: SharedMCPHostMigrationDiff,
            token: SharedMCPHostRollbackToken,
            reason: String
        )
        case restored
    }

    private let runtime: SharedOuroborosServiceRuntime
    private let executor: SharedMCPHostMigrationExecutor
    private let homeDirectory: URL
    private let workQueue = DispatchQueue(
        label: "com.ourolabs.ourocode.shared-mcp-migration-review",
        qos: .userInitiated
    )
    private let endpointStatus = NSTextField(wrappingLabelWithString: "Not checked")
    private let endpointGlyph = NSImageView()
    private let refreshButton = NSButton(title: "Check connection", target: nil, action: nil)
    private var cards: [SharedMCPMigrationHost: SharedMCPMigrationHostCard] = [:]
    private var states: [SharedMCPMigrationHost: HostState] = [:]
    private var endpointAttestation: SharedMCPEndpointAttestation?
    private var verificationGeneration = 0
    private var activated = false
    private var observesRuntime = false

    init(
        runtime: SharedOuroborosServiceRuntime,
        executor: SharedMCPHostMigrationExecutor = SharedMCPHostMigrationExecutor(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runtime = runtime
        self.executor = executor
        self.homeDirectory = homeDirectory.standardizedFileURL
        super.init(nibName: nil, bundle: nil)
        for host in SharedMCPMigrationHost.allCases {
            states[host] = .awaitingEndpoint
        }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 616, height: 370))

        let title = NSTextField(labelWithString: "Shared MCP service")
        title.font = OuroTheme.uiFont(size: 17, weight: .semibold)
        title.textColor = OuroTheme.text

        let subtitle = NSTextField(wrappingLabelWithString:
            "Use one verified Ouroboros service for Codex and Claude Code instead of one stdio process per host. Nothing changes until you preview and confirm each file."
        )
        subtitle.font = OuroTheme.uiFont(size: 12)
        subtitle.textColor = OuroTheme.muted
        subtitle.maximumNumberOfLines = 2

        refreshButton.target = self
        refreshButton.action = #selector(refreshEndpoint(_:))
        refreshButton.bezelStyle = .rounded
        refreshButton.controlSize = .small
        refreshButton.setAccessibilityLabel("Check shared MCP connection")

        let headerSpacer = NSView()
        headerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let header = NSStackView(views: [title, headerSpacer, refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 12

        let endpointPanel = SolidPanelView(cornerRadius: 9)
        endpointPanel.translatesAutoresizingMaskIntoConstraints = false
        endpointGlyph.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        endpointGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .medium)
        endpointGlyph.contentTintColor = OuroTheme.muted
        endpointGlyph.translatesAutoresizingMaskIntoConstraints = false
        endpointStatus.font = OuroTheme.uiFont(size: 11.5, weight: .medium)
        endpointStatus.textColor = OuroTheme.muted
        endpointStatus.maximumNumberOfLines = 2
        endpointStatus.setAccessibilityLabel("Shared MCP service status")
        endpointStatus.translatesAutoresizingMaskIntoConstraints = false
        endpointPanel.addSubview(endpointGlyph)
        endpointPanel.addSubview(endpointStatus)
        NSLayoutConstraint.activate([
            endpointGlyph.leadingAnchor.constraint(equalTo: endpointPanel.leadingAnchor, constant: 13),
            endpointGlyph.centerYAnchor.constraint(equalTo: endpointPanel.centerYAnchor),
            endpointGlyph.widthAnchor.constraint(equalToConstant: 10),
            endpointGlyph.heightAnchor.constraint(equalToConstant: 10),
            endpointStatus.leadingAnchor.constraint(equalTo: endpointGlyph.trailingAnchor, constant: 9),
            endpointStatus.trailingAnchor.constraint(equalTo: endpointPanel.trailingAnchor, constant: -13),
            endpointStatus.topAnchor.constraint(equalTo: endpointPanel.topAnchor, constant: 10),
            endpointStatus.bottomAnchor.constraint(equalTo: endpointPanel.bottomAnchor, constant: -10),
        ])

        for host in SharedMCPMigrationHost.allCases {
            let card = SharedMCPMigrationHostCard(host: host, configPath: configPath(for: host))
            card.previewButton.target = self
            card.previewButton.action = #selector(previewHost(_:))
            card.previewButton.tag = host == .codexUser ? 1 : 2
            card.applyButton.target = self
            card.applyButton.action = #selector(confirmApply(_:))
            card.applyButton.tag = card.previewButton.tag
            card.rollbackButton.target = self
            card.rollbackButton.action = #selector(confirmRollback(_:))
            card.rollbackButton.tag = card.previewButton.tag
            cards[host] = card
        }

        let hostCards = NSStackView(views: SharedMCPMigrationHost.allCases.compactMap { cards[$0] })
        hostCards.orientation = .horizontal
        hostCards.alignment = .top
        hostCards.distribution = .fillEqually
        hostCards.spacing = 12

        let privacy = NSTextField(wrappingLabelWithString:
            "Privacy: previews contain only the transport type, executable name, shared URL, and sibling count. Arguments, environment values, tokens, and unrelated configuration never appear here."
        )
        privacy.font = OuroTheme.uiFont(size: 10.5)
        privacy.textColor = OuroTheme.muted
        privacy.maximumNumberOfLines = 2

        // Keep the privacy contract adjacent to the controls it describes.
        // A final flexible spacer absorbs extra Settings-window height instead
        // of allowing AppKit's gravity-area distribution to split the section.
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        bottomSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let stack = NSStackView(views: [
            header,
            subtitle,
            endpointPanel,
            hostCards,
            privacy,
            bottomSpacer,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.distribution = .fill
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            stack.topAnchor.constraint(equalTo: root.topAnchor),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            header.widthAnchor.constraint(equalTo: stack.widthAnchor),
            subtitle.widthAnchor.constraint(equalTo: stack.widthAnchor),
            endpointPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hostCards.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hostCards.heightAnchor.constraint(greaterThanOrEqualToConstant: 205),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bottomSpacer.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        view = root
        preferredContentSize = NSSize(width: 616, height: 370)
        renderAllHosts()
    }

    /// Called when Settings becomes visible. This performs only a bounded,
    /// read-only ownership/readiness check; host configs remain unopened.
    func activate() {
        _ = view
        if !observesRuntime {
            observesRuntime = true
            runtime.whenSettled { [weak self] _ in
                guard let self, self.activated else { return }
                self.beginEndpointVerification()
            }
        }
        guard !activated else { return }
        activated = true
        beginEndpointVerification()
    }

    @objc private func refreshEndpoint(_ sender: Any?) {
        beginEndpointVerification()
    }

    private func beginEndpointVerification() {
        verificationGeneration += 1
        let generation = verificationGeneration
        endpointAttestation = nil
        endpointStatus.stringValue = "Checking owner-only service artifacts and MCP v2 readiness…"
        endpointStatus.textColor = OuroTheme.muted
        endpointGlyph.contentTintColor = OuroTheme.muted
        endpointStatus.setAccessibilityValue(endpointStatus.stringValue)
        refreshButton.isEnabled = false
        renderAllHosts()

        let home = homeDirectory
        workQueue.async { [weak self] in
            let paths = SharedOuroborosServiceSupervisor.Paths(
                launchAgentsDirectory: home.appendingPathComponent("Library/LaunchAgents").path,
                contractDirectory: home.appendingPathComponent("Library/Application Support/Ourocode").path
            )
            let result = SharedOuroborosServiceSupervisor().attachToExistingService(paths: paths)
            DispatchQueue.main.async {
                guard let self, self.verificationGeneration == generation else { return }
                self.finishEndpointVerification(result)
            }
        }
    }

    private func finishEndpointVerification(
        _ result: Result<OuroborosManagedEndpoint?, SharedOuroborosActivationFailure>
    ) {
        refreshButton.isEnabled = true
        refreshButton.title = "Check again"
        switch result {
        case .success(.some(let managedEndpoint))
            where managedEndpoint.endpoint == SharedOuroborosResolver.defaultEndpoint:
            let endpoint = managedEndpoint.endpoint
            endpointAttestation = SharedMCPEndpointAttestation(
                endpoint: endpoint,
                supervisorLabel: SharedOuroborosResolver.sharedLaunchdLabel,
                contractSchemaVersion: 5,
                serviceVersion: SharedOuroborosResolver.requiredVersion,
                ownershipArtifactsVerified: true,
                readinessProbeSucceeded: true
            )
            endpointStatus.stringValue = "Verified · Ouroboros "
                + SharedOuroborosResolver.requiredVersion.description
                + " · " + endpoint.absoluteString
            endpointStatus.textColor = OuroTheme.text
            endpointGlyph.contentTintColor = OuroTheme.mint
            endpointStatus.setAccessibilityValue(endpointStatus.stringValue)
            for host in SharedMCPMigrationHost.allCases {
                if case .awaitingEndpoint = states[host] { states[host] = .available }
                if case .restored = states[host] { states[host] = .available }
            }
        case .success, .failure:
            endpointAttestation = nil
            endpointStatus.stringValue = "Unavailable · Ownership artifacts and an exact MCP v2 readiness response were not both verified."
            endpointStatus.textColor = NSColor.systemOrange
            endpointGlyph.contentTintColor = NSColor.systemOrange
            endpointStatus.setAccessibilityValue(endpointStatus.stringValue)
        }
        renderAllHosts()
        NSAccessibility.post(element: endpointStatus, notification: .valueChanged)
    }

    @objc private func previewHost(_ sender: NSButton) {
        guard let host = host(for: sender.tag), let endpointAttestation else { return }
        let configTarget: SharedMCPHostConfigTarget
        switch target(for: host) {
        case .success(let value): configTarget = value
        case .failure(let failure):
            states[host] = .unavailable(failureDescription(failure))
            render(host)
            return
        }
        states[host] = .working("Reviewing the named Ouroboros entry…")
        render(host)
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.executor.preview(target: configTarget, endpoint: endpointAttestation)
            DispatchQueue.main.async {
                switch result {
                case .success(let preview): self.states[host] = .preview(preview)
                case .failure(let failure): self.states[host] = .unavailable(self.failureDescription(failure))
                }
                self.render(host)
                if let card = self.cards[host] {
                    NSAccessibility.post(element: card, notification: .valueChanged)
                }
            }
        }
    }

    @objc private func confirmApply(_ sender: NSButton) {
        guard let host = host(for: sender.tag),
              case .preview(let preview) = states[host],
              endpointAttestation != nil else { return }
        presentPhraseConfirmation(
            title: "Use the shared service for " + host.title + "?",
            explanation: "This atomically replaces only the reviewed Ouroboros entry. A private rollback snapshot is kept until you restore it or quit Ourocode.",
            phrase: SharedMCPHostMigrationPlanner.applyConfirmationPhrase,
            confirmTitle: "Apply"
        ) { [weak self] phrase in
            self?.apply(host: host, preview: preview, phrase: phrase)
        }
    }

    private func apply(
        host: SharedMCPMigrationHost,
        preview: SharedMCPHostMigrationPreview,
        phrase: String
    ) {
        states[host] = .working("Applying the reviewed change…")
        render(host)
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.executor.apply(
                previewID: preview.planID,
                confirmation: SharedMCPApplyConfirmation(planID: preview.planID, phrase: phrase)
            )
            DispatchQueue.main.async {
                switch result {
                case .success(let token): self.states[host] = .applied(diff: preview.diff, token: token)
                case .failure(let failure): self.states[host] = .unavailable(self.failureDescription(failure))
                }
                self.render(host)
                if let card = self.cards[host] {
                    NSAccessibility.post(element: card, notification: .valueChanged)
                }
            }
        }
    }

    @objc private func confirmRollback(_ sender: NSButton) {
        guard let host = host(for: sender.tag), let state = states[host] else { return }
        let diff: SharedMCPHostMigrationDiff
        let token: SharedMCPHostRollbackToken
        switch state {
        case .applied(let value, let authority),
             .restoreUnavailable(let value, let authority, _):
            diff = value
            token = authority
        default:
            return
        }
        presentPhraseConfirmation(
            title: "Restore the previous " + host.title + " entry?",
            explanation: "Restore succeeds only if the host file still matches the change Ourocode applied.",
            phrase: SharedMCPHostMigrationExecutor.rollbackConfirmationPhrase,
            confirmTitle: "Restore"
        ) { [weak self] phrase in
            self?.rollback(host: host, diff: diff, token: token, phrase: phrase)
        }
    }

    private func rollback(
        host: SharedMCPMigrationHost,
        diff: SharedMCPHostMigrationDiff,
        token: SharedMCPHostRollbackToken,
        phrase: String
    ) {
        states[host] = .working("Restoring the private rollback snapshot…")
        render(host)
        workQueue.async { [weak self] in
            guard let self else { return }
            let result = self.executor.rollback(
                token,
                confirmation: SharedMCPHostRollbackConfirmation(tokenID: token.id, phrase: phrase)
            )
            DispatchQueue.main.async {
                switch result {
                case .success: self.states[host] = .restored
                case .failure(let failure):
                    self.states[host] = .restoreUnavailable(
                        diff: diff,
                        token: token,
                        reason: self.failureDescription(failure)
                    )
                }
                self.render(host)
                if let card = self.cards[host] {
                    NSAccessibility.post(element: card, notification: .valueChanged)
                }
            }
        }
    }

    private func presentPhraseConfirmation(
        title: String,
        explanation: String,
        phrase: String,
        confirmTitle: String,
        completion: @escaping (String) -> Void
    ) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = explanation
        let confirm = alert.addButton(withTitle: confirmTitle)
        confirm.isEnabled = false
        alert.addButton(withTitle: "Cancel")

        let prompt = NSTextField(wrappingLabelWithString: "Type exactly:\n" + phrase)
        prompt.font = OuroTheme.uiFont(size: 11)
        prompt.textColor = OuroTheme.muted
        let field = SharedMCPPhraseField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "Confirmation phrase"
        field.setAccessibilityLabel(confirmTitle + " confirmation phrase")
        field.setAccessibilityHelp("Type the exact phrase shown above to enable " + confirmTitle + ".")
        field.onChange = { value in confirm.isEnabled = value == phrase }
        let accessory = NSStackView(views: [prompt, field])
        accessory.orientation = .vertical
        accessory.alignment = .leading
        accessory.spacing = 8
        accessory.frame = NSRect(x: 0, y: 0, width: 360, height: 62)
        prompt.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn, field.stringValue == phrase else { return }
            completion(field.stringValue)
        }
    }

    private func renderAllHosts() {
        for host in SharedMCPMigrationHost.allCases { render(host) }
    }

    private func render(_ host: SharedMCPMigrationHost) {
        guard isViewLoaded, let card = cards[host], let state = states[host] else { return }
        let endpointReady = endpointAttestation != nil
        switch state {
        case .awaitingEndpoint:
            card.render(
                status: endpointReady ? "Ready to review" : "Shared service not verified",
                detail: endpointReady ? "Preview reads only the named user-level Ouroboros entry." : "No configuration has been read or changed.",
                diff: nil,
                previewEnabled: endpointReady,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        case .available:
            card.render(
                status: "Ready to review",
                detail: "Preview reads only the named user-level Ouroboros entry.",
                diff: nil,
                previewEnabled: endpointReady,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        case .working(let detail):
            card.render(
                status: "Working…",
                detail: detail,
                diff: nil,
                previewEnabled: false,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        case .unavailable(let reason):
            card.render(
                status: "Unavailable",
                detail: reason,
                diff: nil,
                statusColor: NSColor.systemOrange,
                previewEnabled: endpointReady,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        case .preview(let preview):
            card.render(
                status: "Reviewed · no changes yet",
                detail: "Type the confirmation phrase to apply this exact preview.",
                diff: preview.diff,
                previewEnabled: endpointReady,
                applyVisible: true,
                applyEnabled: endpointReady,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        case .applied(let diff, _):
            card.render(
                status: "Using the shared service",
                detail: "The previous entry can be restored while this window remains open.",
                diff: diff,
                statusColor: OuroTheme.mint,
                previewEnabled: false,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: true,
                rollbackEnabled: true
            )
        case .restoreUnavailable(let diff, _, let reason):
            card.render(
                status: "Restore unavailable",
                detail: reason,
                diff: diff,
                statusColor: NSColor.systemOrange,
                previewEnabled: false,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: true,
                rollbackEnabled: true
            )
        case .restored:
            card.render(
                status: "Previous entry restored",
                detail: "Preview again if you want to return to the shared service.",
                diff: nil,
                previewEnabled: endpointReady,
                applyVisible: false,
                applyEnabled: false,
                rollbackVisible: false,
                rollbackEnabled: false
            )
        }
    }

    private func host(for tag: Int) -> SharedMCPMigrationHost? {
        switch tag {
        case 1: return .codexUser
        case 2: return .claudeUser
        default: return nil
        }
    }

    private func target(
        for host: SharedMCPMigrationHost
    ) -> Result<SharedMCPHostConfigTarget, SharedMCPHostMigrationExecutionFailure> {
        SharedMCPHostConfigLocator.supportedTarget(
            registration: host.registration,
            homeDirectory: homeDirectory
        )
    }

    private func configPath(for host: SharedMCPMigrationHost) -> String {
        switch target(for: host) {
        case .success(let target): return target.configURL.path
        case .failure: return "User configuration unavailable"
        }
    }

    private func failureDescription(_ failure: SharedMCPHostMigrationExecutionFailure) -> String {
        switch failure {
        case .targetMissingOrNotRegularFile:
            return "The user configuration file was not found or is not a regular file."
        case .targetIsSymbolicLink:
            return "Symbolic-link configuration files are not edited."
        case .targetNotOwnedByCurrentUser:
            return "The configuration is not owned by the current user."
        case .targetPermissionsNotOwnerOnly:
            return "The configuration is not owner-only (0600), so Ourocode will not read it."
        case .targetHasMultipleHardLinks:
            return "Hard-linked configuration files are not edited."
        case .configTooLarge:
            return "The configuration exceeds the 1 MiB review limit."
        case .registrationMissing:
            return "No explicit Ouroboros entry exists in this user configuration. There is nothing to migrate."
        case .unsupportedConfigShape:
            return "The Ouroboros entry uses a shape this version cannot safely preserve."
        case .registrationDoesNotMatchConfig:
            return "The selected user registration does not match this configuration."
        case .invalidTargetPath:
            return "The exact user configuration path is unavailable."
        case .planner(let failure):
            return plannerFailureDescription(failure)
        case .previewNotFound:
            return "This preview expired. Preview the change again."
        case .targetChangedAfterPreview:
            return "The host changed its configuration after preview. Review it again."
        case .backupStorageUnsafe, .backupWriteFailed:
            return "A private owner-only rollback snapshot could not be created."
        case .atomicWriteFailed:
            return "The atomic configuration update did not complete."
        case .rollbackTokenUnknown:
            return "The restore authority is no longer available."
        case .rollbackConfirmationMismatch:
            return "The restore confirmation phrase did not match."
        case .rollbackTargetChanged:
            return "The host changed its configuration after apply, so restore was stopped."
        case .rollbackBackupInvalid:
            return "The private rollback snapshot could not be verified."
        case .tooManyLiveRollbackTokens:
            return "Too many pending restores are open. Restart Ourocode before reviewing again."
        }
    }

    private func plannerFailureDescription(_ failure: SharedMCPHostMigrationFailure) -> String {
        switch failure {
        case .endpointNotLoopback, .endpointUnverified:
            return "The shared endpoint is no longer verified. Check the connection again."
        case .invalidServerName, .notOuroboros, .notStdio:
            return "The named entry is not a supported Ouroboros stdio registration."
        case .missingOrInvalidRollbackMetadata:
            return "A safe rollback identity could not be created."
        case .unsupportedClaudeScope:
            return "Only the Claude Code user registration is supported here."
        case .claudePluginCannotBeDisabledOrOverridden:
            return "Plugin-owned Claude MCP entries must be managed by their plugin."
        case .applyConfirmationMismatch:
            return "The apply confirmation phrase did not match."
        }
    }
}
