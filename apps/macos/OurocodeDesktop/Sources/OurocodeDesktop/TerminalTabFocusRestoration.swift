enum TerminalTabFocusRestoration {
    /// Resolves an accessibility focus restoration only when it still belongs
    /// to the latest visible-tab projection. Identity is stable; array indices
    /// and reusable AppKit button slots intentionally are not.
    static func target<ID: Equatable>(
        focusedID: ID?,
        liveIDs: [ID],
        preserve: Bool,
        requestGeneration: UInt64,
        currentGeneration: UInt64
    ) -> ID? {
        guard preserve,
              requestGeneration == currentGeneration,
              let focusedID,
              liveIDs.contains(focusedID) else { return nil }
        return focusedID
    }
}
