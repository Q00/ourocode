import Darwin
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

private final class FixtureNode {
    let id: String
    let generation: Int

    init(id: String, generation: Int) {
        self.id = id
        self.generation = generation
    }
}

@main
private enum SessionRailSemanticActivationFixture {
    static func main() {
        let sessionsID = "link:ouroboros:sessions"
        let sessionIndexID = "ouroboros:resource:ouroboros://sessions"
        let exactAttemptID = "session:ouroboros:execution-7:attempt-2"

        require(
            SessionRailSemanticActivation.accessibilityIdentifier(nodeID: sessionsID)
                == "ourocode.connections.row.link:ouroboros:sessions",
            "Sessions lost its stable accessibility identifier"
        )
        require(
            SessionRailSemanticActivation.accessibilityIdentifier(nodeID: sessionIndexID)
                == "ourocode.connections.row.ouroboros:resource:ouroboros://sessions",
            "Session index lost its source-qualified accessibility identifier"
        )

        let generationOne = [
            FixtureNode(id: sessionsID, generation: 1),
            FixtureNode(id: sessionIndexID, generation: 1),
            FixtureNode(id: exactAttemptID, generation: 1),
        ]
        let stalePressedObject = generationOne[2]

        // Models reloadData() replacing all object identities and changing row
        // ordering between an AX lookup and AXPress delivery.
        let generationTwo = [
            FixtureNode(id: sessionIndexID, generation: 2),
            FixtureNode(id: exactAttemptID, generation: 2),
            FixtureNode(id: sessionsID, generation: 2),
        ]
        let currentIDs = Set(generationTwo.map(\.id))
        let resolved = SessionRailSemanticActivation.resolve(
            requestedNodeID: stalePressedObject.id,
            currentNodeIDs: currentIDs
        )
        require(resolved == exactAttemptID, "reload race activated a neighboring row")
        require(
            generationTwo.first(where: { $0.id == resolved })?.generation == 2,
            "reload race retained the stale node object instead of resolving the current node"
        )

        require(
            SessionRailSemanticActivation.resolve(
                requestedNodeID: sessionIndexID,
                currentNodeIDs: currentIDs
            ) == sessionIndexID,
            "Session index did not preserve exact semantic activation"
        )
        require(
            SessionRailSemanticActivation.resolve(
                requestedNodeID: "session:ouroboros:removed:attempt",
                currentNodeIDs: currentIDs
            ) == nil,
            "a removed session fell through to a row-index neighbor"
        )
        require(
            SessionRailSemanticActivation.resolve(
                requestedNodeID: nil,
                currentNodeIDs: currentIDs
            ) == nil,
            "an empty outline selection invented an activation target"
        )

        print("PASS: SessionRail activation resolves stable exact-node IDs across reload races")
    }
}
