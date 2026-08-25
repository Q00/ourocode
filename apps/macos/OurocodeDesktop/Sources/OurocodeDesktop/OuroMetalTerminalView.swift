#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import MetalKit
  import QuartzCore

  protocol OuroTerminalInputSink: AnyObject {
    func terminalView(_ view: OuroMetalTerminalView, key: NormalizedTerminalKey)
    func terminalView(_ view: OuroMetalTerminalView, commitText text: String)
    func terminalView(_ view: OuroMetalTerminalView, performCommand selectorName: String)
    func terminalView(_ view: OuroMetalTerminalView, mouse event: OuroTerminalMouseEvent)
    func terminalView(_ view: OuroMetalTerminalView, openHyperlinkAt point: NSPoint) -> Bool
    func terminalViewCancelPointerGestures(_ view: OuroMetalTerminalView)
    func terminalView(_ view: OuroMetalTerminalView, paste text: String)
    func terminalView(_ view: OuroMetalTerminalView, focusChanged focused: Bool)
  }

  extension OuroTerminalInputSink {
    func terminalView(_ view: OuroMetalTerminalView, mouse event: OuroTerminalMouseEvent) {}
    func terminalViewCancelPointerGestures(_ view: OuroMetalTerminalView) {}
    func terminalView(_ view: OuroMetalTerminalView, openHyperlinkAt point: NSPoint) -> Bool { false }
  }

  /// One selected terminal surface. Marked text is local and never reaches the
  /// broker; `insertText` is the sole IME commit path.
  final class OuroMetalTerminalView: MTKView, NSTextInputClient {
    weak var inputSink: OuroTerminalInputSink?
    var onMarkedTextChange: ((NSAttributedString?, NSRange) -> Void)?
    private(set) var inputEnabled = false
    private(set) var interactionEnabled = false
    let terminalRenderer: OuroTerminalRenderer

    private let markedTextState = OuroTerminalMarkedTextState()
    private lazy var terminalTextInputContext = NSTextInputContext(client: self)
    private struct KeyInterpretation {
      let event: MacKeyboardEvent
      let hadMarkedText: Bool
      let markedTextAtStart: String
      var changedMarkedText = false
      var insertedText: [String] = []
      var commandSelectors: [String] = []
    }
    private var keyInterpretation: KeyInterpretation?
    private var brokerPressedKeyCodes: Set<UInt16> = []
    private var pressedModifierKeyCodes: Set<UInt16> = []
    private var terminalCellSize = CGSize(width: 8, height: 16)
    private let markedTextPresentation = NSTextField(labelWithString: "")
    private var pointerTrackingArea: NSTrackingArea?
    private var bellResetWorkItem: DispatchWorkItem?
    private lazy var terminalAccessibility = OuroTerminalAccessibilityController(view: self)
    private lazy var appearanceMonitor: OuroTerminalAppearanceMonitor = {
      let monitor = OuroTerminalAppearanceMonitor()
      monitor.onChange = { [weak self] appearance in
        self?.terminalRenderer.updateAppearance(appearance)
      }
      return monitor
    }()

    init(frame: NSRect, device: MTLDevice, renderer: OuroTerminalRenderer) {
      terminalRenderer = renderer
      super.init(frame: frame, device: device)
      configureMetalView()
      registerForDraggedTypes([.fileURL])
      configureMarkedTextPresentation()
      renderer.attach(to: self)
      _ = terminalAccessibility
      _ = appearanceMonitor
    }

    required init(coder: NSCoder) {
      fatalError("OuroMetalTerminalView must be created with an audited Metal renderer")
    }

    override var acceptsFirstResponder: Bool { interactionEnabled }
    override var isOpaque: Bool { true }
    override var inputContext: NSTextInputContext? { terminalTextInputContext }

    override func viewDidChangeEffectiveAppearance() {
      super.viewDidChangeEffectiveAppearance()
      effectiveAppearance.performAsCurrentDrawingAppearance {
        appearanceMonitor.refresh()
        updateMetalClearColor(appearanceMonitor.value)
        updateMarkedTextAppearance()
      }
    }

    override func layout() {
      super.layout()
      updateMarkedTextPresentation()
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
      let area = NSTrackingArea(
        rect: bounds,
        options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect],
        owner: self,
        userInfo: nil
      )
      addTrackingArea(area)
      pointerTrackingArea = area
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
      interactionEnabled ? super.hitTest(point) : nil
    }

    func setInteractionEnabled(_ enabled: Bool) {
      if interactionEnabled, !enabled {
        inputSink?.terminalViewCancelPointerGestures(self)
      }
      interactionEnabled = enabled
      if !enabled { setInputEnabled(false) }
    }

    func setInputEnabled(_ enabled: Bool) {
      guard inputEnabled != enabled else { return }
      inputEnabled = enabled
      if !enabled {
        brokerPressedKeyCodes.removeAll(keepingCapacity: true)
        pressedModifierKeyCodes.removeAll(keepingCapacity: true)
        inputContext?.discardMarkedText()
        unmarkText()
      }
    }

    func setCellSize(
      _ value: CGSize,
      fontPointSize: CGFloat = OuroTheme.terminalFontSize
    ) {
      guard value.width > 0, value.height > 0 else { return }
      terminalCellSize = value
      markedTextPresentation.font = OuroTheme.monoFont(size: fontPointSize)
      updateMarkedTextPresentation()
    }

    func setTerminalAccessibilityVisible(_ visible: Bool) {
      terminalAccessibility.setVisible(visible)
    }

    func updateTerminalAccessibility(_ snapshot: OuroTerminalAccessibilitySnapshot) {
      terminalAccessibility.update(snapshot)
    }

    func replaceTerminalAccessibility(_ snapshot: OuroTerminalAccessibilitySnapshot) {
      terminalAccessibility.replace(snapshot)
    }

    func refreshMarkedTextPresentation() {
      updateMarkedTextPresentation()
    }

    func presentBell(count: UInt32) {
      guard count > 0 else { return }
      NSAccessibility.post(
        element: self,
        notification: .announcementRequested,
        userInfo: [
          .announcement: count == 1 ? "Terminal bell" : "\(count) terminal bells",
          .priority: NSAccessibilityPriorityLevel.medium.rawValue,
        ]
      )
      if TerminalPreferences.audibleBell { NSSound.beep() }
      guard TerminalPreferences.visualBell else { return }
      bellResetWorkItem?.cancel()
      layer?.borderColor = OuroTheme.mint.cgColor
      layer?.borderWidth = OuroTheme.accessibility.increaseContrast ? 3 : 2
      let reset = DispatchWorkItem { [weak self] in
        guard let self else { return }
        self.layer?.borderWidth = 0
      }
      bellResetWorkItem = reset
      let duration: TimeInterval = OuroTheme.accessibility.reduceTransparency ? 0.12 : 0.24
      DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: reset)
    }

    override func becomeFirstResponder() -> Bool {
      let result = super.becomeFirstResponder()
      if result {
        terminalTextInputContext.activate()
        terminalRenderer.updateFocus(true)
        terminalRenderer.requestRetainedRedraw()
        inputSink?.terminalView(self, focusChanged: true)
      }
      return result
    }

    override func resignFirstResponder() -> Bool {
      let result = super.resignFirstResponder()
      if result {
        terminalTextInputContext.deactivate()
        terminalRenderer.updateFocus(false)
        terminalRenderer.requestRetainedRedraw()
        inputSink?.terminalViewCancelPointerGestures(self)
        inputSink?.terminalView(self, focusChanged: false)
      }
      return result
    }

    override func keyDown(with event: NSEvent) {
      guard inputEnabled else {
        NSSound.beep()
        return
      }
      let value = MacKeyboardEvent(event)
      keyInterpretation = KeyInterpretation(
        event: value,
        hadMarkedText: hasMarkedText(),
        markedTextAtStart: markedTextState.string
      )
      interpretKeyEvents([event])
      guard let interpretation = keyInterpretation else { return }
      keyInterpretation = nil

      var insertedText = interpretation.insertedText
      // Some IMEs finalize their last marked syllable through
      // doCommandBySelector (Space is the Korean 2-Set example) without first
      // calling insertText. The command is still part of this physical key
      // interpretation, so commit the retained preedit before forwarding that
      // key. A non-empty replacement preedit remains composition and is never
      // committed here.
      if let retained = OuroTerminalIMECommitPolicy.retainedCommit(
        hadMarkedText: interpretation.hadMarkedText,
        markedTextAtStart: interpretation.markedTextAtStart,
        markedTextAfterInterpretation: markedTextState.string,
        insertedText: insertedText,
        commandSelectors: interpretation.commandSelectors
      ) {
        insertedText.append(retained)
        markedTextState.clear()
        onMarkedTextChange?(nil, NSRange())
        updateMarkedTextPresentation()
      }

      var events = MacKeyboardNormalizer.keyDownEvents(
        event: interpretation.event,
        hadMarkedText: interpretation.hadMarkedText,
        changedMarkedText: interpretation.changedMarkedText,
        insertedText: insertedText,
        activeRightModifiers: MacKeyboardNormalizer.activeRightModifiers(
          for: pressedModifierKeyCodes)
      )

      if !interpretation.commandSelectors.isEmpty {
        let physical = MacKeyboardNormalizer.keyDownEvents(
          event: interpretation.event,
          hadMarkedText: false,
          changedMarkedText: false,
          insertedText: [],
          activeRightModifiers: MacKeyboardNormalizer.activeRightModifiers(
            for: pressedModifierKeyCodes)
        )
        events = MacKeyboardNormalizer.mergingCommandSelectorFallback(
          primary: events,
          physical: physical,
          committedText: insertedText.joined()
        )
      }
      deliverKeyDownEvents(events, physicalKeyCode: value.keyCode)
    }

    override func keyUp(with event: NSEvent) {
      guard inputEnabled else { return }
      let value = MacKeyboardEvent(event)
      guard brokerPressedKeyCodes.remove(value.keyCode) != nil,
        let key = MacKeyboardNormalizer.key(
          from: value,
          action: .release,
          activeRightModifiers: MacKeyboardNormalizer.activeRightModifiers(
            for: pressedModifierKeyCodes)
        )
      else { return }
      inputSink?.terminalView(self, key: key)
    }

    override func flagsChanged(with event: NSEvent) {
      guard inputEnabled else { return }
      let value = MacKeyboardEvent(event)
      let wasTracked = pressedModifierKeyCodes.contains(value.keyCode)
      guard
        let action = MacKeyboardNormalizer.modifierAction(
          for: value,
          wasTracked: wasTracked
        )
      else { return }
      if action == .press {
        pressedModifierKeyCodes.insert(value.keyCode)
      } else {
        pressedModifierKeyCodes.remove(value.keyCode)
      }
      guard
        let key = MacKeyboardNormalizer.modifierKey(
          from: value,
          action: action,
          activeRightModifiers: MacKeyboardNormalizer.activeRightModifiers(
            for: pressedModifierKeyCodes)
        )
      else { return }
      inputSink?.terminalView(self, key: key)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
      guard inputEnabled else { return }
      let value: String
      if let attributed = string as? NSAttributedString {
        value = attributed.string
      } else if let text = string as? String {
        value = text
      } else {
        return
      }
      markedTextState.clear()
      onMarkedTextChange?(nil, NSRange())
      updateMarkedTextPresentation()
      let normalized = OuroTerminalCommittedText.normalize(value)
      guard !normalized.isEmpty else { return }
      if keyInterpretation != nil {
        keyInterpretation?.insertedText.append(normalized)
        return
      }
      inputSink?.terminalView(self, commitText: normalized)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      guard inputEnabled else { return }
      let raw: String
      if let attributed = string as? NSAttributedString {
        raw = attributed.string
      } else if let text = string as? String {
        raw = text
      } else {
        return
      }
      let normalized = OuroTerminalCommittedText.normalize(raw)
      let value = NSAttributedString(
        string: normalized,
        attributes: [.font: OuroTheme.monoFont(size: OuroTheme.terminalFontSize)]
      )
      markedTextState.replace(with: value, selectedRange: selectedRange)
      keyInterpretation?.changedMarkedText = true
      onMarkedTextChange?(markedTextState.attributedText, markedTextState.selection)
      updateMarkedTextPresentation()
      terminalRenderer.requestRetainedRedraw()
    }

    func unmarkText() {
      guard markedTextState.clear() else { return }
      onMarkedTextChange?(nil, NSRange())
      updateMarkedTextPresentation()
      terminalRenderer.requestRetainedRedraw()
    }

    func selectedRange() -> NSRange {
      markedTextState.selectedRange
    }

    func markedRange() -> NSRange {
      markedTextState.markedRange
    }

    func hasMarkedText() -> Bool {
      markedTextState.hasMarkedText
    }

    func attributedSubstring(
      forProposedRange range: NSRange,
      actualRange: NSRangePointer?
    ) -> NSAttributedString? {
      let actual = markedTextState.actualRange(for: range)
      guard let value = markedTextState.attributedSubstring(forProposedRange: range) else {
        return nil
      }
      actualRange?.pointee = actual
      return value
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
      [.font, .foregroundColor, .backgroundColor, .underlineStyle]
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
      actualRange?.pointee = markedTextState.actualRange(for: range)
      return terminalRenderer.cursorScreenRect(in: self)
    }

    func characterIndex(for point: NSPoint) -> Int {
      NSNotFound
    }

    override func doCommand(by selector: Selector) {
      guard inputEnabled else { return }
      if keyInterpretation != nil {
        keyInterpretation?.commandSelectors.append(NSStringFromSelector(selector))
        return
      }
      inputSink?.terminalView(self, performCommand: NSStringFromSelector(selector))
    }

    override func mouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      if event.buttonNumber == 0, event.modifierFlags.contains(.command) {
        if inputSink?.terminalView(
          self,
          openHyperlinkAt: convert(event.locationInWindow, from: nil)
        ) == true {
          return
        }
      }
      sendMouse(.down, event)
    }

    override func mouseDragged(with event: NSEvent) {
      sendMouse(.drag, event)
    }

    override func mouseUp(with event: NSEvent) {
      sendMouse(.up, event)
    }

    override func rightMouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      sendMouse(.down, event)
    }

    override func rightMouseDragged(with event: NSEvent) { sendMouse(.drag, event) }
    override func rightMouseUp(with event: NSEvent) { sendMouse(.up, event) }

    override func otherMouseDown(with event: NSEvent) {
      window?.makeFirstResponder(self)
      sendMouse(.down, event)
    }

    override func otherMouseDragged(with event: NSEvent) { sendMouse(.drag, event) }
    override func otherMouseUp(with event: NSEvent) { sendMouse(.up, event) }

    override func mouseMoved(with event: NSEvent) { sendMouse(.move, event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
      guard inputEnabled,
        let paths = sender.draggingPasteboard.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
        TerminalPathDrop.shellInput(for: paths) != nil
      else { return [] }
      return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
      draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      guard inputEnabled,
        let paths = sender.draggingPasteboard.readObjects(
          forClasses: [NSURL.self],
          options: [.urlReadingFileURLsOnly: true]
        ) as? [URL],
        let input = TerminalPathDrop.shellInput(for: paths)
      else { return false }
      window?.makeFirstResponder(self)
      inputSink?.terminalView(self, commitText: input)
      return true
    }

    override func scrollWheel(with event: NSEvent) {
      sendMouse(.scroll, event)
    }

    @objc func paste(_ sender: Any?) {
      guard inputEnabled,
        let value = NSPasteboard.general.string(forType: .string),
        !value.isEmpty
      else { return }
      inputSink?.terminalView(self, paste: value)
    }

    @objc func copy(_ sender: Any?) {
      guard interactionEnabled else {
        NSSound.beep()
        return
      }
      inputSink?.terminalView(self, performCommand: "copy:")
    }

    @objc override func selectAll(_ sender: Any?) {
      guard interactionEnabled else {
        NSSound.beep()
        return
      }
      inputSink?.terminalView(self, performCommand: "selectAll:")
    }

    private func configureMetalView() {
      isPaused = TerminalMetalSurfaceMemoryPolicy.isPaused
      enableSetNeedsDisplay = TerminalMetalSurfaceMemoryPolicy.enableSetNeedsDisplay
      framebufferOnly = TerminalMetalSurfaceMemoryPolicy.framebufferOnly
      autoResizeDrawable = true
      colorPixelFormat = .bgra8Unorm_srgb
      updateMetalClearColor(.current())
      preferredFramesPerSecond = 30
      wantsLayer = true
      if let metalLayer = layer as? CAMetalLayer {
        metalLayer.maximumDrawableCount = TerminalMetalSurfaceMemoryPolicy.maximumDrawableCount
        metalLayer.presentsWithTransaction = TerminalMetalSurfaceMemoryPolicy.presentsWithTransaction
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      }
    }

    private func configureMarkedTextPresentation() {
      markedTextPresentation.font = OuroTheme.monoFont(size: OuroTheme.terminalFontSize)
      markedTextPresentation.lineBreakMode = .byClipping
      markedTextPresentation.isHidden = true
      markedTextPresentation.wantsLayer = true
      markedTextPresentation.layer?.cornerRadius = 3
      markedTextPresentation.setAccessibilityLabel("Input method composition")
      addSubview(markedTextPresentation)
      updateMarkedTextAppearance()
    }

    private func updateMarkedTextAppearance() {
      markedTextPresentation.textColor = OuroTheme.text
      markedTextPresentation.layer?.backgroundColor = OuroTheme.elevated.withAlphaComponent(
        OuroTheme.accessibility.reduceTransparency ? 1 : 0.94
      ).cgColor
      markedTextPresentation.layer?.borderColor = OuroTheme.border.cgColor
      markedTextPresentation.layer?.borderWidth = OuroTheme.accessibility.increaseContrast ? 1 : 0.5
    }

    private func updateMarkedTextPresentation() {
      let wasVisible = !markedTextPresentation.isHidden
      guard inputEnabled, markedTextState.hasMarkedText, let window else {
        markedTextPresentation.isHidden = true
        if wasVisible {
          NSAccessibility.post(element: self, notification: .layoutChanged)
        }
        return
      }
      let previousValue = markedTextPresentation.stringValue
      markedTextPresentation.stringValue = markedTextState.string
      markedTextPresentation.setAccessibilityValue(markedTextState.string)
      let cursorScreen = terminalRenderer.cursorScreenRect(in: self)
      let cursor = convert(window.convertFromScreen(cursorScreen), from: nil)
      let fitting = markedTextPresentation.fittingSize
      let width = min(max(cursor.width, fitting.width + 8), max(1, bounds.width - cursor.minX))
      let height = max(cursor.height, fitting.height + 4)
      markedTextPresentation.frame = NSRect(
        x: max(0, cursor.minX),
        y: max(0, min(cursor.minY, bounds.height - height)),
        width: width,
        height: height
      )
      markedTextPresentation.isHidden = false
      if previousValue != markedTextState.string {
        NSAccessibility.post(element: markedTextPresentation, notification: .valueChanged)
      }
      if !wasVisible {
        NSAccessibility.post(element: self, notification: .layoutChanged)
      }
    }

    private func updateMetalClearColor(_ appearance: OuroTerminalAppearance) {
      clearColor = MTLClearColorMake(
        Double(appearance.canvas.x),
        Double(appearance.canvas.y),
        Double(appearance.canvas.z),
        Double(appearance.canvas.w)
      )
      terminalRenderer.requestRetainedRedraw()
    }

    private func sendMouse(_ kind: OuroTerminalMouseEvent.Kind, _ event: NSEvent) {
      guard interactionEnabled else { return }
      let value = OuroTerminalMouseEvent(
        kind: kind,
        event: event,
        locationInView: convert(event.locationInWindow, from: nil)
      )
      if kind == .scroll {
        TerminalScrollRuntimeTrace.record(
          "appkit",
          "deltaX=\(value.deltaX) deltaY=\(value.deltaY) precise=\(value.hasPreciseScrollingDeltas) phase=\(value.phase.rawValue) momentum=\(value.momentumPhase.rawValue) inverted=\(event.isDirectionInvertedFromDevice)"
        )
      }
      inputSink?.terminalView(
        self,
        mouse: value
      )
    }

    private func deliverKeyDownEvents(
      _ events: [NormalizedTerminalInputEvent],
      physicalKeyCode: UInt16
    ) {
      for event in events {
        switch event {
        case .key(let key):
          brokerPressedKeyCodes.insert(physicalKeyCode)
          inputSink?.terminalView(self, key: key)
        case .committedText(let text):
          inputSink?.terminalView(self, commitText: text)
        case .mouseGeometry, .mouse, .scroll, .paste, .focus:
          break
        }
      }
    }

  }
#endif
