import Foundation

enum MCPOutlineKeyAction: Equatable {
    case system
    case primaryAction
    case detail
}

/// Small event-order policy for AppKit outlines. Depending on the input path,
/// `selectionDidChange` may run before or after the table action. Both paths
/// must apply selection state before routing the row's primary action.
enum MCPPrimaryClickActivation {
    static func keyAction(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        hasActionModifier: Bool
    ) -> MCPOutlineKeyAction {
        guard !hasActionModifier else { return .system }
        if charactersIgnoringModifiers == " " { return .detail }
        if keyCode == 36 || keyCode == 76 { return .primaryAction }
        return .system
    }

    static func shouldRequestSelection(selectedRow: Int, clickedRow: Int) -> Bool {
        clickedRow >= 0 && selectedRow != clickedRow
    }

    static func shouldApplySelection(activeNodeID: String?, incomingNodeID: String) -> Bool {
        activeNodeID != incomingNodeID
    }

    /// A row that advertises terminal entry must take the user to that
    /// terminal. Session detail remains available through Space instead of
    /// appearing over the destination that the click just opened.
    static func shouldPresentDetail(
        isDetailRow: Bool,
        hasPrimaryTerminalAction: Bool
    ) -> Bool {
        isDetailRow && !hasPrimaryTerminalAction
    }

}
