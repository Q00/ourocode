enum TerminalTabFocusRestoration {
    /// Resolves an accessibility focus restoration only when it still belongs
    /// to the latest visible-tab projection. Identity is stable; array indices
    /// and reusable AppKit button slots intentionally are not.
    static func target<ID: Equatable>(
        focusedID: ID?,
        liveIDs: [ID],
        preserve: Bool,
        terminalFocusPending: Bool = false,
        requestGeneration: UInt64,
        currentGeneration: UInt64
    ) -> ID? {
        guard preserve,
              !terminalFocusPending,
              requestGeneration == currentGeneration,
              let focusedID,
              liveIDs.contains(focusedID) else { return nil }
        return focusedID
    }
}
