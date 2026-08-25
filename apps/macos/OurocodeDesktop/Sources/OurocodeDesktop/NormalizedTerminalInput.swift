import CryptoKit
import Foundation

/// The modifier bit layout is part of `terminal.input.normalized.v1` and
/// matches the pinned Ghostty input ABI. Pointer input is deliberately absent
/// until the broker can return an atomic PTY/local-disposition receipt.
struct NormalizedTerminalModifiers: OptionSet, Equatable {
  let rawValue: UInt16

  static let shift = Self(rawValue: 1 << 0)
  static let control = Self(rawValue: 1 << 1)
  static let option = Self(rawValue: 1 << 2)
  static let command = Self(rawValue: 1 << 3)
  static let capsLock = Self(rawValue: 1 << 4)
  static let numericPad = Self(rawValue: 1 << 5)
  static let rightShift = Self(rawValue: 1 << 6)
  static let rightControl = Self(rawValue: 1 << 7)
  static let rightOption = Self(rawValue: 1 << 8)
  static let rightCommand = Self(rawValue: 1 << 9)

  static let all = Self(rawValue: 0x03ff)
}

enum NormalizedTerminalKeyAction: UInt8, Equatable {
  case release = 0
  case press = 1
  case `repeat` = 2

  fileprivate var wireName: String {
    switch self {
    case .release: return "release"
    case .press: return "press"
    case .repeat: return "repeat"
    }
  }
}

struct NormalizedTerminalKey: Equatable {
  let hidUsage: UInt32
  let action: NormalizedTerminalKeyAction
  let modifiers: NormalizedTerminalModifiers
  let consumedModifiers: NormalizedTerminalModifiers
  let composing: Bool
  let unshiftedCodepoint: UInt32
  let text: String
}

enum NormalizedTerminalMouseAction: UInt8, Equatable {
  case press = 0
  case release = 1
  case motion = 2
  case cancel = 3

  fileprivate var wireName: String {
    switch self {
    case .press: return "press"
    case .release: return "release"
    case .motion: return "motion"
    case .cancel: return "cancel"
    }
  }
}

enum NormalizedTerminalMouseButton: UInt8, Equatable {
  case none = 0
  case left = 1
  case right = 2
  case middle = 3
  case four = 4
  case five = 5
  case six = 6
  case seven = 7
  case eight = 8
  case nine = 9
  case ten = 10
  case eleven = 11

  fileprivate var wireName: String {
    switch self {
    case .none: return "none"
    case .left: return "left"
    case .right: return "right"
    case .middle: return "middle"
    case .four: return "four"
    case .five: return "five"
    case .six: return "six"
    case .seven: return "seven"
    case .eight: return "eight"
    case .nine: return "nine"
    case .ten: return "ten"
    case .eleven: return "eleven"
    }
  }
}

enum NormalizedTerminalScrollDirection: UInt8, Equatable {
  case up = 0
  case down = 1
  case left = 2
  case right = 3

  fileprivate var wireName: String {
    switch self {
    case .up: return "up"
    case .down: return "down"
    case .left: return "left"
    case .right: return "right"
    }
  }
}

struct NormalizedTerminalMouseGeometry: Equatable {
  let screenWidthQ8: UInt32
  let screenHeightQ8: UInt32
  let cellWidthQ8: UInt32
  let cellHeightQ8: UInt32
  let paddingTopQ8: UInt32
  let paddingBottomQ8: UInt32
  let paddingRightQ8: UInt32
  let paddingLeftQ8: UInt32
}

/// Immutable, AppKit-normalized events accepted by the v1 broker contract.
/// IME preedit is intentionally not representable; only committed text is.
enum NormalizedTerminalInputEvent: Equatable {
  case key(NormalizedTerminalKey)
  case committedText(String)
  case mouseGeometry(layoutEpoch: UInt64, NormalizedTerminalMouseGeometry)
  case mouse(
    gestureID: UInt64,
    layoutEpoch: UInt64,
    action: NormalizedTerminalMouseAction,
    button: NormalizedTerminalMouseButton,
    modifiers: NormalizedTerminalModifiers,
    xQ8: Int32,
    yQ8: Int32
  )
  case scroll(
    gestureID: UInt64,
    layoutEpoch: UInt64,
    direction: NormalizedTerminalScrollDirection,
    modifiers: NormalizedTerminalModifiers,
    xQ8: Int32,
    yQ8: Int32
  )
  case paste(String)
  case focus(Bool)
}

enum NormalizedPointerDisposition: String, Equatable {
  case pty
  case localSelection = "local_selection"
  case localScrollback = "local_scrollback"
}

struct NormalizedTerminalInputReceipt: Equatable {
  let terminalID: String
  let inputEpoch: UInt64
  let inputSequence: UInt64
  let eventDigest: String
  let leaseID: String
  let observedStateSequence: UInt64
  let layoutEpoch: UInt64
  let pointerDisposition: NormalizedPointerDisposition?
}

extension NormalizedTerminalInputEvent {
  static let maximumKeyTextBytes = 4_096
  static let maximumPasteBytes = 65_536 - 12

  typealias WireObject = [String: Any]

  var requiresPointerDisposition: Bool {
    switch self {
    case .mouse, .scroll: return true
    case .key, .committedText, .mouseGeometry, .paste, .focus: return false
    }
  }

  var isPointerEvent: Bool {
    switch self {
    case .mouseGeometry, .mouse, .scroll: return true
    case .key, .committedText, .paste, .focus: return false
    }
  }

  var pointerLayoutEpoch: UInt64? {
    switch self {
    case .mouseGeometry(let layoutEpoch, _): return layoutEpoch
    case .mouse(_, let layoutEpoch, _, _, _, _, _): return layoutEpoch
    case .scroll(_, let layoutEpoch, _, _, _, _): return layoutEpoch
    case .key, .committedText, .paste, .focus: return nil
    }
  }

  func validatedWireObject() throws -> WireObject {
    switch self {
    case .key(let key):
      let text = Data(key.text.utf8)
      guard key.modifiers.isSubset(of: .all),
        key.consumedModifiers.isSubset(of: key.modifiers),
        Self.isValidScalarOrZero(key.unshiftedCodepoint),
        text.count <= Self.maximumKeyTextBytes,
        Self.containsNoTerminalControlScalars(key.text)
      else {
        throw BrokerClientError.invalidRequest("Normalized key input violates the v1 key contract.")
      }
      return [
        "kind": "key",
        "hid_usage": key.hidUsage,
        "action": key.action.wireName,
        "modifiers": key.modifiers.rawValue,
        "consumed_modifiers": key.consumedModifiers.rawValue,
        "composing": key.composing,
        "unshifted_codepoint": key.unshiftedCodepoint,
        "utf8": text.base64EncodedString(),
      ]
    case .committedText(let value):
      let text = Data(value.utf8)
      guard text.count <= Self.maximumKeyTextBytes,
        Self.containsNoTerminalControlScalars(value)
      else {
        throw BrokerClientError.invalidRequest(
          "Committed terminal text violates the 4096-byte v1 contract.")
      }
      return ["kind": "committed_text", "utf8": text.base64EncodedString()]
    case .mouseGeometry(let layoutEpoch, let geometry):
      guard geometry.screenWidthQ8 > 0, geometry.screenHeightQ8 > 0,
        geometry.cellWidthQ8 > 0, geometry.cellHeightQ8 > 0
      else {
        throw BrokerClientError.invalidRequest("Normalized pointer geometry must be non-zero.")
      }
      return [
        "kind": "mouse_geometry",
        "layout_epoch": layoutEpoch,
        "geometry": [
          "screen_width_q8": geometry.screenWidthQ8,
          "screen_height_q8": geometry.screenHeightQ8,
          "cell_width_q8": geometry.cellWidthQ8,
          "cell_height_q8": geometry.cellHeightQ8,
          "padding_top_q8": geometry.paddingTopQ8,
          "padding_bottom_q8": geometry.paddingBottomQ8,
          "padding_right_q8": geometry.paddingRightQ8,
          "padding_left_q8": geometry.paddingLeftQ8,
        ],
      ]
    case .mouse(
      let gestureID, let layoutEpoch, let action, let button, let modifiers, let xQ8, let yQ8
    ):
      guard gestureID > 0, xQ8 >= 0, yQ8 >= 0, modifiers.isSubset(of: .all),
        action == .motion || button != .none
      else {
        throw BrokerClientError.invalidRequest("Normalized pointer event violates its v1 contract.")
      }
      return [
        "kind": "mouse",
        "gesture_id": gestureID,
        "layout_epoch": layoutEpoch,
        "action": action.wireName,
        "button": button.wireName,
        "modifiers": modifiers.rawValue,
        "x_q8": xQ8,
        "y_q8": yQ8,
      ]
    case .scroll(
      let gestureID, let layoutEpoch, let direction, let modifiers, let xQ8, let yQ8
    ):
      guard gestureID > 0, xQ8 >= 0, yQ8 >= 0, modifiers.isSubset(of: .all) else {
        throw BrokerClientError.invalidRequest("Normalized scroll event violates its v1 contract.")
      }
      return [
        "kind": "scroll",
        "gesture_id": gestureID,
        "layout_epoch": layoutEpoch,
        "direction": direction.wireName,
        "modifiers": modifiers.rawValue,
        "x_q8": xQ8,
        "y_q8": yQ8,
      ]
    case .paste(let value):
      // Materialize one value-owned copy before hashing and encoding.
      // The source clipboard/string cannot be mutated by the encoder.
      let text = Data(value.utf8)
      guard text.count <= Self.maximumPasteBytes else {
        throw BrokerClientError.invalidRequest("Terminal paste exceeds the 65524-byte v1 contract.")
      }
      return ["kind": "paste", "utf8": text.base64EncodedString()]
    case .focus(let focused):
      return ["kind": "focus", "focused": focused]
    }
  }

  func digestV1() throws -> String {
    // Validation is shared with wire encoding so an invalid event never
    // acquires a digest that could later be sent by mistake.
    _ = try validatedWireObject()
    var preimage = Data("ourocode-terminal-input-normalized-v1\0".utf8)
    switch self {
    case .key(let key):
      preimage.append(0)
      Self.appendBigEndian(key.hidUsage, to: &preimage)
      preimage.append(key.action.rawValue)
      Self.appendBigEndian(key.modifiers.rawValue, to: &preimage)
      Self.appendBigEndian(key.consumedModifiers.rawValue, to: &preimage)
      preimage.append(key.composing ? 1 : 0)
      Self.appendBigEndian(key.unshiftedCodepoint, to: &preimage)
      Self.appendLengthPrefixed(Data(key.text.utf8), to: &preimage)
    case .committedText(let value):
      preimage.append(1)
      Self.appendLengthPrefixed(Data(value.utf8), to: &preimage)
    case .mouseGeometry(let layoutEpoch, let geometry):
      preimage.append(2)
      Self.appendBigEndian(layoutEpoch, to: &preimage)
      for value in [
        geometry.screenWidthQ8,
        geometry.screenHeightQ8,
        geometry.cellWidthQ8,
        geometry.cellHeightQ8,
        geometry.paddingTopQ8,
        geometry.paddingBottomQ8,
        geometry.paddingRightQ8,
        geometry.paddingLeftQ8,
      ] {
        Self.appendBigEndian(value, to: &preimage)
      }
    case .mouse(
      let gestureID, let layoutEpoch, let action, let button, let modifiers, let xQ8, let yQ8
    ):
      preimage.append(3)
      Self.appendBigEndian(gestureID, to: &preimage)
      Self.appendBigEndian(layoutEpoch, to: &preimage)
      preimage.append(action.rawValue)
      preimage.append(button.rawValue)
      Self.appendBigEndian(modifiers.rawValue, to: &preimage)
      Self.appendBigEndian(xQ8, to: &preimage)
      Self.appendBigEndian(yQ8, to: &preimage)
    case .scroll(
      let gestureID, let layoutEpoch, let direction, let modifiers, let xQ8, let yQ8
    ):
      preimage.append(4)
      Self.appendBigEndian(gestureID, to: &preimage)
      Self.appendBigEndian(layoutEpoch, to: &preimage)
      preimage.append(direction.rawValue)
      Self.appendBigEndian(modifiers.rawValue, to: &preimage)
      Self.appendBigEndian(xQ8, to: &preimage)
      Self.appendBigEndian(yQ8, to: &preimage)
    case .paste(let value):
      preimage.append(5)
      Self.appendLengthPrefixed(Data(value.utf8), to: &preimage)
    case .focus(let focused):
      preimage.append(6)
      preimage.append(focused ? 1 : 0)
    }
    return "sha256:" + SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
  }

  private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
    var encoded = value.bigEndian
    withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
  }

  private static func appendLengthPrefixed(_ value: Data, to data: inout Data) {
    appendBigEndian(UInt64(value.count), to: &data)
    data.append(value)
  }

  private static func isValidScalarOrZero(_ value: UInt32) -> Bool {
    value == 0 || (value <= 0x10ffff && !(0xd800...0xdfff).contains(value))
  }

  private static func containsNoTerminalControlScalars(_ value: String) -> Bool {
    value.unicodeScalars.allSatisfy { scalar in
      let codepoint = scalar.value
      return codepoint > 0x1f
        && codepoint != 0x7f
        && !(0xf700...0xf8ff).contains(codepoint)
    }
  }
}
