import AppKit
import SwiftTerm

/// Keeps the GPU terminal usable while exposing a bounded textual snapshot to
/// macOS accessibility clients. The visual renderer remains Metal-backed.
final class AccessibleTerminalView: TerminalView, TerminalViewDelegate {
    private static let accessibilityByteLimit = 16 * 1024
    private var pendingAccessibilityRefresh: DispatchWorkItem?
    var onInput: (([UInt8]) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    var onTitle: ((String) -> Void)?
    var onDirectory: ((String?) -> Void)?
    var isBrokerRunning = false
    var exposesAccessibilitySnapshot = false {
        didSet {
            if exposesAccessibilitySnapshot {
                scheduleAccessibilityRefresh()
            } else {
                pendingAccessibilityRefresh?.cancel()
            }
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(
            frame: frameRect,
            font: OuroTheme.monoFont(size: OuroTheme.terminalFontSize),
            options: TerminalOptions(
                scrollback: 500,
                enableSixelReported: false,
                kittyImageCacheLimitBytes: 4 * 1024 * 1024
            )
        )
        configureAccessibility()
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func configureAccessibility() {
        terminalDelegate = self
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("terminal")
        setAccessibilityLabel("Interactive terminal")
        setAccessibilityHelp("Local shell terminal. Output is exposed as a read-only snapshot; keyboard input is sent to the focused terminal. Assistive clients can invoke Send Return.")
        setAccessibilityValue("")
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Send Return") { [weak self] in
                guard let self, self.isBrokerRunning else { return false }
                if self.getTerminal().keyboardEnhancementFlags.isEmpty && !self.hasMarkedText() {
                    self.send([0x0d])
                } else {
                    self.doCommand(by: #selector(NSResponder.insertNewline(_:)))
                }
                return true
            }
        ])
    }

    override func isAccessibilityFocused() -> Bool {
        window?.firstResponder === self
    }

    override func setAccessibilityFocused(_ accessibilityFocused: Bool) {
        guard accessibilityFocused else { return }
        window?.makeFirstResponder(self)
    }


    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let value: String
        if let attributed = string as? NSAttributedString {
            value = attributed.string
        } else if let plain = string as? String {
            value = plain
        } else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        super.insertText(
            OuroTerminalCommittedText.normalize(value),
            replacementRange: replacementRange
        )
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        let value: String
        if let attributed = string as? NSAttributedString {
            value = attributed.string
        } else if let plain = string as? String {
            value = plain
        } else {
            super.setMarkedText(
                string,
                selectedRange: selectedRange,
                replacementRange: replacementRange
            )
            return
        }
        let normalized = OuroTerminalCommittedText.normalize(value)
        let length = (normalized as NSString).length
        let selection: NSRange
        if selectedRange.location == NSNotFound {
            selection = NSRange(location: length, length: 0)
        } else {
            let location = min(selectedRange.location, length)
            selection = NSRange(
                location: location,
                length: min(selectedRange.length, length - location)
            )
        }
        super.setMarkedText(
            normalized,
            selectedRange: selection,
            replacementRange: replacementRange
        )
    }

    /// Commits the retained preedit before a boundary key consumed by the
    /// host monitor. Clearing SwiftTerm's overlay is not enough: the AppKit
    /// input context must also discard its composition or the Korean IME can
    /// replay the same final syllable on the next word.
    @discardableResult
    func commitMarkedTextForBoundary() -> Bool {
        guard hasMarkedText() else { return false }
        let range = markedRange()
        guard let marked = attributedSubstring(
            forProposedRange: range,
            actualRange: nil
        )?.string, !marked.isEmpty else { return false }
        insertText(marked, replacementRange: range)
        inputContext?.discardMarkedText()
        return true
    }

    func receiveHostData(_ data: [UInt8]) {
        feed(byteArray: data[...])
        guard exposesAccessibilitySnapshot else { return }
        DispatchQueue.main.async { [weak self] in
            self?.scheduleAccessibilityRefresh()
        }
    }

    private func scheduleAccessibilityRefresh() {
        pendingAccessibilityRefresh?.cancel()
        let refresh = DispatchWorkItem { [weak self] in
            self?.refreshAccessibilityValue()
        }
        pendingAccessibilityRefresh = refresh
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: refresh)
    }

    private func refreshAccessibilityValue() {
        let data = getTerminal().getBufferAsData()
        let bounded = data.suffix(Self.accessibilityByteLimit)
        let value = String(decoding: bounded, as: UTF8.self)
        setAccessibilityValue(value)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        onInput?(Array(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        onResize?(newCols, newRows)
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitle?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectory?(directory)
    }

    func scrolled(source: TerminalView, position: Double) {}

    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let value = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([value as NSString])
    }

    func clipboardRead(source: TerminalView) -> Data? {
        NSPasteboard.general.string(forType: .string)?.data(using: .utf8)
    }
}
