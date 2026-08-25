#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import Metal
  import simd

  #if !OUROCODE_GHOSTTY_RENDERER
    #error("OUROCODE_GHOSTTY_METAL_SURFACE requires OUROCODE_GHOSTTY_RENDERER")
  #endif

  enum OuroTerminalSceneError: LocalizedError {
    case invalidGrid
    case memoryBudgetExceeded
    case bufferAllocationFailed
    case malformedFrame
    case invalidColorKind(UInt32)

    var errorDescription: String? {
      switch self {
      case .invalidGrid: return "The terminal scene grid is invalid."
      case .memoryBudgetExceeded: return "The terminal scene exceeds its bounded GPU allocation."
      case .bufferAllocationFailed:
        return "Metal could not allocate the bounded terminal scene buffer."
      case .malformedFrame: return "The terminal frame contains an invalid row or cell range."
      case .invalidColorKind(let kind):
        return "The terminal frame contains unknown color kind \(kind)."
      }
    }
  }

  struct OuroTerminalUniforms {
    var viewportCell: SIMD4<Float>
    var originGrid: SIMD4<Float>
    var cursor: SIMD4<UInt32>
    var semanticCanvas: SIMD4<Float>
    var semanticForeground: SIMD4<Float>
    var semanticTurnBackground: SIMD4<Float>
    var selection: SIMD4<Float>
    var cursorColor: SIMD4<Float>
  }

  struct OuroTerminalSceneUpdate {
    let buffer: MTLBuffer
    let instanceCount: Int
    let frameGeneration: UInt64
    let columns: Int
    let rows: Int
    let stateSequence: UInt64
    let cursor: GhosttyRenderCursor?
    let background: SIMD4<Float>
    let foreground: SIMD4<Float>
    let semanticTurnBackground: SIMD4<Float>
    let accessibility: OuroTerminalAccessibilitySnapshot
    let accessibilityProjection: OuroTerminalAccessibilityProjection
    let containsBlinkingCells: Bool
  }

  /// Retains exactly one presented grid. `prepare` creates at most one bounded
  /// candidate buffer so a failed presentation cannot corrupt the old scene.
  final class OuroTerminalScene {
    static let maximumCells = 131_072
    static let maximumBufferBytes = maximumCells * MemoryLayout<OuroTerminalCellInstance>.stride

    private let device: MTLDevice
    private(set) var activeBuffer: MTLBuffer?
    private(set) var instanceCount = 0
    private(set) var columns = 0
    private(set) var rows = 0
    private(set) var stateSequence: UInt64 = 0
    private(set) var cursor: GhosttyRenderCursor?
    private(set) var background = SIMD4<Float>(0, 0, 0, 1)
    private(set) var foreground = SIMD4<Float>(1, 1, 1, 1)
    private(set) var semanticTurnBackground = SIMD4<Float>(0, 0, 0, 1)
    private(set) var accessibility = OuroTerminalAccessibilitySnapshot.empty
    private(set) var accessibilityProjection = OuroTerminalAccessibilityProjection(rowCount: 0)
    private(set) var containsBlinkingCells = false

    init(device: MTLDevice) {
      self.device = device
    }

    var liveBufferBytes: Int {
      activeBuffer?.length ?? 0
    }

    func prepare(
      frame: GhosttyRenderFrame,
      atlas: OuroGlyphAtlas,
      font: NSFont,
      cellPixelSize: CGSize
    ) throws -> OuroTerminalSceneUpdate {
      let columnCount = Int(frame.columns)
      let rowCount = Int(frame.rows)
      let product = columnCount.multipliedReportingOverflow(by: rowCount)
      guard columnCount > 0, rowCount > 0, !product.overflow,
        product.partialValue <= Self.maximumCells
      else {
        throw OuroTerminalSceneError.invalidGrid
      }
      let bytes = product.partialValue.multipliedReportingOverflow(
        by: MemoryLayout<OuroTerminalCellInstance>.stride
      )
      guard !bytes.overflow, bytes.partialValue <= Self.maximumBufferBytes else {
        throw OuroTerminalSceneError.memoryBudgetExceeded
      }
      guard
        let candidate = device.makeBuffer(length: bytes.partialValue, options: .storageModeShared)
      else {
        throw OuroTerminalSceneError.bufferAllocationFailed
      }
      candidate.label = "Ourocode terminal candidate scene"

      let sameGrid = columns == columnCount && rows == rowCount
      let full = frame.dirty == .full || !sameGrid || activeBuffer == nil
      var nextAccessibilityProjection = full
        ? OuroTerminalAccessibilityProjection(rowCount: rowCount)
        : accessibilityProjection
      if !full, let activeBuffer {
        memcpy(candidate.contents(), activeBuffer.contents(), bytes.partialValue)
      }
      let pointer = candidate.contents().bindMemory(
        to: OuroTerminalCellInstance.self,
        capacity: product.partialValue
      )
      let defaultForeground = rgba(frame.foreground)
      let defaultBackground = rgba(frame.background)
      let semanticTurnBackground = OuroTerminalColorSemantics.semanticTurnBackground(
        red: frame.background.red,
        green: frame.background.green,
        blue: frame.background.blue,
        foregroundRed: frame.foreground.red,
        foregroundGreen: frame.foreground.green,
        foregroundBlue: frame.foreground.blue
      )
      let cellWidth = Int(cellPixelSize.width.rounded(.up))
      let cellHeight = Int(cellPixelSize.height.rounded(.up))
      guard cellWidth > 0, cellHeight > 0 else {
        throw OuroTerminalSceneError.invalidGrid
      }

      if full {
        for index in 0..<product.partialValue {
          pointer[index] = emptyCell(
            index: index,
            columns: columnCount,
            foreground: defaultForeground,
            background: defaultBackground
          )
        }
      }

      var hasBlink = false
      for cellIndex in 0..<frame.cellData.count {
        guard let cell = frame.cellData.cell(at: cellIndex) else {
          throw OuroTerminalSceneError.malformedFrame
        }
        hasBlink = hasBlink || cell.flags & (1 << 6) != 0
      }
      for rowIndex in 0..<frame.rowData.count {
        guard let row = frame.rowData.row(at: rowIndex), Int(row.y) < rowCount else {
          throw OuroTerminalSceneError.malformedFrame
        }
        guard full || row.dirty else { continue }
        let y = Int(row.y)
        let rowStart = y * columnCount
        for x in 0..<columnCount {
          pointer[rowStart + x] = emptyCell(
            x: x,
            y: y,
            foreground: defaultForeground,
            background: defaultBackground,
            semantic: row.semantic
          )
        }
        let cellEnd = row.firstCellIndex.addingReportingOverflow(row.cellCount)
        guard !cellEnd.overflow, row.firstCellIndex >= 0,
          cellEnd.partialValue <= frame.cellData.count
        else {
          throw OuroTerminalSceneError.malformedFrame
        }
        var accessibilityLine = ""
        var accessibilitySelected = ""
        var accessibilityHasSemanticInput = false
        for cellIndex in row.firstCellIndex..<cellEnd.partialValue {
          guard let cell = frame.cellData.cell(at: cellIndex), cell.width != 0,
            let text = frame.graphemes.string(in: cell.graphemeRange)
          else { continue }
          accessibilityLine.append(text)
          if cell.flags & 1 != 0 { accessibilitySelected.append(text) }
          if cell.semantic == 1 { accessibilityHasSemanticInput = true }
        }
        while accessibilityLine.last == " " { accessibilityLine.removeLast() }
        nextAccessibilityProjection.update(
          rowIndex: Int(row.y),
          semantic: row.semantic,
          line: accessibilityLine,
          selected: accessibilitySelected,
          hasSemanticInput: accessibilityHasSemanticInput
        )
        for cellIndex in row.firstCellIndex..<cellEnd.partialValue {
          guard let cell = frame.cellData.cell(at: cellIndex) else {
            throw OuroTerminalSceneError.malformedFrame
          }
          // Ghostty emits the trailing half of a wide grapheme as a distinct
          // zero-width spacer cell. The wide head already spans both columns
          // and marks this slot as skipped. Rebuilding the spacer as a normal
          // empty cell would paint its background over the glyph's right half
          // (Korean/CJK then looked like broken character fragments).
          if cell.width == 0 { continue }
          let x = Int(cell.x)
          let width = Int(cell.width)
          guard x < columnCount, width <= columnCount - x,
            let text = frame.graphemes.string(in: cell.graphemeRange)
          else {
            throw OuroTerminalSceneError.malformedFrame
          }
          var foreground = try resolve(
            cell.foreground,
            defaultColor: defaultForeground,
            palette: frame.palette
          )
          var cellBackground = try resolve(
            cell.background,
            defaultColor: defaultBackground,
            palette: frame.palette
          )
          var foregroundDefaultSource: UInt32? = cell.foreground.kind == 0 ? 0 : nil
          var backgroundDefaultSource: UInt32? = cell.background.kind == 0 ? 1 : nil
          if cell.flags & (1 << 7) != 0 {
            swap(&foreground, &cellBackground)
            swap(&foregroundDefaultSource, &backgroundDefaultSource)
          }
          let underlineColorBits = try packedColor(
            cell.underlineColor,
            palette: frame.palette
          )
          let tile = try atlas.resolve(
            text: text,
            baseFont: font,
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            columns: width,
            bold: cell.flags & (1 << 3) != 0,
            italic: cell.flags & (1 << 4) != 0
          )
          pointer[rowStart + x] = OuroTerminalCellInstance(
            cellRect: SIMD4(Float(x), Float(y), Float(width), 1),
            glyphUV: tile?.uv ?? .zero,
            foreground: foreground,
            background: cellBackground,
            terminalFlags: cell.flags,
            underlineStyle: cell.underline,
            surfaceFlags: (tile == nil ? 0 : 1)
              | (foregroundDefaultSource == 0 ? 1 << 2 : 0)
              | (backgroundDefaultSource == 1 ? 1 << 3 : 0)
              | (foregroundDefaultSource == 1
                ? OuroTerminalColorSemantics.foregroundUsesCanvasSurfaceFlag : 0)
              | (backgroundDefaultSource == 0
                ? OuroTerminalColorSemantics.backgroundUsesForegroundSurfaceFlag : 0)
              | (underlineColorBits == nil
                ? 0 : OuroTerminalColorSemantics.customUnderlineSurfaceFlag)
              | TerminalConversationPresentation.surfaceFlags(
                rowSemantic: row.semantic,
                cellSemantic: cell.semantic
              ),
            decorationColorBits: underlineColorBits ?? 0
          )
          if width > 1 {
            for tailX in (x + 1)..<(x + width) {
              pointer[rowStart + tailX].surfaceFlags = 1 << 1
            }
          }
        }
      }

      return OuroTerminalSceneUpdate(
        buffer: candidate,
        instanceCount: product.partialValue,
        frameGeneration: frame.generation,
        columns: columnCount,
        rows: rowCount,
        stateSequence: frame.stateSequence,
        cursor: frame.cursor,
        background: defaultBackground,
        foreground: defaultForeground,
        semanticTurnBackground: semanticTurnBackground,
        accessibility: nextAccessibilityProjection.snapshot(
          cursorLine: frame.cursor.map { Int($0.y) }
        ),
        accessibilityProjection: nextAccessibilityProjection,
        containsBlinkingCells: hasBlink
      )
    }

    func commit(_ update: OuroTerminalSceneUpdate) {
      activeBuffer = update.buffer
      activeBuffer?.label = "Ourocode terminal active scene"
      instanceCount = update.instanceCount
      columns = update.columns
      rows = update.rows
      stateSequence = update.stateSequence
      cursor = update.cursor
      background = update.background
      foreground = update.foreground
      semanticTurnBackground = update.semanticTurnBackground
      accessibility = update.accessibility
      accessibilityProjection = update.accessibilityProjection
      containsBlinkingCells = update.containsBlinkingCells
    }

    private func emptyCell(
      index: Int,
      columns: Int,
      foreground: SIMD4<Float>,
      background: SIMD4<Float>
    ) -> OuroTerminalCellInstance {
      emptyCell(
        x: index % columns,
        y: index / columns,
        foreground: foreground,
        background: background
      )
    }

    private func emptyCell(
      x: Int,
      y: Int,
      foreground: SIMD4<Float>,
      background: SIMD4<Float>,
      semantic: UInt32 = 0
    ) -> OuroTerminalCellInstance {
      OuroTerminalCellInstance(
        cellRect: SIMD4(Float(x), Float(y), 1, 1),
        glyphUV: .zero,
        foreground: foreground,
        background: background,
        terminalFlags: 0,
        underlineStyle: 0,
        surfaceFlags: (1 << 2) | (1 << 3)
          | TerminalConversationPresentation.surfaceFlags(
            rowSemantic: semantic,
            cellSemantic: 0
          ),
        decorationColorBits: 0
      )
    }

    private func resolve(
      _ color: GhosttyRenderColor,
      defaultColor: SIMD4<Float>,
      palette: GhosttyRenderPalette
    ) throws -> SIMD4<Float> {
      switch color.kind {
      case 0:
        return defaultColor
      case 1:
        guard let value = palette.color(at: Int(color.paletteIndex)) else {
          throw OuroTerminalSceneError.malformedFrame
        }
        return rgba(value)
      case 2:
        return rgba(color.rgb)
      default:
        throw OuroTerminalSceneError.invalidColorKind(color.kind)
      }
    }

    private func rgba(_ color: GhosttyRenderRGB) -> SIMD4<Float> {
      OuroTerminalColorSemantics.linearRGBA(
        red: color.red,
        green: color.green,
        blue: color.blue
      )
    }

    private func packedColor(
      _ color: GhosttyRenderColor,
      palette: GhosttyRenderPalette
    ) throws -> UInt32? {
      let value: GhosttyRenderRGB
      switch color.kind {
      case 0:
        return nil
      case 1:
        guard let paletteColor = palette.color(at: Int(color.paletteIndex)) else {
          throw OuroTerminalSceneError.malformedFrame
        }
        value = paletteColor
      case 2:
        value = color.rgb
      default:
        throw OuroTerminalSceneError.invalidColorKind(color.kind)
      }
      return OuroTerminalColorSemantics.packRGB(
        red: value.red,
        green: value.green,
        blue: value.blue
      )
    }
  }
#endif
