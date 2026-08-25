enum SessionRailOutlineSelectionChangeResolution: Equatable {
    case ignore
    case restoreSemanticSelection
    case apply
}

enum SessionRailDetailFocusRestoration {
    /// `reloadData()` may deliver a selection callback after the synchronous
    /// rebuild guard ends, and the reused row index can then name another
    /// node. A visible session workspace changes only through its explicit
    /// row/Back actions, which already carry semantic node identity.
    static func outlineSelectionChangeResolution(
        isRebuildingTree: Bool,
        isReloadSettling: Bool,
        isSessionWorkspaceVisible: Bool,
        hasRetainedSemanticSelection: Bool,
        hasExplicitUserIntent: Bool
    ) -> SessionRailOutlineSelectionChangeResolution {
        if isRebuildingTree { return .ignore }
        // A real key, pointer, or accessibility action outranks the delayed
        // selection notifications produced by reloadData(). Otherwise the
        // one-run-loop settling guard makes Arrow selection visibly skip rows
        // by restoring the previous semantic selection.
        if hasExplicitUserIntent { return .apply }
        if isReloadSettling || isSessionWorkspaceVisible {
            return .restoreSemanticSelection
        }
        if hasRetainedSemanticSelection { return .restoreSemanticSelection }
        return .apply
    }

    /// A background Sessions projection may dismiss stale detail, but it does
    /// not own keyboard focus. Restore only while focus still belongs to the
    /// detail being dismissed (or AppKit has temporarily left it unclaimed).
    static func shouldRestore(
        detailOwnedFocusAtDismissal: Bool,
        focusIsUnclaimedOrStillInDetail: Bool,
        requestGeneration: UInt64,
        currentGeneration: UInt64,
        detailIsVisible: Bool
    ) -> Bool {
        detailOwnedFocusAtDismissal
            && focusIsUnclaimedOrStillInDetail
            && requestGeneration == currentGeneration
            && !detailIsVisible
    }
}
