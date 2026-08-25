#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import MetalKit

  enum GhosttyRenderDeployment {
    private static let deployment = try! GhosttyBrokerDeployment.resolve()
    static let sourceCommit = deployment.sourceCommit
    static let pinNamespace = deployment.pinNamespace
    static let helperName = deployment.helperName
    static let socketURL = deployment.socketURL
  }

  enum TerminalSurfaceCoordinatorError: LocalizedError {
    case noMetalDevice
    case invalidManifest
    case invalidDimensions
    case candidateMissing
    case candidateAlreadyPresent
    case activeStreamMissing
    case frameAlreadyLeased
    case invalidCardinality
    case pendingEventsExceeded

    var errorDescription: String? {
      switch self {
      case .noMetalDevice:
        return "This Mac does not expose a Metal device for the Ghostty terminal surface."
      case .invalidManifest:
        return "The broker recovery manifest does not match the pinned Ghostty renderer."
      case .invalidDimensions:
        return "The broker supplied terminal dimensions outside the bounded Metal surface."
      case .candidateMissing:
        return "The Ghostty surface has no prepared recovery candidate."
      case .candidateAlreadyPresent:
        return "The Ghostty surface already owns its single recovery candidate."
      case .activeStreamMissing:
        return "The Ghostty surface has not committed an active broker stream."
      case .frameAlreadyLeased:
        return "The Ghostty surface attempted to lease more than one CPU frame."
      case .invalidCardinality:
        return "The Ghostty bridge violated the one-active, one-candidate, one-projection bound."
      case .pendingEventsExceeded:
        return "Live terminal events exceeded the bounded presentation cutover queue."
      }
    }
  }

  private final class TerminalFindCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
      lock.lock()
      cancelled = true
      lock.unlock()
    }

    var isCancelled: Bool {
      lock.lock()
      defer { lock.unlock() }
      return cancelled
    }
  }

  /// Owns the app's sole Ghostty client, Metal view, retained projection, and
  /// bounded candidate. Hidden tabs remain broker metadata and never enter this
  /// object. All mutations arrive on the main thread; the renderer performs its
  /// bounded scene preparation on its one serial render queue.
  final class TerminalSurfaceCoordinator: NSObject, OuroTerminalInputSink {
    struct Candidate {
      fileprivate let token: GhosttyRenderCandidate
      fileprivate let admissionPermit: PaneSurfaceAdmissionPermit
      let stream: GhosttyRenderStream
    }

    private let activeSurfacePermit: PaneSurfaceAdmissionPermit
    let bridge: GhosttyRenderBridge
    let renderer: OuroTerminalRenderer
    let view: OuroMetalTerminalView

    var onFirstPresented: ((UInt64, String, UInt64, OuroTerminalAccessibilitySnapshot) -> Void)?
    var onAccessibilityPresented: ((String, UInt64, OuroTerminalAccessibilitySnapshot) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onInputFailure: ((Error) -> Void)?
    var onInputNotice: ((Error) -> Void)?
    var onBell: ((UInt32) -> Void)?
    var onMetadata: ((String, UInt64, GhosttyRenderMetadata) -> Void)?
    var onLockedInteraction: (() -> Void)?
    var onPointerReady: (() -> Void)?
    /// Reports real AppKit focus, independently from broker focus receipts.
    /// The host uses this only for local presentation choices such as
    /// pane-scoped typography; it is not an input-authority grant.
    var onFocusChange: ((Bool) -> Void)?

    private var font: NSFont
    private var cellPixelSize: CGSize
    private struct PendingCommit {
      let candidate: Candidate
      let inputAuthority: InputAuthorityIdentity
      let attachedReadyStateSequence: UInt64
      let presentationGeneration: UInt64
      let completion: (Result<Void, Error>) -> Void
    }
    private struct PendingPresentation {
      let transitionGeneration: UInt64
      let terminalID: String
      let inputAuthority: InputAuthorityIdentity
      let minimumStateSequence: UInt64
      var frameGeneration: UInt64?
      var metadata: GhosttyRenderMetadata?
    }
    private var activeStream: GhosttyRenderStream?
    private var candidate: Candidate?
    private var candidateStateSequence: UInt64 = 0
    private var candidateLayoutEpoch: UInt64 = 0
    private var appliedActiveStateSequence: UInt64 = 0
    private var lastMetadataEpoch: UInt64?
    private var findRequestGeneration: UInt64 = 0
    private var findResultStream: GhosttyRenderStream?
    private var findCancellationToken: TerminalFindCancellationToken?
    private let findQueue = DispatchQueue(
      label: "works.ourocode.terminal-find",
      qos: .userInitiated
    )
    private var activeLayoutEpoch: UInt64 = 0
    private var frameLeaseOutstanding = false
    private var frameRequested = false
    private var presentationQuiesced = false
    private var pendingCommit: PendingCommit?
    private var pendingPresentation: PendingPresentation?
    private var pendingLiveEvents: [BrokerStateEvent] = []
    private struct InputAuthorityIdentity: Equatable {
      let terminalID: String
      let inputEpoch: UInt64
      let leaseID: String

      init(_ attachment: BrokerAttachment) {
        terminalID = attachment.terminal.id
        inputEpoch = attachment.inputEpoch
        leaseID = attachment.leaseID
      }
    }
    private var firstPresentedInputAuthority: InputAuthorityIdentity?
    private enum QueuedInputAction {
      case broker(NormalizedTerminalInputEvent)
      case copySelection
      case selectAll
      case scrollViewport(GhosttyRenderViewportScroll)
    }
    private struct QueuedInput {
      let action: QueuedInputAction
      let generation: UInt64
      let completion: ((Result<NormalizedTerminalInputReceipt, Error>) -> Void)?
    }
    private weak var inputBroker: BrokerClient?
    private var inputAttachment: BrokerAttachment?
    private var inputQueue: [QueuedInput] = []
    private var inputFlight: (token: UInt64, generation: UInt64, pointer: Bool)?
    private var nextInputFlightToken: UInt64 = 0
    private var inputGeneration: UInt64 = 0
    private var desiredFocus: Bool?
    private var acknowledgedFocus: Bool?
    private var focusWaiters: [Bool: [(Result<Void, Error>) -> Void]] = [:]
    private static let maximumQueuedInputEvents = 64
    private static let sharedMetalResources: Result<OuroTerminalMetalResources, Error> = Result {
      guard let device = MTLCreateSystemDefaultDevice() else {
        throw TerminalSurfaceCoordinatorError.noMetalDevice
      }
      return try OuroTerminalMetalResources(
        device: device,
        sourceURL: debugShaderSourceURL
      )
    }
    private struct ActivePointerGesture {
      let id: UInt64
      let layoutEpoch: UInt64
      let button: NormalizedTerminalMouseButton
      var sample: TerminalPointerSample
      var modifiers: NormalizedTerminalModifiers
      var cancelling: Bool
    }
    private var activePointerGestures: [Int: ActivePointerGesture] = [:]
    private var pointerGeometryAcknowledgedEpoch: UInt64?
    private var pointerGeometryRequestEpoch: UInt64?
    private var pointerReadinessRepairPending = false
    private var pointerReadinessNoticePending = false
    private var nextPointerGestureID: UInt64 = 0
    private var hoverGestureID: UInt64?
    private var scrollGestureID: UInt64?
    private var scrollAccumulatorX: CGFloat = 0
    private var scrollAccumulatorY: CGFloat = 0
    private struct PendingPointerSettlement {
      let event: NormalizedTerminalInputEvent
      let receipt: NormalizedTerminalInputReceipt
      let generation: UInt64
      let authority: InputAuthorityIdentity
    }
    private var pendingPointerSettlements: [PendingPointerSettlement] = []
    private struct PointerResizeBarrier {
      let baselineLayoutEpoch: UInt64
      var expectedLayoutEpoch: UInt64?
      var prepareWaiters: [(Result<Void, Error>) -> Void]
      var readyWaiters: [(Result<Void, Error>) -> Void]
      var prepared: Bool
      var abortError: Error?
      var stagedFont: NSFont?
      var stagedCellPixelSize: CGSize?
      var stagedCellPointSize: CGSize?
      var stagedTerminalFontPointSize: CGFloat?
    }
    private var pointerResizeBarrier: PointerResizeBarrier?

    init(
      brokerGeneration: UInt64,
      bootstrapTerminalID: String,
      columns: Int,
      rows: Int,
      backingScale: CGFloat,
      fontPointSize: CGFloat = OuroTheme.terminalFontSize
    ) throws {
      // Reserve before touching Metal or the Ghostty allocator. If any later
      // initialization step throws, permit deinit atomically rolls the slot
      // back. Every production coordinator uses the one process ledger.
      activeSurfacePermit = try PaneSurfaceAdmissionLedger.shared.reserveActive()
      let metalResources = try Self.sharedMetalResources.get()
      let grid = try Self.grid(columns: columns, rows: rows)
      let geometry = TerminalBackingScaleGeometry(
        cellSize: OuroTheme.terminalCellSize(fontSize: fontPointSize),
        backingScale: backingScale
      )
      let scale = geometry.backingScale
      cellPixelSize = CGSize(
        width: geometry.cellWidthPixels,
        height: geometry.cellHeightPixels
      )
      // CoreText draws into a pixel-addressed atlas context. Scale the font
      // together with the pixel cell or Retina displays render it at half size.
      font = OuroTheme.monoFont(size: fontPointSize * scale)
      let stream = GhosttyRenderStream(
        brokerGeneration: brokerGeneration,
        terminalID: "ourocode-surface-bootstrap-\(bootstrapTerminalID)"
      )
      bridge = try GhosttyRenderBridge(
        configuration: GhosttyRenderConfiguration(
          initialStream: stream,
          columns: grid.columns,
          rows: grid.rows,
          cellWidthPixels: UInt32(cellPixelSize.width.rounded(.up)),
          cellHeightPixels: UInt32(cellPixelSize.height.rounded(.up)),
          initialStateSequence: 0
        )
      )
      renderer = try OuroTerminalRenderer(
        resources: metalResources
      )
      view = OuroMetalTerminalView(
        frame: .zero,
        device: metalResources.device,
        renderer: renderer
      )
      super.init()

      view.translatesAutoresizingMaskIntoConstraints = false
      view.inputSink = self
      view.setInputEnabled(false)
      view.setInteractionEnabled(false)
      view.setCellSize(geometry.cellSizeInPoints, fontPointSize: fontPointSize)
      view.setTerminalAccessibilityVisible(false)

      try Self.requireCardinality(bridge: bridge, candidateCount: 0)

      renderer.onLeaseSettled = { [weak self] disposition in
        guard let self else { return }
        self.frameLeaseOutstanding = false
        self.view.refreshMarkedTextPresentation()
        self.drainPendingPointerSettlements()
        if TerminalLeaseSettlementPolicy.shouldResumePendingCommit(
          hasPendingCommit: self.pendingCommit != nil
        ) {
          self.performPendingCommit()
        }
        if self.frameRequested { self.pumpFrame() }
      }
      renderer.onNeedsFrame = { [weak self] in
        self?.requestFrame()
      }
      renderer.onNeedsFullFrame = { [weak self] in
        guard let self else { return }
        do {
          try self.bridge.forceFullFrame()
          self.requestFrame()
        } catch {
          self.onFailure?(error)
        }
      }
      renderer.onFramePrepared = { [weak self] in
        guard let self, self.pendingPresentation != nil else { return }
        TerminalPaneRuntimeTrace.record(
          "renderer.frame.prepared",
          self.presentationReadinessDescription
        )
        self.drawPendingFrameImmediatelyIfReady()
      }
      renderer.onFirstPresented = {
        [weak self] frameGeneration, stateSequence, accessibility in
        guard let self else { return }
        if let presentation = self.pendingPresentation,
          presentation.frameGeneration == frameGeneration,
          stateSequence >= presentation.minimumStateSequence
        {
          self.pendingPresentation = nil
          self.firstPresentedInputAuthority = presentation.inputAuthority
          self.onFirstPresented?(
            presentation.transitionGeneration,
            presentation.terminalID,
            stateSequence,
            accessibility
          )
          if let metadata = presentation.metadata {
            self.onMetadata?(presentation.terminalID, stateSequence, metadata)
          }
          return
        }
        guard !self.presentationQuiesced,
          self.pendingPresentation == nil,
          let activeStream = self.activeStream,
          self.firstPresentedInputAuthority?.terminalID == activeStream.terminalID
        else { return }
        self.onAccessibilityPresented?(
          activeStream.terminalID,
          stateSequence,
          accessibility
        )
      }
      renderer.onError = { [weak self] error in
        self?.onFailure?(error)
      }
    }

    deinit {
      // A returned Candidate can outlive the coordinator in a caller closure.
      // Revoke the shared slot when its owning coordinator disappears anyway.
      candidate?.admissionPermit.release()
      pendingCommit?.candidate.admissionPermit.release()
    }

    func updateTypography(
      geometry: TerminalBackingScaleGeometry,
      fontPointSize: CGFloat = OuroTheme.terminalFontSize
    ) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard var barrier = pointerResizeBarrier,
        barrier.prepared,
        barrier.expectedLayoutEpoch != nil,
        barrier.abortError == nil
      else {
        throw BrokerClientError.invalidRequest(
          "Terminal typography changes require a prepared resize barrier."
        )
      }
      let scale = geometry.backingScale
      let nextCellPointSize = geometry.cellSizeInPoints
      let nextCellPixelSize = CGSize(
        width: geometry.cellWidthPixels,
        height: geometry.cellHeightPixels
      )
      let nextFont = OuroTheme.monoFont(size: fontPointSize * scale)
      TerminalTypographyRuntimeTrace.record(
        "stage",
        "font=\(nextFont.pointSize) cell=\(Int(nextCellPixelSize.width))x\(Int(nextCellPixelSize.height)) oldFont=\(font.pointSize) oldCell=\(Int(cellPixelSize.width))x\(Int(cellPixelSize.height))"
      )
      guard nextCellPixelSize != cellPixelSize || nextFont.pointSize != font.pointSize else {
        return
      }
      barrier.stagedFont = nextFont
      barrier.stagedCellPixelSize = nextCellPixelSize
      barrier.stagedCellPointSize = nextCellPointSize
      barrier.stagedTerminalFontPointSize = fontPointSize
      pointerResizeBarrier = barrier
    }

    /// A point-size change can leave the rounded pixel cell and grid exactly
    /// unchanged. In that case the PTY geometry and kernel winsize must stay
    /// untouched: only the renderer's font/atlas presentation needs a fresh
    /// full frame. This avoids a needless SIGWINCH, pointer barrier, and
    /// broker resize transaction for a visual-only change.
    func updateTypographyWithoutGeometry(
      geometry: TerminalBackingScaleGeometry,
      fontPointSize: CGFloat = OuroTheme.terminalFontSize
    ) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard pointerResizeBarrier == nil else {
        throw BrokerClientError.unavailable("A terminal resize is already in progress.")
      }
      let nextCellPointSize = geometry.cellSizeInPoints
      let nextCellPixelSize = CGSize(
        width: geometry.cellWidthPixels,
        height: geometry.cellHeightPixels
      )
      guard nextCellPixelSize == cellPixelSize else {
        throw TerminalSurfaceCoordinatorError.invalidDimensions
      }
      let nextFont = OuroTheme.monoFont(
        size: fontPointSize * geometry.backingScale
      )
      guard nextFont.pointSize != font.pointSize else { return }
      font = nextFont
      view.setCellSize(nextCellPointSize, fontPointSize: fontPointSize)
      try bridge.forceFullFrame()
      requestFrame()
    }

    var dimensions: (columns: Int, rows: Int) {
      let columns = renderer.scene.columns
      let rows = renderer.scene.rows
      return (columns > 0 ? columns : 80, rows > 0 ? rows : 24)
    }

    var hasInputAuthority: Bool { inputAttachment != nil }

    func install(in container: NSView) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard view.superview !== container else { return }
      view.removeFromSuperview()
      container.addSubview(view)
      NSLayoutConstraint.activate([
        view.topAnchor.constraint(equalTo: container.topAnchor),
        view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      ])
    }

    func setAccessibilityVisible(_ visible: Bool) {
      dispatchPrecondition(condition: .onQueue(.main))
      view.setTerminalAccessibilityVisible(visible)
    }

    /// Geometry-only diagnostic used by the pane recovery trace. Keeping this
    /// in the coordinator prevents callers from reaching into Metal state.
    var presentationReadinessDescription: String {
      dispatchPrecondition(condition: .onQueue(.main))
      return "window=\(view.window != nil) hidden=\(view.isHiddenOrHasHiddenAncestor) "
        + "bounds=\(Int(view.bounds.width))x\(Int(view.bounds.height)) "
        + "drawable=\(Int(view.drawableSize.width))x\(Int(view.drawableSize.height))"
    }

    /// The first recovery frame is a commit fence, not an animation. A staged
    /// MTKView is intentionally absent from the visible workspace and AppKit
    /// may therefore omit its normal display pass. Request an immediate draw
    /// only when concrete window, geometry, and drawable prerequisites hold.
    func requestPendingPresentationDraw() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard pendingPresentation != nil else { return }
      TerminalPaneRuntimeTrace.record(
        "presentation.draw.request",
        presentationReadinessDescription
      )
      view.needsDisplay = true
      drawPendingFrameImmediatelyIfReady()
    }

    private func drawPendingFrameImmediatelyIfReady() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard pendingPresentation != nil,
        view.window != nil,
        !view.isHiddenOrHasHiddenAncestor,
        view.bounds.width > 0,
        view.bounds.height > 0,
        view.drawableSize.width > 0,
        view.drawableSize.height > 0
      else {
        TerminalPaneRuntimeTrace.record(
          "presentation.draw.deferred",
          presentationReadinessDescription
        )
        return
      }
      TerminalPaneRuntimeTrace.record("presentation.draw.immediate")
      view.draw()
    }

    func prepareCandidate(
      brokerGeneration: UInt64,
      prepared: BrokerPreparedRecovery
    ) throws -> Candidate {
      dispatchPrecondition(condition: .onQueue(.main))
      guard candidate == nil else {
        throw TerminalSurfaceCoordinatorError.candidateAlreadyPresent
      }
      let manifest = try Self.manifest(prepared.manifest)
      try bridge.validateRecoveryManifest(manifest)
      let stream = GhosttyRenderStream(
        brokerGeneration: brokerGeneration,
        terminalID: prepared.terminal.id
      )
      // Candidates are globally serialized, not merely bounded per bridge.
      // A throwing begin/restore releases this local permit through deinit.
      let admissionPermit = try PaneSurfaceAdmissionLedger.shared.reserveCandidate()
      let token = try bridge.beginCandidate(
        stream: stream,
        checkpointStateSequence: prepared.cutoverStateSequence
      )
      do {
        try bridge.restoreCandidate(
          token,
          manifest: manifest,
          checkpointStateSequence: prepared.cutoverStateSequence,
          checkpoint: prepared.checkpoint
        )
        let value = Candidate(
          token: token,
          admissionPermit: admissionPermit,
          stream: stream
        )
        candidateStateSequence = prepared.cutoverStateSequence
        // The recovery checkpoint already represents the broker's current
        // coordinate space. Preserve its epoch even when the checkpoint has
        // no later resize event to replay; resetting to zero makes the first
        // post-recovery pointer layout permanently look unacknowledged.
        candidateLayoutEpoch = prepared.terminal.layoutEpoch
        try Self.requireCardinality(bridge: bridge, candidateCount: 1)
        candidate = value
        return value
      } catch {
        try? bridge.abortCandidate(token)
        throw error
      }
    }

    func applyCandidate(_ event: BrokerStateEvent) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let candidate else { throw TerminalSurfaceCoordinatorError.candidateMissing }
      switch event {
      case .ptyBytes(let sequence, let data):
        try bridge.feedCandidate(candidate.token, stateSequence: sequence, bytes: data)
        candidateStateSequence = sequence
      case .resize(let sequence, let columns, let rows, let cellWidth, let cellHeight, let layoutEpoch):
        TerminalTypographyRuntimeTrace.record(
          "event",
          "sequence=\(sequence) cols=\(columns) rows=\(rows) cell=\(cellWidth)x\(cellHeight) epoch=\(layoutEpoch)"
        )
        let grid = try Self.grid(columns: columns, rows: rows)
        try bridge.resizeCandidate(
          candidate.token,
          stateSequence: sequence,
          columns: grid.columns,
          rows: grid.rows,
          cellWidthPixels: UInt32(max(1, cellWidth)),
          cellHeightPixels: UInt32(max(1, cellHeight))
        )
        candidateStateSequence = sequence
        candidateLayoutEpoch = layoutEpoch
      }
    }

    func commitCandidate(
      _ expected: Candidate,
      attachment: BrokerAttachment,
      attachedReadyStateSequence: UInt64,
      presentationGeneration: UInt64,
      completion: @escaping (Result<Void, Error>) -> Void
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard pendingCommit == nil,
        let candidate, candidate.token == expected.token,
        candidate.stream.terminalID == attachment.terminal.id
      else {
        completion(.failure(TerminalSurfaceCoordinatorError.candidateMissing))
        return
      }
      pendingCommit = PendingCommit(
        candidate: expected,
        inputAuthority: InputAuthorityIdentity(attachment),
        attachedReadyStateSequence: attachedReadyStateSequence,
        presentationGeneration: presentationGeneration,
        completion: completion
      )
      if !frameLeaseOutstanding { performPendingCommit() }
    }

    func abortCandidate(_ expected: Candidate? = nil) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let candidate else { return }
      if let expected, expected.token != candidate.token { return }
      try? bridge.abortCandidate(candidate.token)
      candidate.admissionPermit.release()
      self.candidate = nil
      candidateStateSequence = 0
      candidateLayoutEpoch = 0
    }

    @discardableResult
    func invalidateTransition() -> Bool {
      dispatchPrecondition(condition: .onQueue(.main))
      var invalidatedPresentation = false
      if let frameGeneration = pendingPresentation?.frameGeneration {
        invalidatedPresentation = renderer.invalidatePresentation(
          frameGeneration: frameGeneration
        )
        if invalidatedPresentation {
          pendingPresentation = nil
          presentationQuiesced = true
          frameRequested = false
        }
      } else if pendingPresentation != nil {
        invalidatedPresentation = true
        pendingPresentation = nil
        presentationQuiesced = true
        frameRequested = false
      }
      pendingLiveEvents.removeAll(keepingCapacity: true)
      if let pendingCommit {
        self.pendingCommit = nil
        abortCandidate(pendingCommit.candidate)
        pendingCommit.completion(
          .failure(
            BrokerClientError.unavailable(
              "Ghostty presentation invalidated by terminal selection or broker generation change."
            )
          )
        )
      } else {
        abortCandidate()
      }
      return invalidatedPresentation
    }

    func quiescePresentation() {
      dispatchPrecondition(condition: .onQueue(.main))
      presentationQuiesced = true
      frameRequested = false
    }

    func applyAttachedEvent(_ event: BrokerStateEvent) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      if pendingCommit != nil {
        guard pendingLiveEvents.count < 64 else {
          throw TerminalSurfaceCoordinatorError.pendingEventsExceeded
        }
        pendingLiveEvents.append(event)
        return
      }
      try applyActive(event)
    }

    func applyActive(_ event: BrokerStateEvent) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let activeStream else {
        throw TerminalSurfaceCoordinatorError.activeStreamMissing
      }
      switch event {
      case .ptyBytes(let sequence, let data):
        let metadata = try bridge.feedActive(
          stream: activeStream,
          stateSequence: sequence,
          bytes: data,
          previousMetadataEpoch: lastMetadataEpoch
        )
        appliedActiveStateSequence = sequence
        if let metadata {
          lastMetadataEpoch = metadata.epoch
          publishOrStageMetadata(metadata, stream: activeStream, stateSequence: sequence)
        }
        let bells = try bridge.takeBells(
          stream: activeStream,
          minimumStateSequence: appliedActiveStateSequence
        )
        if bells > 0 { onBell?(bells) }
      case .resize(let sequence, let columns, let rows, let cellWidth, let cellHeight, let layoutEpoch):
        if let barrier = pointerResizeBarrier {
          guard barrier.prepared,
            barrier.abortError == nil,
            barrier.expectedLayoutEpoch == layoutEpoch
          else {
            throw BrokerClientError.protocolViolation(
              "Ordered terminal resize did not match its pointer barrier."
            )
          }
        }
        let grid = try Self.grid(columns: columns, rows: rows)
        try bridge.resizeActive(
          stream: activeStream,
          stateSequence: sequence,
          columns: grid.columns,
          rows: grid.rows,
          cellWidthPixels: UInt32(max(1, cellWidth)),
          cellHeightPixels: UInt32(max(1, cellHeight))
        )
        if let barrier = pointerResizeBarrier,
          let stagedFont = barrier.stagedFont,
          let stagedCellPixelSize = barrier.stagedCellPixelSize,
          let stagedCellPointSize = barrier.stagedCellPointSize
        {
          font = stagedFont
          cellPixelSize = stagedCellPixelSize
          view.setCellSize(
            stagedCellPointSize,
            fontPointSize: barrier.stagedTerminalFontPointSize
              ?? OuroTheme.terminalFontSize
          )
        }
        appliedActiveStateSequence = sequence
        activeLayoutEpoch = layoutEpoch
        TerminalTypographyRuntimeTrace.record(
          "resize-applied",
          "epoch=\(layoutEpoch) sequence=\(sequence)"
        )
        pointerGeometryAcknowledgedEpoch = nil
        hoverGestureID = nil
        enqueuePointerGeometryIfReady()
      }
      drainPendingPointerSettlements()
      requestFrame()
    }

    func memoryInfo() throws -> GhosttyRenderMemoryInfo {
      try bridge.memoryInfo()
    }

    /// Closes the pointer gate at the old layout epoch. Active buttons are
    /// cancelled in deterministic button order on the same FIFO sequencer.
    /// Completion waits for both broker receipts and projection-local effects.
    func prepareForResize(
      completion: @escaping (Result<Void, Error>) -> Void
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputBroker != nil, inputAttachment != nil else {
        completion(.failure(BrokerClientError.staleAttachment))
        return
      }
      guard pointerResizeBarrier == nil else {
        completion(
          .failure(
            BrokerClientError.unavailable(
              "A terminal resize pointer barrier is already active."
            )
          )
        )
        return
      }
      pointerResizeBarrier = PointerResizeBarrier(
        baselineLayoutEpoch: activeLayoutEpoch,
        expectedLayoutEpoch: nil,
        prepareWaiters: [completion],
        readyWaiters: [],
        prepared: false,
        abortError: nil,
        stagedFont: nil,
        stagedCellPixelSize: nil,
        stagedCellPointSize: nil,
        stagedTerminalFontPointSize: nil
      )
      TerminalTypographyRuntimeTrace.record(
        "barrier-open",
        "baseline=\(activeLayoutEpoch)"
      )
      pointerGeometryAcknowledgedEpoch = nil
      hoverGestureID = nil
      scrollGestureID = nil
      scrollAccumulatorX = 0
      scrollAccumulatorY = 0
      cancelAllPointerGestures()
      maybeCompleteResizePreparation()
    }

    /// Binds the prepared barrier to the exact ordered resize event that the
    /// host is about to request. The waiter settles only after the projection
    /// applies that event and the matching mouse geometry receipt is accepted.
    func expectPreparedResize(
      layoutEpoch: UInt64,
      completion: @escaping (Result<Void, Error>) -> Void
    ) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard var barrier = pointerResizeBarrier,
        barrier.prepared,
        barrier.expectedLayoutEpoch == nil,
        barrier.abortError == nil,
        layoutEpoch > barrier.baselineLayoutEpoch
      else {
        throw BrokerClientError.invalidRequest(
          "Terminal resize did not match a prepared pointer barrier."
        )
      }
      barrier.expectedLayoutEpoch = layoutEpoch
      barrier.readyWaiters.append(completion)
      pointerResizeBarrier = barrier
      TerminalTypographyRuntimeTrace.record(
        "barrier-expect",
        "baseline=\(barrier.baselineLayoutEpoch) expected=\(layoutEpoch)"
      )
    }

    /// A framed resize rejection preserves the old projection. Re-acknowledge
    /// its geometry before reopening pointer input at that old epoch.
    func abortPreparedResize(_ error: Error) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard var barrier = pointerResizeBarrier else { return }
      barrier.expectedLayoutEpoch = nil
      barrier.abortError = error
      pointerResizeBarrier = barrier
      pointerGeometryAcknowledgedEpoch = nil
      enqueuePointerGeometryIfReady()
    }

    /// Grants input only after the Host has matched this surface's first
    /// drawable presentation to this exact attachment. The focus receipt is
    /// the final gate before AppKit responder and hit-test paths are opened.
    func activateInput(
      broker: BrokerClient,
      attachment: BrokerAttachment,
      completion: @escaping (Result<Void, Error>) -> Void
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard activeStream?.terminalID == attachment.terminal.id else {
        completion(.failure(BrokerClientError.staleAttachment))
        return
      }
      revokeInputLocally()
      inputGeneration &+= 1
      inputBroker = broker
      inputAttachment = attachment
      let activationGeneration = inputGeneration
      enqueueFocus(true) { [weak self] result in
        guard let self else { return }
        switch result {
        case .success:
          guard self.inputGeneration == activationGeneration,
            self.desiredFocus == true,
            let current = self.inputAttachment,
            Self.sameInputAuthority(current, attachment)
          else {
            completion(.failure(BrokerClientError.staleAttachment))
            return
          }
          self.enqueuePointerGeometryIfReady(completion: completion)
        case .failure(let error):
          completion(.failure(error))
        }
      }
    }

    func openInputAfterActivation(attachment: BrokerAttachment) throws {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let current = inputAttachment,
        Self.sameInputAuthority(current, attachment),
        acknowledgedFocus == true,
        desiredFocus == true
      else { throw BrokerClientError.staleAttachment }
      view.setInteractionEnabled(true)
      view.setInputEnabled(true)
    }

    /// Closes AppKit input immediately, then places focus=false behind all
    /// accepted events on the one receipt sequencer. A caller may detach only
    /// after this receipt succeeds.
    func deactivateInputBeforeDetach(
      attachment: BrokerAttachment,
      completion: @escaping (Result<Void, Error>) -> Void
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      view.setInputEnabled(false)
      view.setInteractionEnabled(false)
      guard let current = inputAttachment,
        Self.sameInputAuthority(current, attachment)
      else {
        revokeInputLocally()
        completion(.success(()))
        return
      }
      enqueueFocus(false) { [weak self] result in
        guard let self else { return }
        if case .success = result { self.revokeInputLocally() }
        completion(result)
      }
    }

    func revokeInputLocally() {
      dispatchPrecondition(condition: .onQueue(.main))
      inputGeneration &+= 1
      inputBroker = nil
      inputAttachment = nil
      inputQueue.removeAll(keepingCapacity: true)
      desiredFocus = nil
      acknowledgedFocus = nil
      focusWaiters.removeAll(keepingCapacity: true)
      pendingPointerSettlements.removeAll(keepingCapacity: true)
      activePointerGestures.removeAll(keepingCapacity: true)
      pointerGeometryAcknowledgedEpoch = nil
      pointerGeometryRequestEpoch = nil
      pointerReadinessRepairPending = false
      pointerReadinessNoticePending = false
      hoverGestureID = nil
      scrollGestureID = nil
      scrollAccumulatorX = 0
      scrollAccumulatorY = 0
      view.setInputEnabled(false)
      view.setInteractionEnabled(false)
      failPointerResizeBarrier(BrokerClientError.staleAttachment)
    }

    func terminalView(_ view: OuroMetalTerminalView, key: NormalizedTerminalKey) {
      enqueue(.key(key))
    }

    func terminalView(_ view: OuroMetalTerminalView, commitText text: String) {
      enqueue(.committedText(text))
    }

    func terminalView(_ view: OuroMetalTerminalView, performCommand selectorName: String) {
      if selectorName == "copy:" {
        enqueueCopySelection()
        return
      }
      if selectorName == "selectAll:" {
        enqueueSelectAll()
        return
      }
      guard selectorName == "insertNewline:" else {
        onLockedInteraction?()
        return
      }
      let event = MacKeyboardEvent(keyCode: 36, charactersIgnoringModifiers: "\r")
      guard let press = MacKeyboardNormalizer.key(from: event, action: .press),
        let release = MacKeyboardNormalizer.key(from: event, action: .release)
      else { return }
      enqueue(.key(press))
      enqueue(.key(release))
    }

    func terminalView(_ view: OuroMetalTerminalView, openHyperlinkAt point: NSPoint) -> Bool {
      guard pointerResizeBarrier == nil,
            let stream = activeStream,
            let layout = currentPointerLayout(),
            let sample = layout.sample(locationInView: point)
      else { return false }
      do {
        guard let url = try bridge.hyperlinkURI(
          stream: stream,
          minimumStateSequence: appliedActiveStateSequence,
          column: sample.column,
          row: sample.row
        ) else {
          return false
        }
        // A recognized OSC 8 link is terminal-owned input even when the
        // workspace cannot launch its handler (for example, a missing app or
        // a policy restriction). Consume it so the click never leaks through
        // as a normal terminal mouse event.
        let opened = NSWorkspace.shared.open(url)
        if !opened { NSSound.beep() }
        return true
      } catch {
        onInputNotice?(error)
        return true
      }
    }

    func findScrollback(
      query: String,
      completion: @escaping (Result<TerminalFindResult, Error>) -> Void
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let stream = activeStream else {
        completion(.failure(TerminalSurfaceCoordinatorError.activeStreamMissing))
        return
      }
      findRequestGeneration &+= 1
      let generation = findRequestGeneration
      let minimumStateSequence = appliedActiveStateSequence
      findResultStream = nil
      let bridge = self.bridge

      findCancellationToken?.cancel()
      let cancellationToken = TerminalFindCancellationToken()
      findCancellationToken = cancellationToken
      findQueue.async { [weak self] in
        guard !cancellationToken.isCancelled else { return }
        let result: Result<TerminalFindResult, Error>
        do {
          let projection = try bridge.findProjection(
            stream: stream,
            minimumStateSequence: minimumStateSequence
          )
          guard !cancellationToken.isCancelled else { return }
          result = .success(
            TerminalFindIndex.build(
              text: projection.text,
              query: query,
              totalRows: projection.scrollbar.total,
              requestGeneration: generation
            )
          )
        } catch {
          result = .failure(error)
        }
        DispatchQueue.main.async {
          guard let self,
                self.activeStream == stream,
                self.findRequestGeneration == generation
          else {
            completion(.failure(BrokerClientError.staleAttachment))
            return
          }
          if case .success = result {
            self.findResultStream = stream
          }
          completion(result)
        }
      }
    }

    func revealFindMatch(_ match: TerminalFindMatch) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard let stream = activeStream,
            findResultStream == stream,
            match.requestGeneration == findRequestGeneration
      else { return }
      do {
        let before = try bridge.scrollbar(
          stream: stream,
          minimumStateSequence: appliedActiveStateSequence
        )
        let maximumOffset = before.total - before.length
        let target = min(match.row, maximumOffset)
        try bridge.scrollViewport(
          stream: stream,
          minimumStateSequence: appliedActiveStateSequence,
          request: .row(target)
        )
        let after = try bridge.scrollbar(
          stream: stream,
          minimumStateSequence: appliedActiveStateSequence
        )
        guard after.offset == target else {
          throw GhosttyRenderBridgeError.invalidPayload(
            "Find navigation did not reach its absolute row contract."
          )
        }
        requestFrame()
      } catch {
        findResultStream = nil
        onInputNotice?(error)
      }
    }

    func terminalView(_ view: OuroMetalTerminalView, mouse event: OuroTerminalMouseEvent) {
      guard pointerResizeBarrier == nil else {
        TerminalTypographyRuntimeTrace.record(
          "pointer-drop",
          "reason=barrier kind=\(event.kind) active=\(activeLayoutEpoch) expected=\(String(describing: pointerResizeBarrier?.expectedLayoutEpoch)) prepared=\(pointerResizeBarrier?.prepared == true)"
        )
        if event.kind == .scroll { TerminalScrollRuntimeTrace.record("drop", "resize-barrier") }
        return
      }
      guard let layout = currentPointerLayout(),
        let sample = pointerSample(event.locationInView, layout: layout)
      else {
        TerminalTypographyRuntimeTrace.record(
          "pointer-drop",
          "reason=layout kind=\(event.kind) active=\(activeLayoutEpoch)"
        )
        if event.kind == .scroll { TerminalScrollRuntimeTrace.record("drop", "missing-layout") }
        onLockedInteraction?()
        return
      }
      let modifiers = TerminalPointerNormalizer.modifiers(event.modifiers)
      switch event.kind {
      case .down:
        guard pointerGeometryAcknowledgedEpoch == layout.layoutEpoch,
          let button = TerminalPointerNormalizer.button(number: event.buttonNumber),
          activePointerGestures[event.buttonNumber] == nil
        else {
          TerminalTypographyRuntimeTrace.record(
            "pointer-drop",
            "reason=ack kind=down active=\(activeLayoutEpoch) ack=\(String(describing: pointerGeometryAcknowledgedEpoch))"
          )
          onLockedInteraction?()
          return
        }
        let gesture = ActivePointerGesture(
          id: nextGestureID(),
          layoutEpoch: layout.layoutEpoch,
          button: button,
          sample: sample,
          modifiers: modifiers,
          cancelling: false
        )
        activePointerGestures[event.buttonNumber] = gesture
        enqueue(
          .mouse(
            gestureID: gesture.id,
            layoutEpoch: gesture.layoutEpoch,
            action: .press,
            button: gesture.button,
            modifiers: modifiers,
            xQ8: sample.xQ8,
            yQ8: sample.yQ8
          ))
      case .drag:
        guard var gesture = activePointerGestures[event.buttonNumber] else { return }
        gesture.sample = sample
        gesture.modifiers = modifiers
        activePointerGestures[event.buttonNumber] = gesture
        enqueue(
          .mouse(
            gestureID: gesture.id,
            layoutEpoch: gesture.layoutEpoch,
            action: .motion,
            button: gesture.button,
            modifiers: modifiers,
            xQ8: sample.xQ8,
            yQ8: sample.yQ8
          ))
      case .up:
        guard var gesture = activePointerGestures[event.buttonNumber] else { return }
        gesture.sample = sample
        gesture.modifiers = modifiers
        activePointerGestures[event.buttonNumber] = gesture
        enqueue(
          .mouse(
            gestureID: gesture.id,
            layoutEpoch: gesture.layoutEpoch,
            action: .release,
            button: gesture.button,
            modifiers: modifiers,
            xQ8: sample.xQ8,
            yQ8: sample.yQ8
          ))
      case .move:
        guard pointerGeometryAcknowledgedEpoch == layout.layoutEpoch else { return }
        let gestureID = hoverGestureID ?? nextGestureID()
        hoverGestureID = gestureID
        enqueue(
          .mouse(
            gestureID: gestureID,
            layoutEpoch: layout.layoutEpoch,
            action: .motion,
            button: .none,
            modifiers: modifiers,
            xQ8: sample.xQ8,
            yQ8: sample.yQ8
          ))
      case .scroll:
        enqueueScroll(event, layout: layout, sample: sample, modifiers: modifiers)
      }
    }

    func terminalViewCancelPointerGestures(_ view: OuroMetalTerminalView) {
      cancelAllPointerGestures()
    }

    private func currentPointerLayout() -> TerminalPointerLayout? {
      guard activeLayoutEpoch > 0 else { return nil }
      let scale = max(1, view.window?.backingScaleFactor ?? 1)
      let grid = dimensions
      return TerminalPointerLayout(
        layoutEpoch: activeLayoutEpoch,
        screenSize: CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale),
        cellSize: cellPixelSize,
        contentInset: OuroTheme.terminalContentInset * scale,
        columns: grid.columns,
        rows: grid.rows
      )
    }

    private func pointerSample(
      _ point: CGPoint,
      layout: TerminalPointerLayout
    ) -> TerminalPointerSample? {
      let scale = max(1, view.window?.backingScaleFactor ?? 1)
      return layout.sample(
        locationInView: CGPoint(x: point.x * scale, y: point.y * scale)
      )
    }

    private func nextGestureID() -> UInt64 {
      nextPointerGestureID &+= 1
      if nextPointerGestureID == 0 { nextPointerGestureID = 1 }
      return nextPointerGestureID
    }

    private func enqueueScroll(
      _ event: OuroTerminalMouseEvent,
      layout: TerminalPointerLayout,
      sample: TerminalPointerSample,
      modifiers: NormalizedTerminalModifiers
    ) {
      guard pointerGeometryAcknowledgedEpoch == layout.layoutEpoch else {
        TerminalScrollRuntimeTrace.record(
          "drop",
          "geometry acknowledged=\(String(describing: pointerGeometryAcknowledgedEpoch)) layout=\(layout.layoutEpoch)"
        )
        return
      }
      let scale = max(1, view.window?.backingScaleFactor ?? 1)
      let precise = event.hasPreciseScrollingDeltas
      let deltaX = CGFloat(event.deltaX) * scale
      let deltaY = CGFloat(event.deltaY) * scale
      let boundary = TerminalPointerNormalizer.scrollBoundary(
        precise: precise,
        phase: event.phase,
        momentumPhase: event.momentumPhase
      )
      let cancelled = boundary.cancelled
      let ending = boundary.ending
      let directions = TerminalPointerNormalizer.scrollDirections(
        deltaX: deltaX,
        deltaY: deltaY,
        precise: precise,
        cellSize: cellPixelSize,
        ending: ending,
        cancelled: cancelled,
        accumulatorX: &scrollAccumulatorX,
        accumulatorY: &scrollAccumulatorY
      )
      TerminalScrollRuntimeTrace.record(
        "normalize",
        "deltaX=\(deltaX) deltaY=\(deltaY) precise=\(precise) ending=\(ending) cancelled=\(cancelled) directions=\(directions) layout=\(layout.layoutEpoch)"
      )
      if scrollGestureID == nil { scrollGestureID = nextGestureID() }
      if let gestureID = scrollGestureID {
        for direction in directions {
          enqueue(
            .scroll(
              gestureID: gestureID,
              layoutEpoch: layout.layoutEpoch,
              direction: direction,
              modifiers: modifiers,
              xQ8: sample.xQ8,
              yQ8: sample.yQ8
            ))
        }
      }
      if ending || cancelled {
        scrollGestureID = nil
      }
    }

    private func cancelAllPointerGestures() {
      // Losing focus cancels ownership of in-flight gestures, but it does not
      // change the projection geometry. Resize, attachment, and detach paths
      // invalidate the ACK explicitly before calling this helper.
      hoverGestureID = nil
      scrollGestureID = nil
      scrollAccumulatorX = 0
      scrollAccumulatorY = 0
      for key in activePointerGestures.keys.sorted() {
        guard var gesture = activePointerGestures[key], !gesture.cancelling else { continue }
        gesture.cancelling = true
        activePointerGestures[key] = gesture
        enqueue(
          .mouse(
            gestureID: gesture.id,
            layoutEpoch: gesture.layoutEpoch,
            action: .cancel,
            button: gesture.button,
            modifiers: gesture.modifiers,
            xQ8: gesture.sample.xQ8,
            yQ8: gesture.sample.yQ8
          ))
      }
      maybeCompleteResizePreparation()
    }

    private func maybeCompleteResizePreparation() {
      guard var barrier = pointerResizeBarrier, !barrier.prepared else { return }
      let queuedProjectionInput = inputQueue.contains { queued in
        switch queued.action {
        case .copySelection, .selectAll, .scrollViewport:
          return true
        case .broker(let event):
          return Self.isPointerEvent(event)
        }
      }
      guard activePointerGestures.isEmpty,
        pendingPointerSettlements.isEmpty,
        inputFlight?.pointer != true,
        !queuedProjectionInput,
        !frameLeaseOutstanding
      else { return }
      barrier.prepared = true
      let waiters = barrier.prepareWaiters
      barrier.prepareWaiters.removeAll(keepingCapacity: false)
      pointerResizeBarrier = barrier
      for waiter in waiters { waiter(.success(())) }
    }

    private func finishPointerResizeBarrierIfReady(geometryEpoch: UInt64) {
      guard let barrier = pointerResizeBarrier, barrier.prepared else { return }
      let matchesExpected = barrier.expectedLayoutEpoch == geometryEpoch
        && barrier.abortError == nil
      let restoresBaseline = barrier.abortError != nil
        && barrier.expectedLayoutEpoch == nil
        && barrier.baselineLayoutEpoch == geometryEpoch
      guard matchesExpected || restoresBaseline else { return }
      TerminalTypographyRuntimeTrace.record(
        "pointer-ready",
        "epoch=\(geometryEpoch) expected=\(String(describing: barrier.expectedLayoutEpoch))"
      )
      pointerResizeBarrier = nil
      let result: Result<Void, Error>
      if let error = barrier.abortError {
        result = .failure(error)
      } else {
        result = .success(())
      }
      for waiter in barrier.readyWaiters { waiter(result) }
    }

    private func failPointerResizeBarrier(_ error: Error) {
      guard let barrier = pointerResizeBarrier else { return }
      pointerResizeBarrier = nil
      for waiter in barrier.prepareWaiters { waiter(.failure(error)) }
      for waiter in barrier.readyWaiters { waiter(.failure(error)) }
    }

    private static func isPointerEvent(_ event: NormalizedTerminalInputEvent) -> Bool {
      switch event {
      case .mouseGeometry, .mouse, .scroll:
        return true
      case .key, .committedText, .paste, .focus:
        return false
      }
    }

    func terminalView(_ view: OuroMetalTerminalView, paste text: String) {
      let bytes = Data(text.utf8)
      guard bytes.count <= NormalizedTerminalInputEvent.maximumPasteBytes else {
        onInputNotice?(
          BrokerClientError.invalidRequest("Paste is larger than 65,524 bytes."))
        return
      }
      let owned = String(decoding: bytes, as: UTF8.self)
      if Self.pasteRequiresConfirmation(owned) {
        let alert = NSAlert()
        alert.messageText = "Paste multiple lines?"
        alert.informativeText =
          "This paste contains line breaks or control characters and may run commands in the terminal."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Paste")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
      }
      enqueue(.paste(owned))
    }

    /// Mirrors Ghostty/Kaku's Cmd-K contract through the canonical PTY input
    /// lane. Control-L is the portable shell/readline clear-screen primitive;
    /// unlike locally rewriting the retained projection it cannot diverge from
    /// the broker-owned terminal state after a reconnect.
    func clearScreen() {
      dispatchPrecondition(condition: .onQueue(.main))
      let event = MacKeyboardEvent(
        keyCode: 37,
        modifiers: [.control],
        charactersIgnoringModifiers: "l"
      )
      guard let press = MacKeyboardNormalizer.key(from: event, action: .press),
        let release = MacKeyboardNormalizer.key(from: event, action: .release)
      else { return }
      enqueue(.key(press))
      enqueue(.key(release))
    }

    func scrollToTop() {
      scrollViewport(to: .top)
    }

    func scrollToBottom() {
      scrollViewport(to: .bottom)
    }

    /// Types a one-shot launch command only after the input lease and focus
    /// barrier are active. This keeps the account zsh alive and reads .zshrc
    /// exactly once instead of using `zsh -lic ...; exec zsh -li`.
    func sendCommandLine(_ command: String) {
      guard !command.isEmpty else { return }
      enqueue(.committedText(command))
      let event = MacKeyboardEvent(keyCode: 36, charactersIgnoringModifiers: "\r")
      guard let press = MacKeyboardNormalizer.key(from: event, action: .press),
        let release = MacKeyboardNormalizer.key(from: event, action: .release)
      else { return }
      enqueue(.key(press))
      enqueue(.key(release))
    }

    func terminalView(_ view: OuroMetalTerminalView, focusChanged focused: Bool) {
      onFocusChange?(focused)
      if focused {
        enqueueFocus(true) { [weak self] result in
          guard case .success = result else { return }
          guard let self, self.pointerResizeBarrier == nil else { return }
          self.enqueuePointerGeometryIfReady()
        }
      } else {
        enqueueFocus(false)
      }
    }

    func matchesFirstPresentedAttachment(_ attachment: BrokerAttachment) -> Bool {
      firstPresentedInputAuthority == InputAuthorityIdentity(attachment)
    }

    /// Presentation identity alone is not enough for a resize transaction:
    /// reconnect and authority revocation intentionally leave the last frame
    /// visible while clearing the live input lane. Callers that resize during
    /// the first-frame lock must match the currently bound authority too.
    func hasInputAuthority(for attachment: BrokerAttachment) -> Bool {
      guard let current = inputAttachment else { return false }
      return Self.sameInputAuthority(current, attachment)
    }

    private func enqueueFocus(
      _ focused: Bool,
      completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
      if let completion {
        if acknowledgedFocus == focused, desiredFocus == focused {
          completion(.success(()))
          return
        }
        focusWaiters[focused, default: []].append(completion)
      }
      guard desiredFocus != focused else {
        return
      }
      desiredFocus = focused
      enqueue(.focus(focused))
    }

    private func enqueuePointerGeometryIfReady(
      completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
      guard inputBroker != nil, inputAttachment != nil,
        let layout = currentPointerLayout(),
        let geometry = layout.wireGeometry
      else {
        completion?(.success(()))
        return
      }
      pointerGeometryRequestEpoch = layout.layoutEpoch
      pointerGeometryAcknowledgedEpoch = nil
      hoverGestureID = nil
      TerminalTypographyRuntimeTrace.record(
        "geometry-send",
        "epoch=\(layout.layoutEpoch) barrier=\(pointerResizeBarrier != nil)"
      )
      enqueue(.mouseGeometry(layoutEpoch: layout.layoutEpoch, geometry)) { [weak self] result in
        guard let self else { return }
        if self.pointerGeometryRequestEpoch == layout.layoutEpoch {
          self.pointerGeometryRequestEpoch = nil
        }
        switch result {
        case .success(let receipt):
          TerminalTypographyRuntimeTrace.record(
            "geometry-receipt",
            "requested=\(layout.layoutEpoch) receipt=\(receipt.layoutEpoch) active=\(self.activeLayoutEpoch)"
          )
          guard receipt.layoutEpoch == layout.layoutEpoch,
            self.activeLayoutEpoch == layout.layoutEpoch
          else {
            completion?(.failure(BrokerClientError.staleAttachment))
            return
          }
          self.pointerGeometryAcknowledgedEpoch = layout.layoutEpoch
          completion?(.success(()))
        case .failure(let error):
          TerminalTypographyRuntimeTrace.record("geometry-failed", error.localizedDescription)
          completion?(.failure(error))
        }
      }
    }

    private func enqueue(
      _ event: NormalizedTerminalInputEvent,
      completion: ((Result<NormalizedTerminalInputReceipt, Error>) -> Void)? = nil
    ) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputBroker != nil, inputAttachment != nil else {
        onLockedInteraction?()
        completion?(.failure(BrokerClientError.staleAttachment))
        return
      }
      do {
        _ = try event.validatedWireObject()
      } catch {
        completion?(.failure(error))
        onInputNotice?(error)
        return
      }
      if completion == nil, coalesceQueuedPointerMotion(event) { return }
      guard inputQueue.count < Self.maximumQueuedInputEvents else {
        let error = BrokerClientError.unavailable(
          "Terminal input is paused because its receipt queue is full.")
        completion?(.failure(error))
        failInput(error, revokeAuthority: true)
        return
      }
      inputQueue.append(
        QueuedInput(
          action: .broker(event),
          generation: inputGeneration,
          completion: completion
        )
      )
      pumpInput()
    }

    private func enqueueCopySelection() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputBroker != nil, inputAttachment != nil else {
        onLockedInteraction?()
        return
      }
      guard inputQueue.count < Self.maximumQueuedInputEvents else {
        failInput(
          BrokerClientError.unavailable(
            "Terminal input is paused because its receipt queue is full."),
          revokeAuthority: true
        )
        return
      }
      inputQueue.append(
        QueuedInput(
          action: .copySelection,
          generation: inputGeneration,
          completion: nil
        )
      )
      pumpInput()
    }

    private func enqueueSelectAll() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputBroker != nil, inputAttachment != nil else {
        onLockedInteraction?()
        return
      }
      guard inputQueue.count < Self.maximumQueuedInputEvents else {
        failInput(
          BrokerClientError.unavailable(
            "Terminal input is paused because its receipt queue is full."),
          revokeAuthority: true
        )
        return
      }
      inputQueue.append(
        QueuedInput(action: .selectAll, generation: inputGeneration, completion: nil)
      )
      pumpInput()
    }

    private func performCopySelection() throws {
      guard let stream = activeStream else {
        throw TerminalSurfaceCoordinatorError.activeStreamMissing
      }
      guard let value = try bridge.copySelection(
        stream: stream,
        minimumStateSequence: appliedActiveStateSequence
      ), !value.isEmpty else {
        NSSound.beep()
        return
      }
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      guard pasteboard.setString(value, forType: .string) else {
        throw BrokerClientError.unavailable("The selected terminal text could not be copied.")
      }
    }

    /// Selects the complete retained grid using stable Ghostty grid refs while
    /// preserving the user's viewport. This uses the same serialized local
    /// selection path as pointer drags and does not duplicate scrollback text
    /// in an AppKit-side model.
    private func performSelectAll() throws {
      guard let stream = activeStream, let layout = currentPointerLayout() else {
        throw TerminalSurfaceCoordinatorError.activeStreamMissing
      }
      let minimumStateSequence = appliedActiveStateSequence
      let before = try bridge.scrollbar(
        stream: stream,
        minimumStateSequence: minimumStateSequence
      )
      let restoreOffset = before.offset
      var shouldRestoreViewport = false
      defer {
        if shouldRestoreViewport {
          try? bridge.scrollViewport(
            stream: stream,
            minimumStateSequence: minimumStateSequence,
            request: .row(restoreOffset)
          )
          requestFrame()
        }
      }

      try bridge.scrollViewport(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        request: .top
      )
      shouldRestoreViewport = true
      let start = GhosttyRenderSelectionPoint(
        column: 0,
        row: 0,
        surfaceX: Double(layout.contentInset),
        surfaceY: 0,
        timeNanoseconds: nil
      )
      _ = try bridge.selectionBegin(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        point: start
      )

      try bridge.scrollViewport(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        request: .bottom
      )
      let end = GhosttyRenderSelectionPoint(
        column: UInt16(max(0, layout.columns - 1)),
        row: UInt32(max(0, layout.rows - 1)),
        surfaceX: Double(layout.screenSize.width - layout.contentInset),
        surfaceY: Double(layout.screenSize.height),
        timeNanoseconds: nil
      )
      let geometry = GhosttyRenderSelectionGeometry(
        columns: UInt32(layout.columns),
        cellWidth: Double(layout.cellSize.width),
        paddingLeft: Double(layout.contentInset),
        screenHeight: Double(layout.screenSize.height)
      )
      let update = try bridge.selectionUpdate(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        point: end,
        geometry: geometry,
        rectangle: false
      )
      let finish = try bridge.selectionEnd(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        point: end
      )
      guard update.hasSelection || finish.hasSelection else {
        NSSound.beep()
        return
      }
      try bridge.scrollViewport(
        stream: stream,
        minimumStateSequence: minimumStateSequence,
        request: .row(restoreOffset)
      )
      shouldRestoreViewport = false
      requestFrame()
    }

    private func scrollViewport(to request: GhosttyRenderViewportScroll) {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputBroker != nil, inputAttachment != nil else {
        onLockedInteraction?()
        return
      }
      guard inputQueue.count < Self.maximumQueuedInputEvents else {
        failInput(
          BrokerClientError.unavailable(
            "Terminal input is paused because its receipt queue is full."),
          revokeAuthority: true
        )
        return
      }
      // Coalesce repeated Home/End presses while a frame lease settles. The
      // newest absolute destination subsumes earlier history navigation.
      if let last = inputQueue.last,
        last.generation == inputGeneration,
        case .scrollViewport = last.action
      {
        inputQueue[inputQueue.count - 1] = QueuedInput(
          action: .scrollViewport(request),
          generation: inputGeneration,
          completion: nil
        )
      } else {
        inputQueue.append(
          QueuedInput(
            action: .scrollViewport(request),
            generation: inputGeneration,
            completion: nil
          )
        )
      }
      pumpInput()
    }

    private func performScrollViewport(_ request: GhosttyRenderViewportScroll) throws {
      guard let stream = activeStream else {
        throw TerminalSurfaceCoordinatorError.activeStreamMissing
      }
      try bridge.scrollViewport(
        stream: stream,
        minimumStateSequence: appliedActiveStateSequence,
        request: request
      )
      requestFrame()
    }

    private func pumpInput() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard inputFlight == nil, pendingPointerSettlements.isEmpty, !frameLeaseOutstanding,
        !inputQueue.isEmpty,
        let broker = inputBroker, let attachment = inputAttachment
      else { return }
      let queued = inputQueue[0]
      if case .copySelection = queued.action {
        guard pendingPointerSettlements.isEmpty else { return }
        inputQueue.removeFirst()
        guard queued.generation == inputGeneration else {
          pumpInput()
          return
        }
        do {
          try performCopySelection()
        } catch {
          onInputNotice?(error)
        }
        maybeCompleteResizePreparation()
        pumpInput()
        return
      }
      if case .selectAll = queued.action {
        inputQueue.removeFirst()
        guard queued.generation == inputGeneration else {
          pumpInput()
          return
        }
        do {
          try performSelectAll()
        } catch {
          onInputNotice?(error)
        }
        maybeCompleteResizePreparation()
        pumpInput()
        return
      }
      if case .scrollViewport(let request) = queued.action {
        inputQueue.removeFirst()
        guard queued.generation == inputGeneration else {
          pumpInput()
          return
        }
        do {
          try performScrollViewport(request)
        } catch {
          onInputNotice?(error)
        }
        maybeCompleteResizePreparation()
        pumpInput()
        return
      }
      guard case .broker(let event) = queued.action else { return }
      inputQueue.removeFirst()
      nextInputFlightToken &+= 1
      if nextInputFlightToken == 0 { nextInputFlightToken = 1 }
      let flightToken = nextInputFlightToken
      inputFlight = (
        token: flightToken,
        generation: queued.generation,
        pointer: Self.isPointerEvent(event)
      )
      broker.normalizedInput(event, using: attachment) { [weak self] result in
        guard let self else { return }
        guard self.inputFlight?.token == flightToken else { return }
        self.inputFlight = nil
        guard queued.generation == self.inputGeneration else {
          self.pumpInput()
          return
        }
        switch result {
        case .success(let receipt):
          self.handleAcceptedInput(
            event,
            receipt: receipt,
            generation: queued.generation
          )
          if case .focus(let focused) = event {
            self.acknowledgedFocus = focused
            let waiters = self.focusWaiters.removeValue(forKey: focused) ?? []
            for waiter in waiters { waiter(.success(())) }
          }
          queued.completion?(.success(receipt))
          self.maybeCompleteResizePreparation()
          self.pumpInput()
        case .failure(let error):
          queued.completion?(.failure(error))
          self.failInput(error, revokeAuthority: true)
        }
      }
    }

    private func coalesceQueuedPointerMotion(_ event: NormalizedTerminalInputEvent) -> Bool {
      guard let last = inputQueue.last,
        last.generation == inputGeneration,
        last.completion == nil,
        case .broker(let lastEvent) = last.action,
        Self.samePointerMotionRoute(lastEvent, event)
      else { return false }
      inputQueue[inputQueue.count - 1] = QueuedInput(
        action: .broker(event),
        generation: inputGeneration,
        completion: nil
      )
      return true
    }

    private static func samePointerMotionRoute(
      _ lhs: NormalizedTerminalInputEvent,
      _ rhs: NormalizedTerminalInputEvent
    ) -> Bool {
      guard case let .mouse(lhsID, lhsEpoch, lhsAction, lhsButton, lhsModifiers, _, _) = lhs,
        case let .mouse(rhsID, rhsEpoch, rhsAction, rhsButton, rhsModifiers, _, _) = rhs
      else { return false }
      return lhsAction == .motion && rhsAction == .motion
        && lhsID == rhsID && lhsEpoch == rhsEpoch
        && lhsButton == rhsButton && lhsModifiers == rhsModifiers
    }

    private func handleAcceptedInput(
      _ event: NormalizedTerminalInputEvent,
      receipt: NormalizedTerminalInputReceipt,
      generation: UInt64
    ) {
      if case .scroll(_, _, let direction, _, _, _) = event {
        TerminalScrollRuntimeTrace.record(
          "receipt",
          "direction=\(direction) disposition=\(String(describing: receipt.pointerDisposition)) observed=\(receipt.observedStateSequence) layout=\(receipt.layoutEpoch) activeLayout=\(activeLayoutEpoch) applied=\(appliedActiveStateSequence)"
        )
      }
      if let disposition = receipt.pointerDisposition,
        disposition != .pty,
        let attachment = inputAttachment
      {
        pendingPointerSettlements.append(
          PendingPointerSettlement(
            event: event,
            receipt: receipt,
            generation: generation,
            authority: InputAuthorityIdentity(attachment)
          )
        )
        drainPendingPointerSettlements()
      }
      switch event {
      case .mouseGeometry(let layoutEpoch, _):
        if receipt.layoutEpoch == layoutEpoch, activeLayoutEpoch == layoutEpoch {
          pointerGeometryAcknowledgedEpoch = layoutEpoch
          pointerReadinessRepairPending = false
          finishPointerResizeBarrierIfReady(geometryEpoch: layoutEpoch)
          if pointerResizeBarrier == nil, pointerReadinessNoticePending {
            pointerReadinessNoticePending = false
            onPointerReady?()
          }
        }
      case .mouse(let gestureID, _, let action, let button, _, _, _):
        guard action == .release || action == .cancel,
          let key = Self.pointerRouteKey(button),
          activePointerGestures[key]?.id == gestureID
        else { return }
        activePointerGestures.removeValue(forKey: key)
      case .key, .committedText, .scroll, .paste, .focus:
        break
      }
    }

    /// Registers interest in the next usable pointer geometry. This is a
    /// level-triggered companion to `onPointerReady`: a transient lock can be
    /// reported after the ACK edge has already arrived, so the host must be
    /// able to ask whether readiness is already true without missing it.
    func requestPointerReadyNotice() {
      dispatchPrecondition(condition: .onQueue(.main))
      if pointerResizeBarrier == nil,
        pointerGeometryAcknowledgedEpoch == activeLayoutEpoch
      {
        pointerReadinessRepairPending = false
        pointerReadinessNoticePending = false
        onPointerReady?()
      } else {
        pointerReadinessNoticePending = true
        // A resize barrier normally gets its geometry ACK from the first
        // queued request.  That request can nevertheless be lost at the
        // presentation/input boundary (for example when a focus or tab
        // transition races the broker's ordered resize event).  Once the
        // projection has applied the barrier's expected epoch, re-queue the
        // same geometry as a level-triggered repair.  The barrier remains
        // closed while the repair is in flight, so this cannot open input on
        // an ambiguous coordinate space; it only gives the ordered input
        // lane another chance to acknowledge the already-applied layout.
        let barrier = pointerResizeBarrier
        if TerminalPointerReadinessPolicy.shouldRepair(
          barrierPresent: barrier != nil,
          barrierPrepared: barrier?.prepared == true,
          barrierAborted: barrier?.abortError != nil,
          expectedLayoutEpoch: barrier?.expectedLayoutEpoch,
          activeLayoutEpoch: activeLayoutEpoch,
          repairPending: pointerReadinessRepairPending
        ) {
          pointerReadinessRepairPending = true
          TerminalTypographyRuntimeTrace.record(
            "pointer-repair",
            "epoch=\(activeLayoutEpoch) barrier=\(pointerResizeBarrier != nil)"
          )
          enqueuePointerGeometryIfReady { [weak self] _ in
            guard let self else { return }
            self.pointerReadinessRepairPending = false
          }
        }
      }
    }

    private func drainPendingPointerSettlements() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard !frameLeaseOutstanding else { return }
      while let settlement = pendingPointerSettlements.first {
        guard appliedActiveStateSequence >= settlement.receipt.observedStateSequence else {
          return
        }
        pendingPointerSettlements.removeFirst()
        guard settlement.generation == inputGeneration,
          let attachment = inputAttachment,
          settlement.authority == InputAuthorityIdentity(attachment),
          settlement.receipt.layoutEpoch == activeLayoutEpoch
        else {
          continue
        }
        do {
          try applyLocalPointerEffect(settlement)
          requestFrame()
          if frameLeaseOutstanding { return }
        } catch {
          failInput(error, revokeAuthority: true)
          return
        }
      }
      maybeCompleteResizePreparation()
      pumpInput()
    }

    private func applyLocalPointerEffect(_ settlement: PendingPointerSettlement) throws {
      guard let stream = activeStream,
        let layout = currentPointerLayout(),
        layout.layoutEpoch == settlement.receipt.layoutEpoch
      else { throw BrokerClientError.staleAttachment }
      let minimumStateSequence = settlement.receipt.observedStateSequence
      switch (settlement.receipt.pointerDisposition, settlement.event) {
      case (
        .localSelection?,
        .mouse(_, _, let action, let button, let modifiers, let xQ8, let yQ8)
      ):
        guard button == .left,
          let sample = layout.sample(
            surfaceX: CGFloat(Double(xQ8) / 256),
            surfaceY: CGFloat(Double(yQ8) / 256)
          )
        else { return }
        let point = GhosttyRenderSelectionPoint(
          column: sample.column,
          row: sample.row,
          surfaceX: sample.surfaceX,
          surfaceY: sample.surfaceY,
          timeNanoseconds: nil
        )
        let geometry = GhosttyRenderSelectionGeometry(
          columns: UInt32(layout.columns),
          cellWidth: Double(layout.cellSize.width),
          paddingLeft: Double(layout.contentInset),
          screenHeight: Double(layout.screenSize.height)
        )
        switch action {
        case .press:
          _ = try bridge.selectionBegin(
            stream: stream,
            minimumStateSequence: minimumStateSequence,
            point: point
          )
        case .motion:
          _ = try bridge.selectionUpdate(
            stream: stream,
            minimumStateSequence: minimumStateSequence,
            point: point,
            geometry: geometry,
            rectangle: modifiers.contains(.option)
          )
        case .release:
          _ = try bridge.selectionEnd(
            stream: stream,
            minimumStateSequence: minimumStateSequence,
            point: point
          )
        case .cancel:
          _ = try bridge.selectionCancel(
            stream: stream,
            minimumStateSequence: minimumStateSequence
          )
        }
      case (
        .localScrollback?,
        .scroll(_, _, let direction, _, _, _)
      ):
        let scrollbar = try bridge.scrollbar(
          stream: stream,
          minimumStateSequence: minimumStateSequence
        )
        guard let request = TerminalScrollProjectionPolicy.request(
          direction: direction,
          total: scrollbar.total,
          offset: scrollbar.offset,
          length: scrollbar.length
        ) else {
          TerminalScrollRuntimeTrace.record(
            "render-boundary",
            "direction=\(direction) total=\(scrollbar.total) length=\(scrollbar.length) offset=\(scrollbar.offset)"
          )
          return
        }
        TerminalScrollRuntimeTrace.record(
          "render-before",
          "direction=\(direction) total=\(scrollbar.total) length=\(scrollbar.length) offset=\(scrollbar.offset) request=\(request)"
        )
        let bridgeRequest: GhosttyRenderViewportScroll
        switch request {
        case .row(let value): bridgeRequest = .row(value)
        case .bottom: bridgeRequest = .bottom
        }
        try bridge.scrollViewport(
          stream: stream,
          minimumStateSequence: minimumStateSequence,
          request: bridgeRequest
        )
        let after = try bridge.scrollbar(
          stream: stream,
          minimumStateSequence: minimumStateSequence
        )
        let expectedOffset: UInt64
        switch request {
        case .row(let value): expectedOffset = value
        case .bottom: expectedOffset = after.total - after.length
        }
        guard after.offset == expectedOffset else {
          throw GhosttyRenderBridgeError.invalidPayload(
            "Viewport scroll did not reach its absolute row contract."
          )
        }
        TerminalScrollRuntimeTrace.record(
          "render-after",
          "direction=\(direction) total=\(after.total) length=\(after.length) offset=\(scrollbar.offset)->\(after.offset)"
        )
      case (.pty?, _), (nil, _), (.localSelection?, _), (.localScrollback?, _):
        return
      }
    }

    private static func pointerRouteKey(_ button: NormalizedTerminalMouseButton) -> Int? {
      switch button {
      case .none: return nil
      case .left: return 0
      case .right: return 1
      case .middle: return 2
      case .four: return 3
      case .five: return 4
      case .six: return 5
      case .seven: return 6
      case .eight: return 7
      case .nine: return 8
      case .ten: return 9
      case .eleven: return 10
      }
    }

    private func failInput(_ error: Error, revokeAuthority: Bool) {
      if revokeAuthority {
        let waiters = focusWaiters.values.flatMap { $0 }
        revokeInputLocally()
        for waiter in waiters { waiter(.failure(error)) }
      }
      onInputFailure?(error)
    }

    private static func sameInputAuthority(
      _ lhs: BrokerAttachment,
      _ rhs: BrokerAttachment
    ) -> Bool {
      lhs.terminal.id == rhs.terminal.id
        && lhs.inputEpoch == rhs.inputEpoch
        && lhs.leaseID == rhs.leaseID
    }

    private static func pasteRequiresConfirmation(_ value: String) -> Bool {
      value.unicodeScalars.contains { scalar in
        scalar.value < 0x20 || scalar.value == 0x7f
      }
    }

    private func requestFrame() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard !presentationQuiesced else {
        frameRequested = false
        return
      }
      frameRequested = true
      pumpFrame()
    }

    private func pumpFrame() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard frameRequested, !frameLeaseOutstanding else { return }
      frameRequested = false
      do {
        let lease = try bridge.acquireFrame()
        guard !frameLeaseOutstanding else {
          try? lease.finish(.retry)
          throw TerminalSurfaceCoordinatorError.frameAlreadyLeased
        }
        if var presentation = pendingPresentation,
          presentation.frameGeneration == nil,
          lease.frame.stateSequence >= presentation.minimumStateSequence,
          lease.frame.dirty == .full
        {
          presentation.frameGeneration = lease.frame.generation
          pendingPresentation = presentation
        }
        frameLeaseOutstanding = true
        renderer.submit(lease, font: font, cellPixelSize: cellPixelSize)
      } catch {
        onFailure?(error)
      }
    }

    private func performPendingCommit() {
      dispatchPrecondition(condition: .onQueue(.main))
      guard !frameLeaseOutstanding, let pendingCommit else { return }
      self.pendingCommit = nil
      do {
        guard let candidate, candidate.token == pendingCommit.candidate.token else {
          throw TerminalSurfaceCoordinatorError.candidateMissing
        }
        // A superseded Metal presentation can settle as RETRY after its lease
        // leaves the renderer. That retry belongs to the old terminal and must
        // not keep the new candidate BUSY forever.
        try bridge.cancelFrameRetry()
        try bridge.commitCandidate(
          candidate.token,
          attachedReadyStateSequence: pendingCommit.attachedReadyStateSequence
        )
        candidate.admissionPermit.release()
        pendingPointerSettlements.removeAll(keepingCapacity: true)
        activeStream = candidate.stream
        appliedActiveStateSequence = max(
          pendingCommit.attachedReadyStateSequence,
          candidateStateSequence
        )
        activeLayoutEpoch = candidateLayoutEpoch
        lastMetadataEpoch = nil
        self.candidate = nil
        candidateStateSequence = 0
        candidateLayoutEpoch = 0
        try Self.requireCardinality(bridge: bridge, candidateCount: 0)
        let metadata = try bridge.activeMetadata(
          stream: candidate.stream,
          minimumStateSequence: appliedActiveStateSequence
        )
        lastMetadataEpoch = metadata?.epoch
        pendingPresentation = PendingPresentation(
          transitionGeneration: pendingCommit.presentationGeneration,
          terminalID: candidate.stream.terminalID,
          inputAuthority: pendingCommit.inputAuthority,
          minimumStateSequence: pendingCommit.attachedReadyStateSequence,
          frameGeneration: nil,
          metadata: metadata
        )
        presentationQuiesced = false
        try bridge.forceFullFrame()
        requestFrame()
        let buffered = pendingLiveEvents
      pendingLiveEvents.removeAll(keepingCapacity: true)
      pendingPointerSettlements.removeAll(keepingCapacity: true)
        for event in buffered { try applyActive(event) }
        pendingCommit.completion(.success(()))
      } catch {
        pendingLiveEvents.removeAll(keepingCapacity: true)
        pendingCommit.completion(.failure(error))
      }
    }

    private func publishOrStageMetadata(
      _ metadata: GhosttyRenderMetadata,
      stream: GhosttyRenderStream,
      stateSequence: UInt64
    ) {
      if var pending = pendingPresentation, pending.terminalID == stream.terminalID {
        pending.metadata = metadata
        pendingPresentation = pending
        return
      }
      guard firstPresentedInputAuthority?.terminalID == stream.terminalID else { return }
      onMetadata?(stream.terminalID, stateSequence, metadata)
    }

    private static func manifest(
      _ value: BrokerRecoveryManifest
    ) throws -> GhosttyRenderRecoveryManifest {
      guard value.compression == "none",
        let terminalABI = UInt32(exactly: value.terminalABIVersion),
        let snapshotFormat = UInt32(exactly: value.snapshotFormatVersion)
      else {
        throw TerminalSurfaceCoordinatorError.invalidManifest
      }
      return GhosttyRenderRecoveryManifest(
        terminalEngineABIVersion: terminalABI,
        snapshotFormatVersion: snapshotFormat,
        ghosttySourceCommit: value.engineSourceCommit,
        snapshotMagic: value.snapshotMagic,
        unicodeWidthPolicy: value.unicodeWidthPolicy,
        graphicsPolicy: value.graphicsPolicy
      )
    }

    private static func grid(columns: Int, rows: Int) throws -> (columns: UInt16, rows: UInt16) {
      guard let columns = UInt16(exactly: columns),
        let rows = UInt16(exactly: rows),
        columns > 0, rows > 0,
        Int(columns) * Int(rows) <= OuroTerminalScene.maximumCells
      else {
        throw TerminalSurfaceCoordinatorError.invalidDimensions
      }
      return (columns, rows)
    }

    private static func requireCardinality(
      bridge: GhosttyRenderBridge,
      candidateCount: Int
    ) throws {
      let memory = try bridge.memoryInfo()
      guard memory.activeTerminalCount == 1,
        memory.candidateTerminalCount == candidateCount,
        memory.projectionCount == 1
      else {
        throw TerminalSurfaceCoordinatorError.invalidCardinality
      }
    }

    private static var debugShaderSourceURL: URL? {
      #if OUROCODE_METAL_RUNTIME_SOURCE
        return
          Bundle.main.url(forResource: "OuroTerminalShaders", withExtension: "metal")
          ?? OurocodeResourceBundle.shared.url(
            forResource: "OuroTerminalShaders",
            withExtension: "metal"
          )
      #else
        return nil
      #endif
    }
  }
#endif
