#if OUROCODE_GHOSTTY_METAL_SURFACE
import AppKit

/// Runtime owner for one visible split leaf.
///
/// `TerminalWorkspaceTab` owns the identity/layout projection; this object
/// owns the authorities that must never be copied into that model: one
/// Ghostty coordinator, one broker attachment and one staging view.  A pane
/// is not handed to the workspace until the broker commit and renderer
/// candidate commit have both succeeded.
@MainActor
final class TerminalPaneRuntime {
    enum State: Equatable {
        case preparing
        case attached
        case presented
        case failed
        case invalidated
    }

    let terminalID: String
    private let brokerGeneration: UInt64
    let surfaceInstanceID = UUID()
    let coordinator: TerminalSurfaceCoordinator
    let container = NSView(frame: .zero)

    private(set) var runtimeGeneration: UInt64 = 1
    private(set) var attachment: BrokerAttachment?
    private(set) var projectionToken: PaneProjectionToken?
    private(set) var state: State = .preparing
    private var pendingPresentationGeneration: UInt64?
    private var pendingPresentationFocused = false
    private var pendingReady: ((Result<Void, Error>) -> Void)?
    private var resizeInFlight = false
    private struct ResizeRequest: Equatable {
        let columns: Int
        let rows: Int
        let backingScale: CGFloat
        let fontPointSize: CGFloat
        let cellWidthPixels: Int
        let cellHeightPixels: Int

        var projectionIdentity: TerminalTypographyProjectionIdentity {
            TerminalTypographyProjectionIdentity(
                columns: columns,
                rows: rows,
                cellWidthPixels: cellWidthPixels,
                cellHeightPixels: cellHeightPixels,
                backingScale: backingScale,
                fontPointSize: fontPointSize
            )
        }
    }
    private var pendingResize: ResizeRequest?
    private var typographyProjection = TerminalTypographyProjectionState()
    private var rendererOnlyGeometryFallbackPending = false
    private var currentLayoutEpoch: UInt64 = 0
    private struct PendingDetach {
        let broker: BrokerClient
        let completion: (Result<BrokerDetachReceipt?, Error>) -> Void
    }
    private var pendingDetach: PendingDetach?

    var onFailure: ((Error) -> Void)?
    var onInputFailure: ((Error) -> Void)?

    init(
        brokerGeneration: UInt64,
        prepared: BrokerPreparedRecovery,
        backingScale: CGFloat,
        fontPointSize: CGFloat = OuroTheme.terminalFontSize,
        onFocusChange: ((Bool) -> Void)? = nil
    ) throws {
        terminalID = prepared.terminal.id
        self.brokerGeneration = brokerGeneration
        coordinator = try TerminalSurfaceCoordinator(
            brokerGeneration: brokerGeneration,
            bootstrapTerminalID: prepared.terminal.id,
            columns: prepared.terminal.columns,
            rows: prepared.terminal.rows,
            backingScale: backingScale,
            fontPointSize: fontPointSize
        )
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = OuroTheme.canvas.cgColor
        container.setAccessibilityElement(false)
        coordinator.install(in: container)
        coordinator.onFocusChange = onFocusChange
        coordinator.setAccessibilityVisible(false)
        coordinator.view.isHidden = true

        coordinator.onFirstPresented = { [weak self] generation, terminalID, _, _ in
            TerminalPaneRuntimeTrace.record(
                "first-present.callback",
                "generation=\(generation)"
            )
            guard let self,
                  self.terminalID == terminalID,
                  self.pendingPresentationGeneration == generation,
                  let attachment = self.attachment,
                  let broker = self.brokerForPendingPresentation,
                  self.coordinator.matchesFirstPresentedAttachment(attachment) else {
                return
            }
            guard self.pendingPresentationFocused else {
                self.finishPresentation(.success(()))
                return
            }
            self.coordinator.activateInput(
                broker: broker,
                attachment: attachment
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.coordinator.openInputAfterActivation(attachment: attachment)
                        self.finishPresentation(.success(()))
                    } catch {
                        self.finishPresentation(.failure(error))
                    }
                case .failure(let error):
                    self.finishPresentation(.failure(error))
                }
            }
        }
        coordinator.onFailure = { [weak self] error in
            self?.onFailure?(error)
        }
        coordinator.onInputFailure = { [weak self] error in
            self?.onInputFailure?(error)
        }
    }

    private weak var brokerForPendingPresentation: BrokerClient?

    /// Prepare and commit a real broker attachment into this runtime. The
    /// returned runtime is still hidden; `present` is the explicit projection
    /// step after the workspace CAS mutation succeeds.
    func attach(
        broker: BrokerClient,
        brokerGeneration: UInt64,
        prepared: BrokerPreparedRecovery,
        presentationGeneration: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard state == .preparing else {
            completion(.failure(BrokerClientError.unavailable("Pane runtime is no longer preparing.")))
            return
        }
        brokerForPendingPresentation = broker
        pendingPresentationGeneration = presentationGeneration
        pendingPresentationFocused = false
        pendingReady = completion
        coordinator.view.isHidden = false
        TerminalPaneRuntimeTrace.record(
            "attach.begin",
            coordinator.presentationReadinessDescription
        )
        let candidate: TerminalSurfaceCoordinator.Candidate
        do {
            candidate = try coordinator.prepareCandidate(
                brokerGeneration: brokerGeneration,
                prepared: prepared
            )
            TerminalPaneRuntimeTrace.record("candidate.prepared")
        } catch {
            TerminalPaneRuntimeTrace.record("candidate.prepare.failure")
            broker.abortRecovery(
                prepared,
                reason: "Pane renderer rejected the recovery checkpoint before commit."
            )
            state = .failed
            finishPresentation(.failure(error))
            return
        }
        TerminalPaneRuntimeTrace.record("broker.commit.begin")
        broker.commitAttachment(
            prepared,
            onEvent: { [weak self] event in
                guard let self,
                      self.state == .preparing
                        || self.state == .attached
                        || self.state == .presented else { return }
                do {
                    try self.coordinator.applyAttachedEvent(event)
                    if case .resize(_, _, _, _, _, let layoutEpoch) = event {
                        self.currentLayoutEpoch = layoutEpoch
                    }
                } catch {
                    self.onFailure?(error)
                }
            }
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                TerminalPaneRuntimeTrace.record("broker.commit.failure")
                self.coordinator.abortCandidate(candidate)
                self.state = .failed
                if Self.commitOutcomeMayBeAmbiguous(error) {
                    broker.reconnectAfterAuthorityFailure(error)
                }
                self.finishPresentation(.failure(error))
            case .success(let attachment):
                TerminalPaneRuntimeTrace.record("broker.commit.success")
                self.attachment = attachment
                self.currentLayoutEpoch = attachment.terminal.layoutEpoch
                do {
                    TerminalPaneRuntimeTrace.record("catchup.begin")
                    try attachment.consumeCatchUpEvents { events in
                        for event in events { try self.coordinator.applyCandidate(event) }
                    }
                    TerminalPaneRuntimeTrace.record("catchup.end")
                    TerminalPaneRuntimeTrace.record("surface.commit.begin")
                    self.coordinator.commitCandidate(
                        candidate,
                        attachment: attachment,
                        attachedReadyStateSequence: attachment.terminal.stateSequence,
                        presentationGeneration: presentationGeneration
                    ) { [weak self] commitResult in
                        guard let self else { return }
                        switch commitResult {
                        case .success:
                            self.state = .attached
                            TerminalPaneRuntimeTrace.record(
                                "surface.commit.success",
                                self.coordinator.presentationReadinessDescription
                            )
                            self.coordinator.requestPendingPresentationDraw()
                        case .failure(let error):
                            TerminalPaneRuntimeTrace.record("surface.commit.failure")
                            self.state = .failed
                            self.finishPresentation(.failure(error))
                        }
                    }
                } catch {
                    TerminalPaneRuntimeTrace.record("catchup.failure")
                    self.coordinator.abortCandidate(candidate)
                    self.state = .failed
                    self.finishPresentation(.failure(error))
                }
            }
        }
    }

    /// Make the committed stream visible. Input is granted only when the
    /// first frame matches the same attachment and the caller marks this pane
    /// focused; a background pane remains observable but not writable.
    func present(
        focused: Bool,
        broker: BrokerClient,
        presentationGeneration: UInt64,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        TerminalPaneRuntimeTrace.record(
            "present.begin",
            "focused=\(focused) state=\(String(describing: state))"
        )
        guard state == .presented, let attachment else {
            completion(.failure(BrokerClientError.staleAttachment))
            return
        }
        brokerForPendingPresentation = broker
        container.isHidden = false
        coordinator.view.isHidden = false
        coordinator.setAccessibilityVisible(true)
        coordinator.install(in: container)
        guard focused else {
            completion(.success(()))
            return
        }
        coordinator.activateInput(broker: broker, attachment: attachment) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                do {
                    try self.coordinator.openInputAfterActivation(attachment: attachment)
                    TerminalPaneRuntimeTrace.record("present.input-open.success")
                    completion(.success(()))
                } catch {
                    TerminalPaneRuntimeTrace.record("present.input-open.failure")
                    completion(.failure(error))
                }
            case .failure(let error):
                TerminalPaneRuntimeTrace.record("present.activate.failure")
                completion(.failure(error))
            }
        }
    }

    func revokeInput() {
        coordinator.revokeInputLocally()
    }

    func resize(
        broker: BrokerClient,
        columns: Int,
        rows: Int,
        backingScale: CGFloat,
        fontPointSize: CGFloat = OuroTheme.terminalFontSize
    ) {
        guard state == .presented,
              attachment != nil,
              columns >= 2,
              rows >= 2 else { return }
        let geometry = TerminalBackingScaleGeometry(
            cellSize: OuroTheme.terminalCellSize(fontSize: fontPointSize),
            backingScale: backingScale
        )
        let request = ResizeRequest(
            columns: columns,
            rows: rows,
            backingScale: geometry.backingScale,
            fontPointSize: fontPointSize,
            cellWidthPixels: geometry.cellWidthPixels,
            cellHeightPixels: geometry.cellHeightPixels
        )
        pendingResize = request
        driveResize(broker: broker)
    }

    func detach(
        broker: BrokerClient,
        completion: @escaping (Result<BrokerDetachReceipt?, Error>) -> Void
    ) {
        if resizeInFlight {
            guard pendingDetach == nil else {
                completion(.failure(BrokerClientError.unavailable("Pane detach is already pending.")))
                return
            }
            pendingResize = nil
            pendingDetach = PendingDetach(broker: broker, completion: completion)
            return
        }
        guard let attachment else {
            invalidate()
            completion(.success(nil))
            return
        }
        coordinator.deactivateInputBeforeDetach(attachment: attachment) {
            [weak self] barrierResult in
            guard let self else { return }
            switch barrierResult {
            case .failure(let error):
                completion(.failure(error))
            case .success:
                broker.detach(attachment) { [weak self] detachResult in
                    guard let self else { return }
                    switch detachResult {
                    case .success(let receipt):
                        self.attachment = nil
                        self.invalidate()
                        completion(.success(receipt))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func bindProjectionToken(_ token: PaneProjectionToken) throws {
        guard token.terminalID == terminalID,
              token.attachmentIdentity.surfaceInstanceID == surfaceInstanceID,
              token.attachmentIdentity.runtimeGeneration == runtimeGeneration else {
            throw BrokerClientError.staleAttachment
        }
        projectionToken = token
    }

    /// Validates the exact pane authority that may become a tab's retained
    /// primary surface. No ownership changes here: the host performs its old
    /// primary detach barrier first, then consumes this authority in one
    /// main-actor transaction with the workspace layout CAS.
    func preparePrimaryPromotion(
        currentProjectionToken: PaneProjectionToken
    ) throws -> BrokerAttachment {
        guard state == .presented,
              let attachment,
              PaneProjectionTokenGuard.accepts(
                  currentProjectionToken,
                  current: projectionToken
              ),
              currentProjectionToken.terminalID == terminalID,
              coordinator.matchesFirstPresentedAttachment(attachment)
        else { throw BrokerClientError.staleAttachment }
        return attachment
    }

    /// Crosses from pane projection authority to the host's retained primary
    /// authority after the old primary attachment has detached. The event
    /// stream and coordinator stay owned by this runtime until the promoted
    /// primary itself later crosses an ordered detach barrier.
    func commitPrimaryPromotion(
        currentProjectionToken: PaneProjectionToken,
        attachment expectedAttachment: BrokerAttachment
    ) throws {
        guard let attachment,
              Self.sameAttachmentAuthority(attachment, expectedAttachment),
              PaneProjectionTokenGuard.accepts(
                  currentProjectionToken,
                  current: projectionToken
              ) else { throw BrokerClientError.staleAttachment }
        projectionToken = nil
    }

    /// The host may detach a promoted primary through its ordinary retained
    /// surface barrier. Clear this runtime only after the exact broker receipt
    /// returns; a different lease can never be invalidated by a stale callback.
    func invalidateAfterExternalPrimaryDetach(_ detached: BrokerAttachment) throws {
        guard let attachment,
              Self.sameAttachmentAuthority(attachment, detached)
        else { throw BrokerClientError.staleAttachment }
        self.attachment = nil
        invalidate()
    }

    func invalidate() {
        guard state != .invalidated else { return }
        runtimeGeneration &+= 1
        if runtimeGeneration == 0 { runtimeGeneration = 1 }
        pendingReady?(.failure(BrokerClientError.staleAttachment))
        pendingReady = nil
        pendingDetach?.completion(.failure(BrokerClientError.staleAttachment))
        pendingDetach = nil
        pendingPresentationGeneration = nil
        projectionToken = nil
        coordinator.invalidateTransition()
        coordinator.revokeInputLocally()
        coordinator.setAccessibilityVisible(false)
        coordinator.view.isHidden = true
        container.removeFromSuperview()
        state = .invalidated
    }

    func projectionToken(
        tabID: UUID,
        tabProjectionGeneration: UInt64,
        pane: TerminalPane
    ) -> PaneProjectionToken? {
        guard let attachment, state == .attached || state == .presented else { return nil }
        return pane.projectionToken(
            tabID: tabID,
            tabGeneration: tabProjectionGeneration,
            attachment: attachment,
            surfaceInstanceID: surfaceInstanceID,
            runtimeGeneration: runtimeGeneration
        )
    }

    private func finishPresentation(_ result: Result<Void, Error>) {
        guard let pendingReady else { return }
        switch result {
        case .success:
            TerminalPaneRuntimeTrace.record("presentation.finish.success")
        case .failure:
            TerminalPaneRuntimeTrace.record("presentation.finish.failure")
        }
        self.pendingReady = nil
        pendingPresentationGeneration = nil
        if case .success = result {
            state = .presented
        } else {
            state = .failed
            coordinator.setAccessibilityVisible(false)
            coordinator.view.isHidden = true
        }
        pendingReady(result)
    }

    private static func sameAttachmentAuthority(
        _ lhs: BrokerAttachment,
        _ rhs: BrokerAttachment
    ) -> Bool {
        lhs.terminal.id == rhs.terminal.id
            && lhs.inputEpoch == rhs.inputEpoch
            && lhs.leaseID == rhs.leaseID
    }

    private func driveResize(broker: BrokerClient) {
        guard !resizeInFlight,
              let request = pendingResize,
              let attachment
        else { return }
        pendingResize = nil
        resizeInFlight = true
        let geometry = TerminalBackingScaleGeometry(
            cellSize: OuroTheme.terminalCellSize(fontSize: request.fontPointSize),
            backingScale: request.backingScale
        )
        let projectionAuthority = TerminalTypographyProjectionAuthority(
            terminalID: attachment.terminal.id,
            brokerGeneration: brokerGeneration,
            inputEpoch: attachment.inputEpoch,
            leaseID: attachment.leaseID
        )
        let updateKind = typographyProjection.resolve(
            next: request.projectionIdentity,
            authority: projectionAuthority
        )
        if updateKind == .none {
            resizeInFlight = false
            driveResize(broker: broker)
            return
        }
        if updateKind == .rendererOnly {
            do {
                try coordinator.updateTypographyWithoutGeometry(
                    geometry: geometry,
                    fontPointSize: request.fontPointSize
                )
                guard typographyProjection.commitRendererOnly(
                    request.projectionIdentity,
                    authority: projectionAuthority
                ) else {
                    throw BrokerClientError.staleAttachment
                }
                resizeInFlight = false
                driveResize(broker: broker)
            } catch {
                // A renderer-only rejection must not tear down the pane or
                // retry the same projection indefinitely. Revocation forces
                // this exact request through the ordered broker/pointer
                // geometry transaction on the next drive.
                typographyProjection.revoke()
                pendingResize = request
                rendererOnlyGeometryFallbackPending = true
                resizeInFlight = false
                driveResize(broker: broker)
            }
            return
        }
        let reportsGeometryFailure = rendererOnlyGeometryFallbackPending
        rendererOnlyGeometryFallbackPending = false
        guard let nextEpoch = TerminalLayoutEpoch.next(after: currentLayoutEpoch) else {
            resizeInFlight = false
            let error = BrokerClientError.invalidRequest("Terminal layout epoch is exhausted.")
            onFailure?(error)
            return
        }
        final class Settlement {
            var broker = false
            var pointer = false
            var failure: Error?
            var finished = false
        }
        let settlement = Settlement()
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            if !settlement.finished,
               settlement.failure != nil || (settlement.broker && settlement.pointer) {
                settlement.finished = true
                if settlement.failure == nil {
                    self.currentLayoutEpoch = nextEpoch
                    self.typographyProjection.commitTerminalGeometry(
                        request.projectionIdentity,
                        authority: projectionAuthority
                    )
                }
                self.resizeInFlight = false
                if let pendingDetach = self.pendingDetach {
                    self.pendingDetach = nil
                    self.detach(
                        broker: pendingDetach.broker,
                        completion: pendingDetach.completion
                    )
                    return
                }
                if let error = settlement.failure, reportsGeometryFailure {
                    self.pendingResize = nil
                    self.onFailure?(error)
                    return
                }
                self.driveResize(broker: broker)
            }
        }
        coordinator.prepareForResize { [weak self] prepareResult in
            guard let self else { return }
            switch prepareResult {
            case .failure(let error):
                settlement.failure = error
                finish()
            case .success:
                do {
                    try self.coordinator.expectPreparedResize(layoutEpoch: nextEpoch) { pointerResult in
                        switch pointerResult {
                        case .success: settlement.pointer = true
                        case .failure(let error): settlement.failure = error
                        }
                        finish()
                    }
                    try self.coordinator.updateTypography(
                        geometry: geometry,
                        fontPointSize: request.fontPointSize
                    )
                } catch {
                    settlement.failure = error
                    self.coordinator.abortPreparedResize(error)
                    finish()
                    return
                }
                broker.resize(
                    columns: request.columns,
                    rows: request.rows,
                    cellWidthPixels: request.cellWidthPixels,
                    cellHeightPixels: request.cellHeightPixels,
                    layoutEpoch: nextEpoch,
                    using: attachment
                ) { brokerResult in
                    switch brokerResult {
                    case .success: settlement.broker = true
                    case .failure(let error):
                        settlement.failure = error
                        if Self.commitOutcomeMayBeAmbiguous(error) {
                            self.pendingResize = nil
                            self.typographyProjection.revoke()
                            self.coordinator.revokeInputLocally()
                            broker.reconnectAfterAuthorityFailure(error)
                        }
                        self.coordinator.abortPreparedResize(error)
                    }
                    finish()
                }
            }
        }
    }

    private static func commitOutcomeMayBeAmbiguous(_ error: Error) -> Bool {
        guard let brokerError = error as? BrokerClientError else { return true }
        switch brokerError {
        case .server, .invalidRequest, .staleAttachment, .unavailable:
            return false
        case .notConnected, .helperMissing, .connectFailed, .disconnected,
             .protocolViolation, .resyncRequired, .timedOut:
            return true
        }
    }
}
#endif
