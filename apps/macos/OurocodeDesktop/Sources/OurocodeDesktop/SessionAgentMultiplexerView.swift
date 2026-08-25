import AppKit

/// Full-card activation keeps the multiplexer from feeling like a read-only
/// dashboard. AppKit still gives the editor and explicit buttons their normal
/// hit targets; the remaining card surface behaves like the visible primary
/// action and provides immediate press feedback.
private final class SessionAgentCardActivationButton: NSButton {
    var onPressedChange: ((Bool) -> Void)?

    override func mouseDown(with event: NSEvent) {
        onPressedChange?(true)
        defer { onPressedChange?(false) }
        super.mouseDown(with: event)
    }
}

/// A deliberately small, bounded work plane for one Ouroboros session group.
/// Each card owns its NSTextField, so a draft can never jump to the currently
/// selected row in the rail. The view has no terminal model and creates no
/// PTY; its surface label is derived from the server-owned identity contract.
final class SessionAgentMultiplexerView: NSView {
    var onDraftChange: ((String, String) -> Void)?
    var onSubmit: ((String, String) -> Void)?
    var onPrimaryAction: ((String, SessionAgentPrimaryAction) -> Void)?

    private let header = NSTextField(labelWithString: "Agents")
    private let explanation = NSTextField(labelWithString: "Choose an agent to continue its work. Messages arrive after the current response.")
    private let grid = NSStackView()
    private var cardsByID: [String: SessionAgentCardView] = [:]
    private var currentPresentation = SessionAgentMultiplexerPresentation.hidden
    private var currentColumnCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { nil }

    func update(_ presentation: SessionAgentMultiplexerPresentation) {
        currentPresentation = presentation
        isHidden = !presentation.isVisible
        guard presentation.isVisible else {
            header.stringValue = "Agents"
            return
        }
        header.stringValue = presentation.countLabel
        explanation.stringValue = presentation.overflowCount > 0
            ? "Showing 4 agents. \(presentation.overflowCount) more remain in Sessions."
            : "Choose an agent to continue its work. Messages arrive after the current response."

        let nextIDs = Set(presentation.cards.map(\.id))
        cardsByID = cardsByID.filter { nextIDs.contains($0.key) }
        for card in presentation.cards {
            let view = cardsByID[card.id] ?? makeCard(id: card.id)
            cardsByID[card.id] = view
            view.update(card)
        }

        rebuildGrid(columnCount: desiredColumnCount())
        needsLayout = true
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    override func layout() {
        super.layout()
        guard currentPresentation.isVisible else { return }
        let nextCount = desiredColumnCount()
        if nextCount != currentColumnCount { rebuildGrid(columnCount: nextCount) }
    }

    private func desiredColumnCount() -> Int {
        min(
            max(1, currentPresentation.cards.count),
            SessionAgentMultiplexerPolicy.columnCount(availableWidth: Double(bounds.width))
        )
    }

    private func rebuildGrid(columnCount: Int) {
        currentColumnCount = columnCount
        grid.arrangedSubviews.forEach { grid.removeArrangedSubview($0); $0.removeFromSuperview() }
        let columns = (0..<columnCount).map { _ in NSStackView() }
        for column in columns {
            column.orientation = .vertical
            column.alignment = .width
            column.distribution = .fill
            column.spacing = 10
            column.translatesAutoresizingMaskIntoConstraints = false
            grid.addArrangedSubview(column)
        }
        for (index, card) in currentPresentation.cards.enumerated() {
            columns[index % columns.count].addArrangedSubview(cardsByID[card.id]!)
        }
    }

    var keyViews: [NSView] {
        currentPresentation.cards.flatMap { cardsByID[$0.id]?.keyViews ?? [] }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Live agent multiplexer")
        setAccessibilityHelp("Up to four exact Ouroboros agents can be controlled independently here. Enter Terminal opens an attached PTY. Message Agent focuses guarded MCP steering. Headless cards are MCP steering, not terminal input.")

        header.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        header.textColor = .labelColor
        header.translatesAutoresizingMaskIntoConstraints = false
        explanation.font = OuroTheme.uiFont(size: 11.5)
        explanation.textColor = .secondaryLabelColor
        explanation.maximumNumberOfLines = 2
        explanation.translatesAutoresizingMaskIntoConstraints = false

        grid.orientation = .horizontal
        grid.alignment = .top
        grid.distribution = .fillEqually
        grid.spacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(explanation)
        addSubview(grid)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            explanation.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 3),
            explanation.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            explanation.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            grid.topAnchor.constraint(equalTo: explanation.bottomAnchor, constant: 8),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            grid.heightAnchor.constraint(greaterThanOrEqualToConstant: 154)
        ])
        applyAppearance()
    }

    private func makeCard(id: String) -> SessionAgentCardView {
        let card = SessionAgentCardView(id: id)
        card.onDraftChange = { [weak self] id, draft in self?.onDraftChange?(id, draft) }
        card.onSubmit = { [weak self] id, message in self?.onSubmit?(id, message) }
        card.onPrimaryAction = { [weak self] id, action in
            self?.onPrimaryAction?(id, action)
        }
        return card
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.22).cgColor
            layer?.cornerRadius = 10
            layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.32).cgColor
            layer?.borderWidth = 0.5
        }
    }
}

private final class SessionAgentCardView: NSView, NSTextFieldDelegate {
    let id: String
    var onDraftChange: ((String, String) -> Void)?
    var onSubmit: ((String, String) -> Void)?
    var onPrimaryAction: ((String, SessionAgentPrimaryAction) -> Void)?

    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let surface = NSTextField(labelWithString: "")
    private let identity = NSTextField(labelWithString: "")
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let field = NSTextField(string: "")
    private let primaryButton = NSButton(title: "Message Agent", target: nil, action: nil)
    private let queueButton = NSButton(title: "Queue", target: nil, action: nil)
    private let receipt = NSTextField(wrappingLabelWithString: "")
    private let cardActivationButton = SessionAgentCardActivationButton()
    private var current: SessionAgentCardPresentation?
    private var cardTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPressingCard = false

    init(id: String) {
        self.id = id
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        // Static copy visually belongs to the card, so clicking it should not
        // become a dead zone. Editors and explicit buttons keep their own hit
        // targets and therefore never double-submit.
        if hit === title || hit === status || hit === surface
            || hit === identity || hit === summary || hit === receipt {
            return cardActivationButton
        }
        return hit
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let cardTrackingArea { removeTrackingArea(cardTrackingArea) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        cardTrackingArea = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        applyAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        applyAppearance()
    }

    override func cursorUpdate(with event: NSEvent) {
        if current.map({ $0.primaryAction != SessionAgentPrimaryAction.none }) ?? false {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }

    func update(_ presentation: SessionAgentCardPresentation) {
        current = presentation
        title.stringValue = presentation.title
        status.stringValue = presentation.status.capitalized
        status.textColor = (presentation.canEnterTerminal || presentation.canSteer)
            ? .systemGreen
            : .secondaryLabelColor
        surface.stringValue = presentation.surfaceLabel
        surface.textColor = presentation.canEnterTerminal
            ? .systemGreen
            : .secondaryLabelColor
        identity.stringValue = presentation.exactIdentity
        identity.toolTip = presentation.exactIdentity
        title.toolTip = presentation.exactIdentity
        surface.toolTip = presentation.exactIdentity
        summary.stringValue = presentation.summary
        receipt.stringValue = presentation.receipt
        if presentation.receipt.hasPrefix("Rejected")
            || presentation.receipt.hasPrefix("Not queued") {
            receipt.textColor = .systemRed
        } else if presentation.receipt.hasPrefix("Delivery uncertain")
                    || presentation.receipt.hasPrefix("Terminal unavailable") {
            receipt.textColor = .systemOrange
        } else if presentation.receipt.hasPrefix("Completed")
                    || presentation.receipt.hasPrefix("Applied") {
            receipt.textColor = .systemGreen
        } else {
            receipt.textColor = .secondaryLabelColor
        }
        let committedReceiptPrefixes = [
            "Queued", "Delivering", "Applied", "Completed", "Rejected", "Delivery uncertain",
        ]
        let shouldClearCommittedDraft = presentation.draft.isEmpty
            && committedReceiptPrefixes.contains(where: presentation.receipt.hasPrefix)
        if (field.currentEditor() == nil || shouldClearCommittedDraft),
           field.stringValue != presentation.draft {
            field.stringValue = presentation.draft
        }
        field.isEnabled = presentation.canSteer
        field.placeholderString = presentation.canSteer
            ? "Message this agent"
            : (presentation.canEnterTerminal ? "Use Enter Terminal" : "Messaging unavailable")
        queueButton.isEnabled = presentation.canSteer
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        primaryButton.title = presentation.primaryAction.label
        primaryButton.isEnabled = presentation.primaryAction != .none
        primaryButton.setAccessibilityLabel("\(presentation.primaryAction.label) for \(presentation.title)")
        primaryButton.setAccessibilityHelp(presentation.steeringHelp)
        receipt.setAccessibilityLabel("Delivery status for \(presentation.title)")
        receipt.setAccessibilityHelp("\(presentation.exactIdentity). \(presentation.receipt)")
        setAccessibilityLabel("\(presentation.title), \(presentation.surfaceLabel)")
        setAccessibilityHelp("\(presentation.exactIdentity). Click the card or use \(presentation.primaryAction.label). \(presentation.steeringHelp). \(presentation.receipt)")
        cardActivationButton.isEnabled = presentation.primaryAction != .none
        cardActivationButton.toolTip = presentation.steeringHelp
        applyAppearance()
    }

    func focusInput() {
        guard field.isEnabled else { return }
        window?.makeFirstResponder(field)
    }

    var keyViews: [NSView] {
        var views: [NSView] = [primaryButton]
        if field.isEnabled { views.append(contentsOf: [field, queueButton]) }
        return views
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        cardActivationButton.title = ""
        cardActivationButton.isBordered = false
        cardActivationButton.isTransparent = true
        cardActivationButton.setAccessibilityElement(false)
        cardActivationButton.target = self
        cardActivationButton.action = #selector(performPrimaryAction(_:))
        cardActivationButton.onPressedChange = { [weak self] pressed in
            self?.isPressingCard = pressed
            self?.applyAppearance()
        }
        cardActivationButton.translatesAutoresizingMaskIntoConstraints = false

        title.font = OuroTheme.uiFont(size: 13, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        status.font = OuroTheme.uiFont(size: 11.5, weight: .medium)
        status.alignment = .right
        status.translatesAutoresizingMaskIntoConstraints = false
        surface.font = OuroTheme.uiFont(size: 11.5, weight: .medium)
        surface.translatesAutoresizingMaskIntoConstraints = false
        // Keep the exact attempt visible enough to make the steering target
        // verifiable. It is deliberately tertiary typography, not a noisy
        // diagnostics header, but a person must be able to tell Agent A from
        // Agent B before sending a message.
        identity.textColor = .tertiaryLabelColor
        identity.lineBreakMode = .byTruncatingMiddle
        identity.translatesAutoresizingMaskIntoConstraints = false
        summary.font = OuroTheme.uiFont(size: 11.5)
        summary.textColor = .secondaryLabelColor
        summary.maximumNumberOfLines = 2
        summary.translatesAutoresizingMaskIntoConstraints = false
        field.font = OuroTheme.uiFont(size: 12.5)
        field.placeholderString = "Message this agent"
        field.delegate = self
        // Ordinary focus movement only persists the draft. Return is handled
        // explicitly below and maps to the same guarded Queue action.
        field.setAccessibilityLabel("Message \(id)")
        field.translatesAutoresizingMaskIntoConstraints = false

        for button in [primaryButton, queueButton] {
            button.bezelStyle = .rounded
            button.font = OuroTheme.uiFont(size: 11.5, weight: .semibold)
            button.translatesAutoresizingMaskIntoConstraints = false
        }
        primaryButton.target = self
        primaryButton.action = #selector(performPrimaryAction(_:))
        queueButton.target = self
        queueButton.action = #selector(queue(_:))
        queueButton.setAccessibilityLabel("Queue message to \(id)")

        receipt.font = OuroTheme.uiFont(size: 10.5)
        receipt.maximumNumberOfLines = 2
        receipt.lineBreakMode = .byTruncatingTail
        receipt.translatesAutoresizingMaskIntoConstraints = false

        addSubview(cardActivationButton)
        [title, status, surface, identity, summary, field, primaryButton, queueButton, receipt]
            .forEach(addSubview)
        NSLayoutConstraint.activate([
            cardActivationButton.topAnchor.constraint(equalTo: topAnchor),
            cardActivationButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            cardActivationButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            cardActivationButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 164),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            title.trailingAnchor.constraint(lessThanOrEqualTo: status.leadingAnchor, constant: -6),
            status.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            status.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            surface.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            surface.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            identity.topAnchor.constraint(equalTo: surface.bottomAnchor),
            identity.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            identity.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            summary.topAnchor.constraint(equalTo: identity.bottomAnchor, constant: 5),
            summary.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            summary.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 7),
            field.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -5),
            field.heightAnchor.constraint(equalToConstant: 26),
            primaryButton.trailingAnchor.constraint(equalTo: queueButton.leadingAnchor, constant: -4),
            primaryButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            primaryButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 104),
            queueButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            queueButton.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            queueButton.widthAnchor.constraint(equalToConstant: 54),
            receipt.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 4),
            receipt.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            receipt.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            receipt.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8)
        ])
        applyAppearance()
    }

    @objc private func performPrimaryAction(_ sender: Any?) {
        guard let action = current?.primaryAction, action != .none else { return }
        switch action {
        case .enterTerminal:
            onPrimaryAction?(id, action)
        case .messageAgent:
            focusInput()
            onPrimaryAction?(id, action)
        case .none:
            break
        }
    }

    @objc private func queue(_ sender: Any?) {
        let message = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard field.isEnabled, !message.isEmpty else { return }
        onSubmit?(id, message)
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let current, let textField = obj.object as? NSTextField, textField === field else { return }
        queueButton.isEnabled = current.canSteer
            && !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        onDraftChange?(id, field.stringValue)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard control === field, commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        queue(nil)
        return true
    }

    private func applyAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let isActionable = current.map {
                $0.primaryAction != SessionAgentPrimaryAction.none
            } ?? false
            let background: NSColor
            if isPressingCard && isActionable {
                background = NSColor.controlAccentColor.withAlphaComponent(0.16)
            } else if isPointerInside && isActionable {
                background = NSColor.controlAccentColor.withAlphaComponent(0.09)
            } else {
                background = NSColor.windowBackgroundColor.withAlphaComponent(0.72)
            }
            layer?.backgroundColor = background.cgColor
            layer?.cornerRadius = 8
            layer?.borderColor = (isPointerInside && isActionable
                ? NSColor.controlAccentColor.withAlphaComponent(0.42)
                : NSColor.separatorColor.withAlphaComponent(0.30)).cgColor
            layer?.borderWidth = isPointerInside && isActionable ? 1 : 0.5
        }
    }
}
