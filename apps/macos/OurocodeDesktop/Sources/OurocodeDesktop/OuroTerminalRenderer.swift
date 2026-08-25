#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import MetalKit

  enum OuroTerminalRendererError: LocalizedError {
    case commandBufferUnavailable
    case drawableUnavailable
    case encoderUnavailable
    case gpuFailure(String)

    var errorDescription: String? {
      switch self {
      case .commandBufferUnavailable: return "Metal could not create a terminal command buffer."
      case .drawableUnavailable: return "The terminal drawable is temporarily unavailable."
      case .encoderUnavailable: return "Metal could not create the terminal render encoder."
      case .gpuFailure(let message): return "The terminal frame was not presented: \(message)"
      }
    }
  }

  /// Damage-driven renderer with an exact one-command-buffer-in-flight gate.
  /// The old retained scene is committed only after the candidate presentation
  /// completes, so a drawable or GPU failure leaves the visible model intact.
  final class OuroTerminalRenderer: NSObject, MTKViewDelegate {
    var onNeedsFrame: (() -> Void)?
    var onNeedsFullFrame: (() -> Void)?
    var onFramePrepared: (() -> Void)?
    var onLeaseSettled: ((GhosttyRenderLeaseDisposition) -> Void)?
    var onFirstPresented: ((UInt64, UInt64, OuroTerminalAccessibilitySnapshot) -> Void)?
    var onError: ((Error) -> Void)?

    let scene: OuroTerminalScene
    private(set) var atlas: OuroGlyphAtlas

    private struct Pending {
      let update: OuroTerminalSceneUpdate
      let lease: GhosttyRenderFrameLease
      let cellPixelSize: CGSize
      let typography: TypographyIdentity
      let atlas: OuroGlyphAtlas
      let rotatesAtlas: Bool
    }

    private struct TypographyIdentity: Equatable {
      let fontName: String
      let pointSize: CGFloat
      let cellPixelSize: CGSize
    }

    private let device: MTLDevice
    private let metalLibrary: OuroTerminalMetalLibrary
    private let commandQueue: MTLCommandQueue
    private let sampler: MTLSamplerState
    private let stateLock = NSLock()
    private let renderQueue = DispatchQueue(label: "com.ourolabs.ourocode.terminal-render")
    private weak var view: MTKView?
    private var pending: Pending?
    /// Reserves scene/atlas mutation before work leaves the lock. Without this
    /// gate a retained redraw could begin while `prepare` is replacing atlas
    /// texels on the render queue.
    private var preparing = false
    private var inFlight = false
    private var invalidatedFrameGeneration: UInt64?
    private var presentingFrameGeneration: UInt64?
    private var retainedRedrawRequested = false
    private var currentCellPixelSize = CGSize(width: 1, height: 1)
    private var currentTypography: TypographyIdentity?
    /// Atlas saturation is recovered by asking the engine for one full frame
    /// and preparing it into a fresh generation. Partial damage cannot safely
    /// switch textures because untouched cells still reference the old atlas.
    private var atlasRotationRequested = false
    private var appearance: OuroTerminalAppearance
    private var blinkVisible = true
    private var terminalFocused = false
    private var blinkTimer: DispatchSourceTimer?

    init(
      resources: OuroTerminalMetalResources,
      appearance: OuroTerminalAppearance = .current()
    ) throws {
      metalLibrary = resources.library
      commandQueue = resources.commandQueue
      sampler = resources.sampler
      device = resources.device
      scene = OuroTerminalScene(device: resources.device)
      atlas = try OuroGlyphAtlas(device: resources.device)
      self.appearance = appearance
      super.init()
    }

    deinit {
      blinkTimer?.cancel()
      if let pending {
        try? pending.lease.finish(.retry)
      }
    }

    var hasCommandBufferInFlight: Bool {
      stateLock.withLock { inFlight }
    }

    func attach(to view: MTKView) {
      self.view = view
      view.delegate = self
    }

    func submit(
      _ lease: GhosttyRenderFrameLease,
      font: NSFont,
      cellPixelSize: CGSize
    ) {
      renderQueue.async { [weak self] in
        guard let self else {
          try? lease.finish(.retry)
          return
        }
        let canPrepare = self.stateLock.withLock { () -> Bool in
          guard !self.preparing, !self.inFlight, self.pending == nil else { return false }
          self.preparing = true
          return true
        }
        guard canPrepare else {
          try? lease.finish(.retry)
          self.dispatchMain {
            self.onLeaseSettled?(.retry)
            self.onNeedsFrame?()
          }
          return
        }
        do {
          let typography = TypographyIdentity(
            fontName: font.fontName,
            pointSize: font.pointSize,
            cellPixelSize: cellPixelSize
          )
          // A typography transaction gets a fresh bounded atlas. The old
          // retained scene keeps its texture until the candidate drawable is
          // committed, so a GPU failure can still fall back atomically without
          // accumulating every prior font size in one texture.
          let rotatesAtlas = self.atlasRotationRequested && lease.frame.dirty == .full
          if self.atlasRotationRequested && !rotatesAtlas {
            self.stateLock.withLock { self.preparing = false }
            try? lease.finish(.retry)
            self.dispatchMain {
              self.onLeaseSettled?(.retry)
              self.onNeedsFullFrame?()
            }
            return
          }
          let candidateAtlas = self.currentTypography == typography && !rotatesAtlas
            ? self.atlas
            : try OuroGlyphAtlas(device: self.device)
          let update = try self.scene.prepare(
            frame: lease.frame,
            atlas: candidateAtlas,
            font: font,
            cellPixelSize: cellPixelSize
          )
          candidateAtlas.flushPendingUpload()
          self.stateLock.withLock {
            self.preparing = false
            self.pending = Pending(
              update: update,
              lease: lease,
              cellPixelSize: cellPixelSize,
              typography: typography,
              atlas: candidateAtlas,
              rotatesAtlas: rotatesAtlas
            )
          }
          self.dispatchMain { [weak self] in
            guard let self else { return }
            self.view?.needsDisplay = true
            self.onFramePrepared?()
          }
        } catch {
          let recoverableSaturation: Bool
          switch error {
          case OuroGlyphAtlasError.metadataBudgetExceeded,
            OuroGlyphAtlasError.textureFull:
            recoverableSaturation = !self.atlasRotationRequested
              && self.currentTypography?.fontName == font.fontName
              && self.currentTypography?.pointSize == font.pointSize
              && self.currentTypography?.cellPixelSize == cellPixelSize
          default:
            recoverableSaturation = false
          }
          if recoverableSaturation { self.atlasRotationRequested = true }
          self.stateLock.withLock { self.preparing = false }
          try? lease.finish(.retry)
          self.dispatchMain {
            self.onLeaseSettled?(.retry)
            if recoverableSaturation {
              self.onNeedsFullFrame?()
            } else {
              self.onError?(error)
            }
          }
        }
      }
    }

    func requestRetainedRedraw() {
      let shouldSchedule = stateLock.withLock { () -> Bool in
        retainedRedrawRequested = true
        return !preparing && !inFlight
      }
      if shouldSchedule {
        dispatchMain { [weak self] in self?.view?.needsDisplay = true }
      }
    }

    func updateFocus(_ focused: Bool) {
      let changed = stateLock.withLock { () -> Bool in
        guard terminalFocused != focused else { return false }
        terminalFocused = focused
        return true
      }
      if changed { requestRetainedRedraw() }
    }

    /// Revokes a not-yet-authorized candidate drawable. Rendering may already
    /// be executing, but the drawable is not presented until the first command
    /// buffer completes and this generation passes the cutover check.
    func invalidatePresentation(frameGeneration: UInt64) -> Bool {
      stateLock.withLock {
        guard presentingFrameGeneration != frameGeneration else { return false }
        invalidatedFrameGeneration = frameGeneration
        return true
      }
    }

    func updateAppearance(_ next: OuroTerminalAppearance) {
      renderQueue.async { [weak self] in
        guard let self else { return }
        let changed = self.stateLock.withLock { () -> Bool in
          guard self.appearance != next else { return false }
          self.appearance = next
          return true
        }
        guard changed else { return }
        self.configureBlinkTimer()
        self.requestRetainedRedraw()
      }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
      requestRetainedRedraw()
    }

    func draw(in view: MTKView) {
      let work = stateLock.withLock {
        () -> (
          pending: Pending?, buffer: MTLBuffer, count: Int, cellSize: CGSize,
          appearance: OuroTerminalAppearance, blinkVisible: Bool, focused: Bool,
          defaultBackground: SIMD4<Float>, defaultForeground: SIMD4<Float>,
          semanticTurnBackground: SIMD4<Float>
        )? in
        guard !preparing, !inFlight else { return nil }
        if let pending {
          self.pending = nil
          inFlight = true
          retainedRedrawRequested = false
          return (
            pending, pending.update.buffer, pending.update.instanceCount, pending.cellPixelSize,
            appearance, blinkVisible, terminalFocused,
            pending.update.background, pending.update.foreground,
            pending.update.semanticTurnBackground
          )
        }
        guard retainedRedrawRequested, let buffer = scene.activeBuffer, scene.instanceCount > 0
        else {
          return nil
        }
        inFlight = true
        retainedRedrawRequested = false
        return (
          nil, buffer, scene.instanceCount, currentCellPixelSize, appearance, blinkVisible,
          terminalFocused, scene.background, scene.foreground,
          scene.semanticTurnBackground
        )
      }
      guard let work else { return }
      guard let drawable = view.currentDrawable else {
        failBeforeCommit(work.pending, error: OuroTerminalRendererError.drawableUnavailable)
        return
      }
      guard let commandBuffer = commandQueue.makeCommandBuffer() else {
        failBeforeCommit(work.pending, error: OuroTerminalRendererError.commandBufferUnavailable)
        return
      }
      let pass = MTLRenderPassDescriptor()
      pass.colorAttachments[0].texture = drawable.texture
      pass.colorAttachments[0].loadAction = .clear
      pass.colorAttachments[0].storeAction = .store
      let background = work.defaultBackground
      pass.colorAttachments[0].clearColor = MTLClearColor(
        red: Double(background.x),
        green: Double(background.y),
        blue: Double(background.z),
        alpha: Double(background.w)
      )
      guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
        failBeforeCommit(work.pending, error: OuroTerminalRendererError.encoderUnavailable)
        return
      }
      let cursor = work.pending?.update.cursor ?? scene.cursor
      var uniforms = makeUniforms(
        view: view,
        cellSize: work.cellSize,
        cursor: cursor,
        appearance: work.appearance,
        blinkVisible: work.blinkVisible,
        focused: work.focused,
        defaultBackground: work.defaultBackground,
        defaultForeground: work.defaultForeground,
        semanticTurnBackground: work.semanticTurnBackground
      )
      encoder.label = "Ourocode terminal retained redraw"
      encoder.setRenderPipelineState(metalLibrary.cellPipeline)
      encoder.setVertexBuffer(work.buffer, offset: 0, index: 0)
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<OuroTerminalUniforms>.stride, index: 1)
      encoder.setFragmentBytes(
        &uniforms, length: MemoryLayout<OuroTerminalUniforms>.stride, index: 1)
      encoder.setFragmentTexture(work.pending?.atlas.texture ?? atlas.texture, index: 0)
      encoder.setFragmentSamplerState(sampler, index: 0)
      encoder.drawPrimitives(
        type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: work.count)
      encoder.endEncoding()
      commandBuffer.label = "Ourocode terminal frame"
      commandBuffer.addCompletedHandler { [weak self] completed in
        self?.renderQueue.async { [weak self] in
          self?.finishRendering(
            work.pending,
            drawable: drawable,
            commandBuffer: completed
          )
        }
      }
      commandBuffer.commit()
    }

    func cursorScreenRect(in view: NSView) -> NSRect {
      let cursor = stateLock.withLock { scene.cursor }
      guard let cursor, let window = view.window else { return .zero }
      let scale = window.backingScaleFactor
      let inset = OuroTheme.terminalContentInset
      let cellSizeInPoints = CGSize(
        width: currentCellPixelSize.width / scale,
        height: currentCellPixelSize.height / scale
      )
      let local = NSRect(
        x: inset + CGFloat(cursor.x) * cellSizeInPoints.width,
        y: view.bounds.height - inset - CGFloat(cursor.y + 1) * cellSizeInPoints.height,
        width: cellSizeInPoints.width,
        height: cellSizeInPoints.height
      )
      return window.convertToScreen(view.convert(local, to: nil))
    }

    private func makeUniforms(
      view: MTKView,
      cellSize: CGSize,
      cursor: GhosttyRenderCursor?,
      appearance: OuroTerminalAppearance,
      blinkVisible: Bool,
      focused: Bool,
      defaultBackground: SIMD4<Float>,
      defaultForeground: SIMD4<Float>,
      semanticTurnBackground: SIMD4<Float>
    ) -> OuroTerminalUniforms {
      let cursorVisible =
        cursor.map {
          $0.visible && (!$0.blinking || appearance.reduceMotion || blinkVisible)
        } ?? false
      let backingScale = max(1, view.window?.backingScaleFactor ?? 1)
      let contentInsetPixels = OuroTheme.terminalContentInset * backingScale
      return OuroTerminalUniforms(
        viewportCell: SIMD4(
          Float(view.drawableSize.width),
          Float(view.drawableSize.height),
          Float(cellSize.width),
          Float(cellSize.height)
        ),
        originGrid: SIMD4(
          Float(contentInsetPixels), Float(contentInsetPixels),
          Float(scene.columns),
          Float((blinkVisible ? 1 : 0) | (appearance.increaseContrast ? 2 : 0))
        ),
        cursor: SIMD4(
          UInt32(cursor?.x ?? 0),
          UInt32(cursor?.y ?? 0),
          cursorVisible ? (focused ? 3 : 1) : 0,
          cursor?.style ?? 0
        ),
        semanticCanvas: defaultBackground,
        semanticForeground: defaultForeground,
        semanticTurnBackground: semanticTurnBackground,
        selection: appearance.selection,
        cursorColor: cursor?.color.map {
          OuroTerminalColorSemantics.linearRGBA(red: $0.red, green: $0.green, blue: $0.blue)
        } ?? appearance.cursor
      )
    }

    private func complete(_ pending: Pending?, commandBuffer: MTLCommandBuffer) {
      let succeeded = commandBuffer.status == .completed
      if succeeded, let pending {
        scene.commit(pending.update)
        currentCellPixelSize = pending.cellPixelSize
        currentTypography = pending.typography
        atlas = pending.atlas
        if pending.rotatesAtlas { atlasRotationRequested = false }
        try? pending.lease.finish(.consumed)
        configureBlinkTimer()
        dispatchMain {
          self.onLeaseSettled?(.consumed)
          self.onFirstPresented?(
            pending.update.frameGeneration,
            pending.update.stateSequence,
            pending.update.accessibility
          )
        }
      } else if let pending {
        try? pending.lease.finish(.retry)
        dispatchMain { self.onLeaseSettled?(.retry) }
      }
      let needsRedraw = stateLock.withLock { () -> Bool in
        if let pending,
          presentingFrameGeneration == pending.update.frameGeneration
        {
          presentingFrameGeneration = nil
        }
        inFlight = false
        return retainedRedrawRequested || self.pending != nil
      }
      if !succeeded {
        let message =
          commandBuffer.error?.localizedDescription
          ?? "Metal command buffer status \(commandBuffer.status.rawValue)"
        dispatchMain {
          self.onError?(OuroTerminalRendererError.gpuFailure(message))
          self.onNeedsFrame?()
        }
      }
      if needsRedraw {
        dispatchMain { [weak self] in self?.view?.needsDisplay = true }
      }
    }

    private func finishRendering(
      _ pending: Pending?,
      drawable: CAMetalDrawable,
      commandBuffer: MTLCommandBuffer
    ) {
      guard commandBuffer.status == .completed else {
        complete(pending, commandBuffer: commandBuffer)
        return
      }
      dispatchMain { [weak self] in
        guard let self else { return }
        self.renderQueue.async { [weak self] in
          guard let self else { return }
          if let pending,
            self.stateLock.withLock({
              self.invalidatedFrameGeneration == pending.update.frameGeneration
            })
          {
            self.discardBeforePresentation(pending)
            return
          }
          guard let presentation = self.commandQueue.makeCommandBuffer() else {
            self.failBeforeCommit(
              pending,
              error: OuroTerminalRendererError.commandBufferUnavailable
            )
            return
          }
          presentation.label = "Ourocode terminal presentation barrier"
          if let pending {
            self.stateLock.withLock {
              self.presentingFrameGeneration = pending.update.frameGeneration
            }
          }
          presentation.present(drawable)
          presentation.addCompletedHandler { [weak self] completed in
            self?.renderQueue.async { [weak self] in
              self?.complete(pending, commandBuffer: completed)
            }
          }
          presentation.commit()
        }
      }
    }

    private func discardBeforePresentation(_ pending: Pending) {
      stateLock.withLock {
        if invalidatedFrameGeneration == pending.update.frameGeneration {
          invalidatedFrameGeneration = nil
        }
        inFlight = false
      }
      try? pending.lease.finish(.consumed)
      dispatchMain { self.onLeaseSettled?(.consumed) }
    }

    private func failBeforeCommit(_ pending: Pending?, error: Error) {
      renderQueue.async { [weak self] in
        guard let self else { return }
        if let pending {
          try? pending.lease.finish(.retry)
          self.dispatchMain { self.onLeaseSettled?(.retry) }
        }
        self.stateLock.withLock {
          self.inFlight = false
          if pending == nil { self.retainedRedrawRequested = true }
        }
        self.dispatchMain {
          self.onError?(error)
          if pending != nil { self.onNeedsFrame?() }
        }
      }
    }

    private func configureBlinkTimer() {
      blinkTimer?.cancel()
      blinkTimer = nil
      let appearance = stateLock.withLock { () -> OuroTerminalAppearance in
        blinkVisible = true
        return self.appearance
      }
      guard !appearance.reduceMotion,
        scene.containsBlinkingCells || scene.cursor?.blinking == true
      else {
        return
      }
      let timer = DispatchSource.makeTimerSource(queue: renderQueue)
      timer.schedule(
        deadline: .now() + .milliseconds(500), repeating: .milliseconds(500),
        leeway: .milliseconds(30))
      timer.setEventHandler { [weak self] in
        guard let self else { return }
        self.stateLock.withLock { self.blinkVisible.toggle() }
        self.requestRetainedRedraw()
      }
      blinkTimer = timer
      timer.resume()
    }

    private func dispatchMain(_ body: @escaping () -> Void) {
      if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }
  }

  extension NSLock {
    fileprivate func withLock<T>(_ body: () throws -> T) rethrows -> T {
      lock()
      defer { unlock() }
      return try body()
    }
  }
#endif
