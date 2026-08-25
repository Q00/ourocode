/// Resolves terminal-wide commands against the pane the person most recently
/// focused. A stale split identity must fail back to the tab's primary pane;
/// it must never be guessed from another tab or another session.
enum TerminalFocusedSurfaceRouting {
    static func terminalID(
        primaryTerminalID: String?,
        focusedTerminalID: String?,
        availableAdditionalTerminalIDs: Set<String>
    ) -> String? {
        guard let primaryTerminalID, !primaryTerminalID.isEmpty else { return nil }
        guard let focusedTerminalID,
              focusedTerminalID != primaryTerminalID,
              availableAdditionalTerminalIDs.contains(focusedTerminalID) else {
            return primaryTerminalID
        }
        return focusedTerminalID
    }
}
