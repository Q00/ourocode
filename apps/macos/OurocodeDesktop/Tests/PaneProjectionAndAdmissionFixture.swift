import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum PaneProjectionAndAdmissionFixture {
    private static let tabID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let paneID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    private static let connectionID = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
    private static let surfaceInstanceID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000401"
    )!

    static func main() {
        realAttachmentFactoryRejectsEveryStaleAuthorityDimension()
        resizeLayoutEpochIsAnIndependentTransactionAuthority()
        productionFactoriesFailClosedOnInvalidIdentity()
        admissionRequiresExplicitHardCapacity()
        admissionFailsClosedAtEightAndOnInvalidCounts()
        print(
            "PASS: real broker attachment pane authority, resize epoch, and 4/8 admission "
                + "are fail-closed"
        )
    }

    private static func realAttachmentFactoryRejectsEveryStaleAuthorityDimension() {
        let current = token(attachment: attachment())
        require(
            PaneProjectionTokenGuard.accepts(current, current: current),
            "the exact real-attachment projection token must be accepted"
        )
        require(
            current.attachmentIdentity.terminalID == "terminal-a"
                && current.attachmentIdentity.brokerGeneration == 23
                && current.attachmentIdentity.connectionID == connectionID
                && current.attachmentIdentity.inputEpoch == 29
                && current.attachmentIdentity.leaseID == "lease-a"
                && current.attachmentIdentity.surfaceInstanceID == surfaceInstanceID
                && current.attachmentIdentity.runtimeGeneration == 31,
            "the narrow factory omitted part of the exact attachment/surface authority tuple"
        )

        let staleTokens = [
            token(attachment: attachment(), tabID: UUID()),
            token(attachment: attachment(), tabGeneration: 12),
            token(attachment: attachment(), paneID: UUID()),
            token(attachment: attachment(), paneGeneration: 18),
            token(attachment: attachment(terminalID: "terminal-b")),
            token(attachment: attachment(brokerGeneration: 24)),
            token(attachment: attachment(connectionID: UUID())),
            token(attachment: attachment(inputEpoch: 30)),
            token(attachment: attachment(leaseID: "lease-b")),
            token(attachment: attachment(), surfaceInstanceID: UUID()),
            token(attachment: attachment(), runtimeGeneration: 32),
        ]
        for stale in staleTokens {
            require(
                !PaneProjectionTokenGuard.accepts(stale, current: current),
                "a stale terminal/connection/broker/epoch/lease/surface/runtime token was accepted"
            )
        }
    }

    private static func resizeLayoutEpochIsAnIndependentTransactionAuthority() {
        let projectionAt41 = token(attachment: attachment(layoutEpoch: 41))
        let projectionAt42 = token(attachment: attachment(layoutEpoch: 42))
        require(
            PaneProjectionTokenGuard.accepts(projectionAt41, current: projectionAt42),
            "layoutEpoch incorrectly revoked attachment/input/surface projection authority"
        )

        guard let resizeAt41 = PaneResizeTransactionToken(
            projectionToken: projectionAt41,
            layoutEpoch: 41
        ), let resizeAt42 = PaneResizeTransactionToken(
            projectionToken: projectionAt42,
            layoutEpoch: 42
        ) else {
            require(false, "valid resize transaction tokens were not constructed")
            return
        }
        require(
            PaneResizeTransactionTokenGuard.accepts(resizeAt42, current: resizeAt42),
            "the exact resize transaction token must be accepted"
        )
        require(
            !PaneResizeTransactionTokenGuard.accepts(resizeAt41, current: resizeAt42),
            "a stale layoutEpoch resize transaction was accepted"
        )
        require(
            !PaneResizeTransactionTokenGuard.accepts(resizeAt42, current: nil),
            "a removed pane accepted a late resize transaction"
        )
    }

    private static func productionFactoriesFailClosedOnInvalidIdentity() {
        let zeroUUID = UUID(uuid: (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        ))
        let invalidAttachments = [
            attachment(terminalID: ""),
            attachment(brokerGeneration: 0),
            attachment(connectionID: zeroUUID),
            attachment(inputEpoch: 0),
            attachment(leaseID: ""),
        ]
        for invalidAttachment in invalidAttachments {
            require(
                makeToken(attachment: invalidAttachment) == nil,
                "an invalid real BrokerAttachment identity produced a projection token"
            )
        }
        require(
            makeToken(attachment: attachment(), surfaceInstanceID: zeroUUID) == nil,
            "a zero surface instance produced a projection token"
        )
        require(
            makeToken(attachment: attachment(), runtimeGeneration: 0) == nil,
            "a zero runtime generation produced a projection token"
        )
        require(
            makeToken(attachment: attachment(), tabID: zeroUUID) == nil,
            "a zero tab ID produced a projection token"
        )
        require(
            makeToken(attachment: attachment(), tabGeneration: 0) == nil,
            "a zero tab projection generation produced a projection token"
        )
        require(
            makeToken(attachment: attachment(), paneID: zeroUUID) == nil,
            "a zero pane ID produced a projection token"
        )
        require(
            makeToken(attachment: attachment(), paneGeneration: 0) == nil,
            "a zero pane generation produced a projection token"
        )

        let current = token(attachment: attachment())
        require(
            PaneResizeTransactionToken(projectionToken: current, layoutEpoch: 0) == nil,
            "a zero layout epoch produced a resize transaction token"
        )
    }

    private static func admissionRequiresExplicitHardCapacity() {
        let policy = PaneSurfaceAdmissionPolicy.standard
        require(
            policy.decision(currentSurfaceCount: 3) == .admitted(tier: .normal),
            "the fourth surface must fit normal admission"
        )
        require(
            policy.decision(currentSurfaceCount: 4)
                == .requiresExplicitHardAdmission(normalLimit: 4, requestedTotal: 5),
            "the fifth surface must require explicit hard admission"
        )
        require(
            policy.decision(currentSurfaceCount: 4, requestedTier: .hard)
                == .admitted(tier: .hard),
            "explicit hard admission must allow the fifth surface"
        )
        require(
            policy.decision(
                currentSurfaceCount: 4,
                additionalSurfaceCount: 4,
                requestedTier: .hard
            ) == .admitted(tier: .hard),
            "explicit hard admission must allow exactly eight surfaces"
        )
    }

    private static func admissionFailsClosedAtEightAndOnInvalidCounts() {
        let policy = PaneSurfaceAdmissionPolicy.standard
        require(
            policy.decision(currentSurfaceCount: 8, requestedTier: .hard)
                == .deniedHardLimit(hardLimit: 8, requestedTotal: 9),
            "the ninth surface must be rejected even with hard admission"
        )
        require(
            policy.decision(currentSurfaceCount: -1) == .invalidCount,
            "a negative allocated-surface count must fail closed"
        )
        require(
            policy.decision(currentSurfaceCount: 1, additionalSurfaceCount: 0)
                == .invalidCount,
            "a zero-size admission request must fail closed"
        )
        require(
            policy.decision(
                currentSurfaceCount: Int.max,
                additionalSurfaceCount: Int.max,
                requestedTier: .hard
            ) == .deniedHardLimit(hardLimit: 8, requestedTotal: Int.max),
            "overflowing capacity arithmetic must fail closed"
        )
    }

    private static func attachment(
        terminalID: String = "terminal-a",
        brokerGeneration: UInt64 = 23,
        connectionID: UUID = connectionID,
        inputEpoch: UInt64 = 29,
        leaseID: String = "lease-a",
        layoutEpoch: UInt64 = 41
    ) -> BrokerAttachment {
        BrokerAttachment.paneProjectionFixtureAttachment(
            terminalID: terminalID,
            brokerGeneration: brokerGeneration,
            connectionID: connectionID,
            inputEpoch: inputEpoch,
            leaseID: leaseID,
            layoutEpoch: layoutEpoch
        )
    }

    private static func makeToken(
        attachment: BrokerAttachment,
        tabID: UUID = tabID,
        tabGeneration: UInt64 = 11,
        paneID: UUID = paneID,
        paneGeneration: UInt64 = 17,
        surfaceInstanceID: UUID = surfaceInstanceID,
        runtimeGeneration: UInt64 = 31
    ) -> PaneProjectionToken? {
        PaneProjectionToken(
            tabID: tabID,
            tabProjectionGeneration: tabGeneration,
            paneID: paneID,
            paneGeneration: paneGeneration,
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        )
    }

    private static func token(
        attachment: BrokerAttachment,
        tabID: UUID = tabID,
        tabGeneration: UInt64 = 11,
        paneID: UUID = paneID,
        paneGeneration: UInt64 = 17,
        surfaceInstanceID: UUID = surfaceInstanceID,
        runtimeGeneration: UInt64 = 31
    ) -> PaneProjectionToken {
        guard let value = makeToken(
            attachment: attachment,
            tabID: tabID,
            tabGeneration: tabGeneration,
            paneID: paneID,
            paneGeneration: paneGeneration,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        ) else {
            require(false, "a valid real BrokerAttachment did not produce a projection token")
            fatalError("unreachable")
        }
        return value
    }
}
