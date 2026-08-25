#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit

  /// Value-only pointer data. AppKit raises Objective-C exceptions when
  /// scroll-only accessors are queried on ordinary mouse events (and vice
  /// versa), so event-kind validation belongs at this boundary.
  struct OuroTerminalMouseEvent {
    enum Kind { case down, drag, up, move, scroll }
    let kind: Kind
    let locationInView: CGPoint
    let buttonNumber: Int
    let deltaX: Double
    let deltaY: Double
    let hasPreciseScrollingDeltas: Bool
    let phase: NSEvent.Phase
    let momentumPhase: NSEvent.Phase
    let timestamp: TimeInterval
    let modifiers: NSEvent.ModifierFlags

    init(kind: Kind, event: NSEvent, locationInView: CGPoint) {
      let isScroll = kind == .scroll
      self.kind = kind
      self.locationInView = locationInView
      buttonNumber = isScroll ? 0 : Int(event.buttonNumber)
      deltaX = isScroll ? event.scrollingDeltaX : 0
      deltaY = isScroll ? event.scrollingDeltaY : 0
      hasPreciseScrollingDeltas = isScroll && event.hasPreciseScrollingDeltas
      phase = isScroll ? event.phase : []
      momentumPhase = isScroll ? event.momentumPhase : []
      timestamp = event.timestamp
      modifiers = event.modifierFlags
    }
  }
#endif
