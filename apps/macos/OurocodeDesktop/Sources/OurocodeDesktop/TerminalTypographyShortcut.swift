import AppKit

enum TerminalTypographyShortcut: Equatable {
    case increase
    case decrease
    case reset

    /// `+` shares a physical key with `=` on common layouts. Resolve the
    /// action at the event boundary so keyboard layout does not decide whether
    /// a basic terminal shortcut works.
    static func resolve(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        charactersIgnoringModifiers: String?
    ) -> Self? {
        let commandOnly = modifiers.intersection([.command, .control, .option]) == [.command]
        guard commandOnly else { return nil }
        if let charactersIgnoringModifiers, !charactersIgnoringModifiers.isEmpty {
            switch charactersIgnoringModifiers {
            case "+", "=": return .increase
            case "-", "_": return .decrease
            case "0": return .reset
            default: return nil
            }
        }
        // Synthetic/window-system events can omit characters. Retain a bounded
        // ANSI/keypad fallback without overriding a real custom-layout glyph.
        switch keyCode {
        case 24, 69: return .increase // ANSI =/+ and keypad +
        case 27, 78: return .decrease // ANSI -/_ and keypad -
        case 29, 82: return .reset // ANSI 0 and keypad 0
        default: return nil
        }
    }
}

/// One bounded availability policy is shared by the native menu and the
/// terminal-local text-size menu. It keeps shortcuts discoverable while
/// preventing commands that cannot change the selected terminal surface.
enum TerminalTypographyAvailability {
    static func isEnabled(
        _ action: TerminalTypographyShortcut,
        hasEligibleTerminal: Bool,
        currentSize: CGFloat,
        minimumSize: CGFloat,
        maximumSize: CGFloat,
        defaultSize: CGFloat
    ) -> Bool {
        guard hasEligibleTerminal,
              minimumSize <= defaultSize,
              defaultSize <= maximumSize,
              minimumSize <= currentSize,
              currentSize <= maximumSize else { return false }
        switch action {
        case .increase: return currentSize < maximumSize
        case .decrease: return currentSize > minimumSize
        case .reset: return currentSize != defaultSize
        }
    }
}

struct TerminalTypographyProjectionIdentity: Equatable {
    let columns: Int
    let rows: Int
    let cellWidthPixels: Int
    let cellHeightPixels: Int
    let backingScale: CGFloat
    let fontPointSize: CGFloat

    func hasSameTerminalGeometry(as other: Self) -> Bool {
        columns == other.columns
            && rows == other.rows
            && cellWidthPixels == other.cellWidthPixels
            && cellHeightPixels == other.cellHeightPixels
            && backingScale == other.backingScale
    }
}

/// Binds a committed typography projection to the exact broker input lane.
/// A visually identical replacement attachment must still take the ordered
/// geometry path once before renderer-only updates are admitted.
struct TerminalTypographyProjectionAuthority: Equatable {
    let terminalID: String
    let brokerGeneration: UInt64
    let inputEpoch: UInt64
    let leaseID: String
}

enum TerminalTypographyUpdateKind: Equatable {
    case none
    case rendererOnly
    case terminalGeometry
}

enum TerminalTypographyUpdatePolicy {
    static func resolve(
        current: TerminalTypographyProjectionIdentity?,
        next: TerminalTypographyProjectionIdentity
    ) -> TerminalTypographyUpdateKind {
        guard let current else { return .terminalGeometry }
        guard current.hasSameTerminalGeometry(as: next) else { return .terminalGeometry }
        return current.fontPointSize == next.fontPointSize ? .none : .rendererOnly
    }
}

/// Retains only an acknowledged projection. Callers resolve against this
/// value, then commit renderer-only work immediately or terminal geometry only
/// after both the broker and pointer barrier settle.
struct TerminalTypographyProjectionState {
    private(set) var committed: TerminalTypographyProjectionIdentity?
    private(set) var authority: TerminalTypographyProjectionAuthority?

    func resolve(
        next: TerminalTypographyProjectionIdentity,
        authority nextAuthority: TerminalTypographyProjectionAuthority
    ) -> TerminalTypographyUpdateKind {
        guard authority == nextAuthority else { return .terminalGeometry }
        return TerminalTypographyUpdatePolicy.resolve(current: committed, next: next)
    }

    mutating func commitRendererOnly(
        _ next: TerminalTypographyProjectionIdentity,
        authority nextAuthority: TerminalTypographyProjectionAuthority
    ) -> Bool {
        guard resolve(next: next, authority: nextAuthority) == .rendererOnly else {
            return false
        }
        committed = next
        authority = nextAuthority
        return true
    }

    mutating func commitTerminalGeometry(
        _ next: TerminalTypographyProjectionIdentity,
        authority nextAuthority: TerminalTypographyProjectionAuthority
    ) {
        committed = next
        authority = nextAuthority
    }

    mutating func revoke() {
        committed = nil
        authority = nil
    }
}

enum TerminalTypographyBoundary: String, Equatable {
    case minimum = "Minimum"
    case maximum = "Maximum"
}

struct TerminalTypographyPointSizeChange: Equatable {
    let next: CGFloat
    let boundary: TerminalTypographyBoundary?
}

/// Coalesces held shortcuts before UserDefaults, HUD timers, and AX work.
enum TerminalTypographyPointSizeTransition {
    static func noOpFeedback(
        action: TerminalTypographyShortcut,
        current: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat,
        defaultSize: CGFloat
    ) -> String? {
        guard current.isFinite, minimum.isFinite, maximum.isFinite,
              defaultSize.isFinite else { return nil }
        switch action {
        case .increase: return current >= maximum ? "Maximum" : nil
        case .decrease: return current <= minimum ? "Minimum" : nil
        case .reset: return current == defaultSize ? "Default" : nil
        }
    }

    static func resolve(
        current: CGFloat,
        requested: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> TerminalTypographyPointSizeChange? {
        guard current.isFinite,
              requested.isFinite,
              minimum.isFinite,
              maximum.isFinite,
              minimum <= maximum else { return nil }
        let next = min(maximum, max(minimum, requested))
        guard next != current else { return nil }
        let boundary: TerminalTypographyBoundary?
        if next == minimum {
            boundary = .minimum
        } else if next == maximum {
            boundary = .maximum
        } else {
            boundary = nil
        }
        return TerminalTypographyPointSizeChange(next: next, boundary: boundary)
    }
}
