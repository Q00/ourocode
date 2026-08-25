#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit

  struct TerminalPointerSample: Equatable {
    let xQ8: Int32
    let yQ8: Int32
    let column: UInt16
    let row: UInt32
    let surfaceX: Double
    let surfaceY: Double
  }

  /// Immutable geometry shared by the broker encoder and the app-side
  /// projection. AppKit is bottom-left based; the terminal contract is
  /// top-left based, so conversion happens exactly once here.
  struct TerminalPointerLayout: Equatable {
    let layoutEpoch: UInt64
    let screenSize: CGSize
    let cellSize: CGSize
    let contentInset: CGFloat
    let columns: Int
    let rows: Int

    init?(
      layoutEpoch: UInt64,
      screenSize: CGSize,
      cellSize: CGSize,
      contentInset: CGFloat,
      columns: Int,
      rows: Int
    ) {
      guard layoutEpoch > 0,
        screenSize.width > 0, screenSize.height > 0,
        cellSize.width > 0, cellSize.height > 0,
        contentInset >= 0,
        columns > 0, columns <= Int(UInt16.max),
        rows > 0, rows <= Int(UInt32.max)
      else { return nil }
      self.layoutEpoch = layoutEpoch
      self.screenSize = screenSize
      self.cellSize = cellSize
      self.contentInset = contentInset
      self.columns = columns
      self.rows = rows
    }

    var wireGeometry: NormalizedTerminalMouseGeometry? {
      guard let screenWidth = Self.unsignedQ8(screenSize.width),
        let screenHeight = Self.unsignedQ8(screenSize.height),
        let cellWidth = Self.unsignedQ8(cellSize.width),
        let cellHeight = Self.unsignedQ8(cellSize.height),
        let padding = Self.unsignedQ8(contentInset)
      else { return nil }
      return NormalizedTerminalMouseGeometry(
        screenWidthQ8: screenWidth,
        screenHeightQ8: screenHeight,
        cellWidthQ8: cellWidth,
        cellHeightQ8: cellHeight,
        paddingTopQ8: padding,
        paddingBottomQ8: padding,
        paddingRightQ8: padding,
        paddingLeftQ8: padding
      )
    }

    func sample(locationInView point: CGPoint) -> TerminalPointerSample? {
      let surfaceX = min(max(0, point.x), screenSize.width)
      let surfaceY = min(max(0, screenSize.height - point.y), screenSize.height)
      return sample(surfaceX: surfaceX, surfaceY: surfaceY)
    }

    func sample(surfaceX rawX: CGFloat, surfaceY rawY: CGFloat) -> TerminalPointerSample? {
      let surfaceX = min(max(0, rawX), screenSize.width)
      let surfaceY = min(max(0, rawY), screenSize.height)
      guard let xQ8 = Self.signedQ8(surfaceX), let yQ8 = Self.signedQ8(surfaceY) else {
        return nil
      }
      let contentX = max(0, surfaceX - contentInset)
      let contentY = max(0, surfaceY - contentInset)
      let column = min(columns - 1, max(0, Int(floor(contentX / cellSize.width))))
      let row = min(rows - 1, max(0, Int(floor(contentY / cellSize.height))))
      return TerminalPointerSample(
        xQ8: xQ8,
        yQ8: yQ8,
        column: UInt16(column),
        row: UInt32(row),
        surfaceX: Double(surfaceX),
        surfaceY: Double(surfaceY)
      )
    }

    private static func unsignedQ8(_ value: CGFloat) -> UInt32? {
      guard value.isFinite, value > 0 else { return nil }
      let scaled = (Double(value) * 256).rounded()
      guard scaled > 0, scaled <= Double(UInt32.max) else { return nil }
      return UInt32(scaled)
    }

    private static func signedQ8(_ value: CGFloat) -> Int32? {
      guard value.isFinite, value >= 0 else { return nil }
      let scaled = (Double(value) * 256).rounded()
      guard scaled >= 0, scaled <= Double(Int32.max) else { return nil }
      return Int32(scaled)
    }
  }

  enum TerminalPointerNormalizer {
    struct ScrollBoundary: Equatable {
      let ending: Bool
      let cancelled: Bool
    }

    static func button(number: Int) -> NormalizedTerminalMouseButton? {
      switch number {
      case 0: return .left
      case 1: return .right
      case 2: return .middle
      case 3: return .four
      case 4: return .five
      case 5: return .six
      case 6: return .seven
      case 7: return .eight
      case 8: return .nine
      case 9: return .ten
      case 10: return .eleven
      default: return nil
      }
    }

    static func modifiers(_ flags: NSEvent.ModifierFlags) -> NormalizedTerminalModifiers {
      MacKeyboardNormalizer.normalizedModifiers(flags)
    }

    static func dominantScrollDirection(deltaX: CGFloat, deltaY: CGFloat)
      -> NormalizedTerminalScrollDirection?
    {
      guard deltaX.isFinite, deltaY.isFinite else { return nil }
      if abs(deltaY) >= abs(deltaX), deltaY != 0 {
        return deltaY > 0 ? .up : .down
      }
      if deltaX != 0 {
        return deltaX > 0 ? .left : .right
      }
      return nil
    }

    static func scrollBoundary(
      precise: Bool,
      phase: NSEvent.Phase,
      momentumPhase: NSEvent.Phase
    ) -> ScrollBoundary {
      let cancelled = phase.contains(.cancelled) || momentumPhase.contains(.cancelled)
      let explicitEnd = phase.contains(.ended) || momentumPhase.contains(.ended)
      // CGEvent/Computer Use pixel scrolls are precise but carry no phase.
      // They are independent wheel ticks, not an open-ended trackpad gesture.
      let standalonePrecise = precise && phase.isEmpty && momentumPhase.isEmpty
      return ScrollBoundary(
        ending: explicitEnd || standalonePrecise || cancelled,
        cancelled: cancelled
      )
    }

    /// Converts AppKit pixel scrolling into bounded terminal-row ticks. A
    /// short precise gesture may end before reaching one full cell; commit its
    /// residual direction at the gesture boundary instead of silently losing
    /// the user's scroll-down request.
    static func scrollDirections(
      deltaX: CGFloat,
      deltaY: CGFloat,
      precise: Bool,
      cellSize: CGSize,
      ending: Bool,
      cancelled: Bool,
      accumulatorX: inout CGFloat,
      accumulatorY: inout CGFloat
    ) -> [NormalizedTerminalScrollDirection] {
      guard deltaX.isFinite, deltaY.isFinite,
        cellSize.width.isFinite, cellSize.height.isFinite,
        cellSize.width > 0, cellSize.height > 0
      else { return [] }
      guard precise else {
        return dominantScrollDirection(deltaX: deltaX, deltaY: deltaY).map { [$0] } ?? []
      }

      accumulatorX = min(max(accumulatorX + deltaX, -cellSize.width * 64), cellSize.width * 64)
      accumulatorY = min(max(accumulatorY + deltaY, -cellSize.height * 64), cellSize.height * 64)
      let vertical = abs(accumulatorY) >= abs(accumulatorX)
      let threshold = max(1, vertical ? cellSize.height : cellSize.width)
      var accumulator = vertical ? accumulatorY : accumulatorX
      let ticks = min(8, Int(abs(accumulator) / threshold))
      var directions: [NormalizedTerminalScrollDirection] = []
      if ticks > 0,
        let direction = dominantScrollDirection(
          deltaX: vertical ? 0 : accumulator,
          deltaY: vertical ? accumulator : 0
        )
      {
        directions.append(contentsOf: repeatElement(direction, count: ticks))
        accumulator -= CGFloat(ticks) * threshold * (accumulator > 0 ? 1 : -1)
        if vertical { accumulatorY = accumulator } else { accumulatorX = accumulator }
      }

      if ending, !cancelled, directions.isEmpty {
        let residualX = accumulatorX
        let residualY = accumulatorY
        let residualThreshold = max(0.5, (abs(residualY) >= abs(residualX)
          ? cellSize.height : cellSize.width) * 0.05)
        if max(abs(residualX), abs(residualY)) >= residualThreshold,
          let direction = dominantScrollDirection(deltaX: residualX, deltaY: residualY)
        {
          directions.append(direction)
        }
      }
      if ending || cancelled {
        accumulatorX = 0
        accumulatorY = 0
      }
      return directions
    }
  }
#endif
