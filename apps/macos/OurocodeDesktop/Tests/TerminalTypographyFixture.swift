import AppKit
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private func relativeLuminance(_ color: NSColor) -> CGFloat {
    guard let value = color.usingColorSpace(.sRGB) else { return 1 }
    func linear(_ channel: CGFloat) -> CGFloat {
        channel <= 0.04045
            ? channel / 12.92
            : pow((channel + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(value.redComponent)
        + 0.7152 * linear(value.greenComponent)
        + 0.0722 * linear(value.blueComponent)
}

@main
enum TerminalTypographyFixture {
    static func main() {
        require(OuroTheme.defaultTerminalFontSize == 16, "terminal default must remain readable")
        require(OuroTheme.minimumTerminalFontSize >= 12, "minimum terminal font regressed")
        require(OuroTheme.maximumTerminalFontSize >= 48, "low-vision text zoom range regressed")
        require(OuroTheme.terminalContentInset >= 16, "terminal content touches the window edge")

        let font = OuroTheme.monoFont(size: OuroTheme.defaultTerminalFontSize)
        require(font.pointSize == 16, "terminal font point size is not stable")
        require(font.isFixedPitch, "terminal font must be fixed pitch")
        require(
            OuroTheme.terminalFontCandidates.first == BundledTerminalFont.postScriptName,
            "the bundled zsh-friendly Nerd Font must be preferred"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 24, modifiers: [.command, .shift], charactersIgnoringModifiers: "=") == .increase,
            "Command-plus did not resolve from the physical equals key"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 24, modifiers: [.command], charactersIgnoringModifiers: "=") == .increase,
            "Command-equals alias did not resolve"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 93, modifiers: [.command], charactersIgnoringModifiers: "+") == .increase,
            "layout-independent Command-plus did not resolve"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 24, modifiers: [.command], charactersIgnoringModifiers: "å") == nil,
            "a custom-layout character was hijacked by its ANSI physical position"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 27, modifiers: [.command], charactersIgnoringModifiers: "-") == .decrease,
            "Command-minus did not resolve"
        )
        require(
            TerminalTypographyShortcut.resolve(keyCode: 29, modifiers: [.command], charactersIgnoringModifiers: "0") == .reset,
            "Command-zero did not resolve"
        )
        let typography16 = TerminalTypographyProjectionIdentity(
            columns: 100,
            rows: 30,
            cellWidthPixels: 18,
            cellHeightPixels: 42,
            backingScale: 2,
            fontPointSize: 16
        )
        let typography17SameCells = TerminalTypographyProjectionIdentity(
            columns: 100,
            rows: 30,
            cellWidthPixels: 18,
            cellHeightPixels: 42,
            backingScale: 2,
            fontPointSize: 17
        )
        require(
            TerminalTypographyUpdatePolicy.resolve(
                current: typography16,
                next: typography17SameCells
            ) == .rendererOnly,
            "font-only zoom triggered a PTY geometry resize"
        )
        require(
            TerminalTypographyUpdatePolicy.resolve(
                current: typography16,
                next: typography16
            ) == .none,
            "unchanged typography was not a no-op"
        )
        let typography17Wider = TerminalTypographyProjectionIdentity(
            columns: 90,
            rows: 28,
            cellWidthPixels: 20,
            cellHeightPixels: 44,
            backingScale: 2,
            fontPointSize: 17
        )
        require(
            TerminalTypographyUpdatePolicy.resolve(
                current: typography16,
                next: typography17Wider
            ) == .terminalGeometry,
            "real grid/cell change skipped the PTY resize contract"
        )

        let authority = TerminalTypographyProjectionAuthority(
            terminalID: "primary",
            brokerGeneration: 7,
            inputEpoch: 3,
            leaseID: "lease-a"
        )
        var projection = TerminalTypographyProjectionState()
        require(
            projection.resolve(next: typography16, authority: authority) == .terminalGeometry,
            "an uncommitted primary projection did not fail closed to geometry"
        )
        var brokerResizeCount = 0
        brokerResizeCount += 1
        projection.commitTerminalGeometry(typography16, authority: authority)
        require(
            projection.resolve(next: typography17SameCells, authority: authority) == .rendererOnly,
            "the committed primary projection did not admit renderer-only zoom"
        )
        require(
            projection.commitRendererOnly(typography17SameCells, authority: authority),
            "renderer-only zoom was not committed after the renderer update"
        )
        require(
            projection.resolve(next: typography17Wider, authority: authority) == .terminalGeometry,
            "a real primary grid change skipped the broker geometry path"
        )
        brokerResizeCount += 1
        projection.commitTerminalGeometry(typography17Wider, authority: authority)
        require(brokerResizeCount == 2, "font-only zoom incorrectly incremented broker resize count")
        let replacementAuthority = TerminalTypographyProjectionAuthority(
            terminalID: "primary",
            brokerGeneration: 8,
            inputEpoch: 1,
            leaseID: "lease-b"
        )
        require(
            projection.resolve(next: typography17SameCells, authority: replacementAuthority) == .terminalGeometry,
            "a replacement attachment reused the previous primary projection"
        )

        var minimum = OuroTheme.minimumTerminalFontSize
        var transitionCount = 0
        for _ in 0..<10 {
            if let change = TerminalTypographyPointSizeTransition.resolve(
                current: minimum,
                requested: minimum - 1,
                minimum: OuroTheme.minimumTerminalFontSize,
                maximum: OuroTheme.maximumTerminalFontSize
            ) {
                minimum = change.next
                transitionCount += 1
            }
        }
        require(transitionCount == 0, "minimum-bound repeats generated preference work")
        require(
            TerminalTypographyPointSizeTransition.resolve(
                current: OuroTheme.defaultTerminalFontSize,
                requested: OuroTheme.minimumTerminalFontSize - 1,
                minimum: OuroTheme.minimumTerminalFontSize,
                maximum: OuroTheme.maximumTerminalFontSize
            )?.boundary == .minimum,
            "entering the minimum bound did not produce one bounded announcement"
        )
        let maximum = OuroTheme.maximumTerminalFontSize
        for _ in 0..<10 {
            require(
                TerminalTypographyPointSizeTransition.resolve(
                    current: maximum,
                    requested: maximum + 1,
                    minimum: OuroTheme.minimumTerminalFontSize,
                    maximum: OuroTheme.maximumTerminalFontSize
                ) == nil,
                "maximum-bound repeats generated preference work"
            )
        }
        require(
            TerminalLayoutEpoch.next(after: 6, monotonicNow: 1_000) == 1_000,
            "a relaunched UI did not advance beyond an older broker layout epoch"
        )
        require(
            TerminalLayoutEpoch.next(after: 1_000, monotonicNow: 900) == 1_001,
            "same-process layout epochs did not remain strictly monotonic"
        )
        require(
            TerminalLayoutEpoch.next(after: .max, monotonicNow: .max) == nil,
            "layout epoch exhaustion did not fail closed"
        )

        let cell = OuroTheme.terminalCellSize
        require(cell.width >= 8, "terminal cell width is illegible")
        require(cell.height >= 21, "terminal leading is too tight")

        let displayScaleSequence = [CGFloat(1), CGFloat(2), CGFloat(1)].map {
            TerminalBackingScaleGeometry(cellSize: cell, backingScale: $0)
        }
        require(
            displayScaleSequence[0].cellWidthPixels * 2 == displayScaleSequence[1].cellWidthPixels,
            "1x -> 2x display move did not double terminal cell pixel width"
        )
        require(
            displayScaleSequence[0].cellHeightPixels * 2 == displayScaleSequence[1].cellHeightPixels,
            "1x -> 2x display move did not double terminal cell pixel height"
        )
        require(
            displayScaleSequence[0] == displayScaleSequence[2],
            "1x -> 2x -> 1x display move did not restore terminal pixel geometry"
        )
        let fractional = TerminalBackingScaleGeometry(cellSize: cell, backingScale: 1.5)
        require(
            fractional.cellSizeInPoints.width * fractional.backingScale
                == CGFloat(fractional.cellWidthPixels)
                && fractional.cellSizeInPoints.height * fractional.backingScale
                == CGFloat(fractional.cellHeightPixels),
            "fractional backing scale did not round-trip through canonical pixel geometry"
        )

        let trackingView = TerminalAppearanceTrackingView()
        var backingChangeCount = 0
        trackingView.onBackingPropertiesChange = { backingChangeCount += 1 }
        trackingView.viewDidChangeBackingProperties()
        require(
            backingChangeCount == 1,
            "AppKit backing-property changes do not reach the terminal resize callback"
        )

        guard let dark = NSAppearance(named: .darkAqua) else {
            FileHandle.standardError.write(Data("FAIL: dark appearance unavailable\n".utf8))
            exit(1)
        }
        dark.performAsCurrentDrawingAppearance {
            let canvas = relativeLuminance(OuroTheme.canvas)
            let text = relativeLuminance(OuroTheme.text)
            let contrast = (max(canvas, text) + 0.05) / (min(canvas, text) + 0.05)
            let tabCanvas = relativeLuminance(OuroTheme.railCanvas)
            let tabText = relativeLuminance(OuroTheme.tabText)
            let tabContrast = (max(tabCanvas, tabText) + 0.05)
                / (min(tabCanvas, tabText) + 0.05)
            require(canvas < 0.02, "dark terminal canvas became grey")
            require(contrast >= 7, "terminal text contrast fell below AAA")
            require(tabContrast >= 4.5, "inactive terminal tabs fell below AA contrast")
        }

        print("PASS: font-only zoom has zero broker resize, grid changes resize once, bounds coalesce")
    }
}
