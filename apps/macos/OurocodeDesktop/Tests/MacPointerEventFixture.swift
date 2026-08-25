import AppKit
import CoreGraphics
import Foundation

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum MacPointerEventFixture {
  static func main() {
    guard let mouseDown = NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: CGPoint(x: 12, y: 24),
      modifierFlags: .shift,
      timestamp: 1,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ) else {
      fatalError("could not construct mouse fixture")
    }
    let click = OuroTerminalMouseEvent(
      kind: .down,
      event: mouseDown,
      locationInView: CGPoint(x: 3, y: 4)
    )
    require(click.buttonNumber == 0, "left mouse button identity changed")
    require(click.deltaX == 0 && click.deltaY == 0, "mouse click invented scroll deltas")
    require(click.phase.isEmpty && click.momentumPhase.isEmpty, "mouse click invented scroll phases")
    require(click.modifiers.contains(.shift), "mouse modifiers were lost")

    guard let scrollCGEvent = CGEvent(
      scrollWheelEvent2Source: nil,
      units: .pixel,
      wheelCount: 2,
      wheel1: 7,
      wheel2: -3,
      wheel3: 0
    ), let scrollEvent = NSEvent(cgEvent: scrollCGEvent) else {
      fatalError("could not construct scroll fixture")
    }
    let scroll = OuroTerminalMouseEvent(
      kind: .scroll,
      event: scrollEvent,
      locationInView: .zero
    )
    require(scroll.buttonNumber == 0, "scroll event invented a mouse button")
    require(scroll.deltaX != 0 || scroll.deltaY != 0, "scroll deltas were discarded")

    print("PASS: AppKit mouse and scroll fields remain event-kind safe")
  }
}
