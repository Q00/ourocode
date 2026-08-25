import Foundation

/// Semantic routing for SessionRail actions.
///
/// AppKit is allowed to recreate every outline item and row view during
/// `reloadData()`. An accessibility client can therefore press a view whose
/// captured object identity is already stale, while a delayed selection event
/// can leave the same row number pointing at a different node. Session actions
/// carry the stable node ID instead and resolve it against the current tree.
enum SessionRailSemanticActivation {
    static func accessibilityIdentifier(nodeID: String) -> String {
        "ourocode.connections.row.\(nodeID)"
    }

    static func resolve(
        requestedNodeID: String?,
        currentNodeIDs: Set<String>
    ) -> String? {
        resolve(requestedNodeID: requestedNodeID) { currentNodeIDs.contains($0) }
    }

    static func resolve(
        requestedNodeID: String?,
        currentNodeIDExists: (String) -> Bool
    ) -> String? {
        guard let requestedNodeID,
              !requestedNodeID.isEmpty,
              currentNodeIDExists(requestedNodeID) else {
            return nil
        }
        return requestedNodeID
    }
}
