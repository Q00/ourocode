#if OUROCODE_GHOSTTY_METAL_SURFACE
  enum TerminalScrollProjectionRequest: Equatable {
    case row(UInt64)
    case bottom
  }

  enum TerminalScrollProjectionPolicy {
    static func request(
      direction: NormalizedTerminalScrollDirection,
      total: UInt64,
      offset: UInt64,
      length: UInt64
    ) -> TerminalScrollProjectionRequest? {
      guard length <= total, offset <= total - length else { return nil }
      switch direction {
      case .up:
        guard offset > 0 else { return nil }
        // Use the absolute top-origin row contract. This removes any platform
        // ambiguity about the sign of AppKit's scrolling delta.
        return .row(offset - 1)
      case .down:
        let maxOffset = total - length
        // Enter Ghostty's explicit bottom state for the final retained row.
        // This keeps subsequent output attached to the live viewport instead
        // of leaving an indistinguishable one-row scrollback projection.
        return maxOffset - offset <= 1 ? .bottom : .row(offset + 1)
      case .left, .right:
        return nil
      }
    }
  }
#endif
