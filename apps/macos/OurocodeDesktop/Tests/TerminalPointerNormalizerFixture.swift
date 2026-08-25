#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import Foundation

  private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
      FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
      exit(1)
    }
  }

  @main
  enum TerminalPointerNormalizerFixture {
    static func main() {
      func cuaPixelScroll(_ wheel: Int32) -> OuroTerminalMouseEvent {
        guard let event = CGEvent(
          scrollWheelEvent2Source: nil,
          units: .pixel,
          wheelCount: 1,
          wheel1: wheel,
          wheel2: 0,
          wheel3: 0
        ), let appKitEvent = NSEvent(cgEvent: event) else {
          fatalError("Could not construct the CUA pixel-scroll event")
        }
        return OuroTerminalMouseEvent(
          kind: .scroll,
          event: appKitEvent,
          locationInView: CGPoint(x: 40, y: 40)
        )
      }

      let cuaDown = cuaPixelScroll(-4)
      require(cuaDown.deltaY == -4, "CUA -4 pixel delta changed at the AppKit boundary")
      require(cuaDown.hasPreciseScrollingDeltas, "CUA pixel scroll was not precise")
      require(cuaDown.phase.isEmpty && cuaDown.momentumPhase.isEmpty, "CUA pixel scroll gained a gesture phase")
      let cuaUp = cuaPixelScroll(4)
      require(cuaUp.deltaY == 4, "CUA +4 pixel delta changed at the AppKit boundary")

      let layout = TerminalPointerLayout(
        layoutEpoch: 7,
        screenSize: CGSize(width: 100, height: 80),
        cellSize: CGSize(width: 10, height: 20),
        contentInset: 10,
        columns: 8,
        rows: 3
      )!
      let geometry = layout.wireGeometry!
      require(geometry.screenWidthQ8 == 25_600, "screen width Q8 changed")
      require(geometry.cellHeightQ8 == 5_120, "cell height Q8 changed")
      require(geometry.paddingLeftQ8 == 2_560, "padding Q8 changed")

      let first = layout.sample(locationInView: CGPoint(x: -8, y: 90))!
      require(first.xQ8 == 0 && first.yQ8 == 0, "screen clamp changed")
      require(first.column == 0 && first.row == 0, "first cell mapping changed")

      let middle = layout.sample(locationInView: CGPoint(x: 35, y: 50))!
      require(middle.xQ8 == 8_960 && middle.yQ8 == 7_680, "point Q8 changed")
      require(middle.column == 2 && middle.row == 1, "top-left grid mapping changed")

      let last = layout.sample(locationInView: CGPoint(x: 120, y: -20))!
      require(last.column == 7 && last.row == 2, "last-cell clamp changed")
      require(last.surfaceX == 100 && last.surfaceY == 80, "surface clamp changed")

      require(TerminalPointerNormalizer.button(number: 0) == .left, "left button changed")
      require(TerminalPointerNormalizer.button(number: 10) == .eleven, "button 11 changed")
      require(TerminalPointerNormalizer.button(number: 11) == nil, "unknown button accepted")
      require(
        TerminalPointerNormalizer.dominantScrollDirection(deltaX: 1, deltaY: -4) == .down,
        "vertical scroll direction changed")
      require(
        TerminalPointerNormalizer.dominantScrollDirection(
          deltaX: cuaUp.deltaX, deltaY: cuaUp.deltaY
        ) == .up,
        "CUA +4 event did not map toward older scrollback")
      require(
        TerminalPointerNormalizer.dominantScrollDirection(deltaX: 5, deltaY: 1) == .left,
        "horizontal scroll direction changed")
      var accumulatorX: CGFloat = 0
      var accumulatorY: CGFloat = 0
      require(
        TerminalPointerNormalizer.scrollBoundary(
          precise: true, phase: [], momentumPhase: []
        ) == TerminalPointerNormalizer.ScrollBoundary(ending: true, cancelled: false),
        "standalone precise CGEvent was mistaken for an open trackpad gesture"
      )
      let partialDown = TerminalPointerNormalizer.scrollDirections(
        deltaX: 0,
        deltaY: -4,
        precise: true,
        cellSize: CGSize(width: 10, height: 20),
        ending: false,
        cancelled: false,
        accumulatorX: &accumulatorX,
        accumulatorY: &accumulatorY
      )
      require(partialDown.isEmpty, "partial precise gesture emitted before its boundary")
      let committedDown = TerminalPointerNormalizer.scrollDirections(
        deltaX: 0,
        deltaY: 0,
        precise: true,
        cellSize: CGSize(width: 10, height: 20),
        ending: true,
        cancelled: false,
        accumulatorX: &accumulatorX,
        accumulatorY: &accumulatorY
      )
      require(committedDown == [.down], "short scroll-down gesture was lost at phase end")
      require(accumulatorX == 0 && accumulatorY == 0, "ended gesture retained stale pixels")
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .down, total: 100, offset: 79, length: 20
        ) == .bottom,
        "final retained row did not enter explicit bottom state"
      )
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .down, total: 100, offset: 40, length: 20
        ) == .row(41),
        "ordinary retained scroll-down did not advance one row"
      )
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .up, total: 100, offset: 40, length: 20
        ) == .row(39),
        "ordinary retained scroll-up did not use an absolute older row"
      )
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .up, total: 100, offset: 80, length: 20
        ) == .row(79),
        "CUA scroll-up could not leave the explicit live-bottom row"
      )
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .down, total: 100, offset: 79, length: 20
        ) == .bottom,
        "CUA scroll-down could not restore explicit live-bottom state"
      )
      require(
        TerminalScrollProjectionPolicy.request(
          direction: .up, total: 100, offset: 0, length: 20
        ) == nil,
        "top-bound scroll emitted a meaningless viewport mutation"
      )
      print("PASS: pointer geometry and precise scroll/bottom projection normalization")
    }
  }
#endif
