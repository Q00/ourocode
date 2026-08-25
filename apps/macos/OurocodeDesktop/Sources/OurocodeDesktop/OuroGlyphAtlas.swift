#if OUROCODE_GHOSTTY_METAL_SURFACE
  import AppKit
  import CoreText
  import Metal

  enum OuroGlyphAtlasError: LocalizedError {
    case invalidCellSize
    case allocationFailed
    case metadataBudgetExceeded
    case textureFull
    case rasterContextFailed

    var errorDescription: String? {
      switch self {
      case .invalidCellSize: return "The terminal glyph cell size is outside its checked bound."
      case .allocationFailed: return "The bounded terminal glyph scratch allocation failed."
      case .metadataBudgetExceeded: return "The terminal glyph metadata budget is exhausted."
      case .textureFull: return "The bounded terminal glyph atlas is full."
      case .rasterContextFailed: return "CoreText could not create a bounded glyph raster context."
      }
    }
  }

  /// A bounded, single-channel CoreText atlas. It never grows and never evicts
  /// while a retained scene may still reference an entry. Reset is an explicit
  /// renderer operation performed only with no command buffer in flight.
  final class OuroGlyphAtlas {
    struct Tile: Equatable {
      let uv: SIMD4<Float>
    }

    struct Budget {
      let width: Int
      let height: Int
      let metadataBytes: Int
      let maximumEntries: Int
      let maximumTileWidth: Int
      let maximumTileHeight: Int

      static let desktop = Budget(
        width: 2_048,
        height: 2_048,
        metadataBytes: 2 * 1_024 * 1_024,
        maximumEntries: 16_384,
        maximumTileWidth: 512,
        maximumTileHeight: 256
      )
    }

    private struct Key: Hashable {
      let text: String
      let fontName: String
      let pointSizeBits: UInt64
      let cellWidth: Int
      let cellHeight: Int
      let columns: Int
      let bold: Bool
      let italic: Bool
    }

    let texture: MTLTexture
    let budget: Budget
    private let scratch: UnsafeMutableRawPointer
    private let scratchBytes: Int
    /// One CPU-side image backs every glyph resolved for this atlas. We batch
    /// all tiles discovered while preparing a frame into one texture upload;
    /// calling `MTLTexture.replace` once per glyph made the driver retain a
    /// separate 4 MiB graphics region for each upload during font zoom.
    private let bitmap: UnsafeMutableRawPointer
    private let bitmapBytes: Int
    private var entries: [Key: Tile] = [:]
    private var metadataBytes = 0
    private var shelfX = 0
    private var shelfY = 0
    private var shelfHeight = 0
    private var pendingUploadBounds: MTLRegion?
    private(set) var pendingGlyphUploadCount = 0
    private(set) var textureUploadCount = 0
    /// Logical dirty bytes submitted through the one coalesced upload. These
    /// counters are deterministic and intentionally do not claim to measure
    /// opaque driver allocations; the structural driver bound is one call
    /// against one fixed-size texture per flush.
    private(set) var totalUploadRegionBytes = 0
    private(set) var peakUploadRegionBytes = 0

    init(device: MTLDevice, budget: Budget = .desktop) throws {
      guard budget.width > 0, budget.height > 0,
        budget.maximumTileWidth > 0, budget.maximumTileHeight > 0
      else {
        throw OuroGlyphAtlasError.invalidCellSize
      }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .r8Unorm,
        width: budget.width,
        height: budget.height,
        mipmapped: false
      )
      descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
      descriptor.usage = [.shaderRead]
      guard let texture = device.makeTexture(descriptor: descriptor) else {
        throw OuroGlyphAtlasError.allocationFailed
      }
      let size = budget.maximumTileWidth.multipliedReportingOverflow(
        by: budget.maximumTileHeight
      )
      guard !size.overflow, let scratch = calloc(size.partialValue, 1) else {
        throw OuroGlyphAtlasError.allocationFailed
      }
      let bitmapSize = budget.width.multipliedReportingOverflow(by: budget.height)
      guard !bitmapSize.overflow, let bitmap = calloc(bitmapSize.partialValue, 1) else {
        free(scratch)
        throw OuroGlyphAtlasError.allocationFailed
      }
      self.texture = texture
      self.texture.label = "Ourocode bounded CoreText glyph atlas"
      self.budget = budget
      self.scratch = scratch
      scratchBytes = size.partialValue
      self.bitmap = bitmap
      bitmapBytes = bitmapSize.partialValue
    }

    deinit {
      free(scratch)
      free(bitmap)
    }

    var textureBytes: Int { budget.width * budget.height }
    var cpuBackingBytes: Int { bitmapBytes }
    var scratchBackingBytes: Int { scratchBytes }
    var liveMetadataBytes: Int { metadataBytes }
    var entryCount: Int { entries.count }

    func reset() {
      entries.removeAll(keepingCapacity: true)
      metadataBytes = 0
      shelfX = 0
      shelfY = 0
      shelfHeight = 0
      pendingUploadBounds = nil
      pendingGlyphUploadCount = 0
      memset(bitmap, 0, bitmapBytes)
    }

    func resolve(
      text: String,
      baseFont: NSFont,
      cellWidth: Int,
      cellHeight: Int,
      columns: Int,
      bold: Bool,
      italic: Bool
    ) throws -> Tile? {
      guard !text.isEmpty, text != " " else { return nil }
      guard cellWidth > 0, cellHeight > 0, columns > 0 else {
        throw OuroGlyphAtlasError.invalidCellSize
      }
      let tileWidthResult = cellWidth.multipliedReportingOverflow(by: columns)
      guard !tileWidthResult.overflow,
        tileWidthResult.partialValue <= budget.maximumTileWidth,
        cellHeight <= budget.maximumTileHeight
      else {
        throw OuroGlyphAtlasError.invalidCellSize
      }
      let key = Key(
        text: text,
        fontName: baseFont.fontName,
        pointSizeBits: Double(baseFont.pointSize).bitPattern,
        cellWidth: cellWidth,
        cellHeight: cellHeight,
        columns: columns,
        bold: bold,
        italic: italic
      )
      if let cached = entries[key] { return cached }

      let estimatedMetadata =
        MemoryLayout<Key>.stride
        + MemoryLayout<Tile>.stride
        + text.utf8.count
        + baseFont.fontName.utf8.count
      guard entries.count < budget.maximumEntries,
        estimatedMetadata <= budget.metadataBytes - metadataBytes
      else {
        throw OuroGlyphAtlasError.metadataBudgetExceeded
      }

      let padding = 1
      let contentWidth = tileWidthResult.partialValue
      let contentHeight = cellHeight
      let allocationWidth = contentWidth + padding * 2
      let allocationHeight = contentHeight + padding * 2
      let origin = try allocate(width: allocationWidth, height: allocationHeight)
      try rasterize(
        text: text,
        baseFont: baseFont,
        bold: bold,
        italic: italic,
        width: contentWidth,
        height: contentHeight,
        columns: columns
      )
      let region = MTLRegionMake2D(
        origin.x + padding,
        origin.y + padding,
        contentWidth,
        contentHeight
      )
      copyScratchToBitmap(region: region)
      includePendingUpload(region)
      pendingGlyphUploadCount += 1
      let atlasWidth = Float(budget.width)
      let atlasHeight = Float(budget.height)
      let tile = Tile(
        uv: SIMD4(
          Float(region.origin.x) / atlasWidth,
          Float(region.origin.y) / atlasHeight,
          Float(region.origin.x + region.size.width) / atlasWidth,
          Float(region.origin.y + region.size.height) / atlasHeight
        ))
      entries[key] = tile
      metadataBytes += estimatedMetadata
      return tile
    }

    /// Upload every glyph discovered during one scene preparation with a
    /// single driver call. The dirty rectangle may contain untouched bytes,
    /// but it is bounded by the fixed 4 MiB CPU image and avoids N full-size
    /// transient Metal backing allocations during typography changes.
    func flushPendingUpload() {
      guard let region = pendingUploadBounds else { return }
      let byteOffset = region.origin.y * budget.width + region.origin.x
      texture.replace(
        region: region,
        mipmapLevel: 0,
        withBytes: bitmap.advanced(by: byteOffset),
        bytesPerRow: budget.width
      )
      pendingUploadBounds = nil
      pendingGlyphUploadCount = 0
      textureUploadCount += 1
      let uploadBytes = region.size.width * region.size.height
      totalUploadRegionBytes += uploadBytes
      peakUploadRegionBytes = max(peakUploadRegionBytes, uploadBytes)
    }

    private func copyScratchToBitmap(region: MTLRegion) {
      let width = region.size.width
      let height = region.size.height
      for row in 0..<height {
        let source = scratch.advanced(by: row * width)
        let destinationOffset = (region.origin.y + row) * budget.width + region.origin.x
        memcpy(bitmap.advanced(by: destinationOffset), source, width)
      }
    }

    private func includePendingUpload(_ region: MTLRegion) {
      guard let current = pendingUploadBounds else {
        pendingUploadBounds = region
        return
      }
      let minX = min(current.origin.x, region.origin.x)
      let minY = min(current.origin.y, region.origin.y)
      let maxX = max(current.origin.x + current.size.width, region.origin.x + region.size.width)
      let maxY = max(current.origin.y + current.size.height, region.origin.y + region.size.height)
      pendingUploadBounds = MTLRegionMake2D(minX, minY, maxX - minX, maxY - minY)
    }

    private func allocate(width: Int, height: Int) throws -> (x: Int, y: Int) {
      guard width <= budget.width, height <= budget.height else {
        throw OuroGlyphAtlasError.textureFull
      }
      if shelfX + width > budget.width {
        shelfX = 0
        shelfY += shelfHeight
        shelfHeight = 0
      }
      guard shelfY + height <= budget.height else {
        throw OuroGlyphAtlasError.textureFull
      }
      let origin = (x: shelfX, y: shelfY)
      shelfX += width
      shelfHeight = max(shelfHeight, height)
      return origin
    }

    private func rasterize(
      text: String,
      baseFont: NSFont,
      bold: Bool,
      italic: Bool,
      width: Int,
      height: Int,
      columns: Int
    ) throws {
      let byteCount = width.multipliedReportingOverflow(by: height)
      guard !byteCount.overflow, byteCount.partialValue <= scratchBytes else {
        throw OuroGlyphAtlasError.invalidCellSize
      }
      memset(scratch, 0, byteCount.partialValue)
      guard
        let context = CGContext(
          data: scratch,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width,
          space: CGColorSpaceCreateDeviceGray(),
          bitmapInfo: CGImageAlphaInfo.none.rawValue
        )
      else {
        throw OuroGlyphAtlasError.rasterContextFailed
      }

      var traits: NSFontTraitMask = []
      if bold { traits.insert(.boldFontMask) }
      if italic { traits.insert(.italicFontMask) }
      let styledBaseFont =
        traits.isEmpty
        ? baseFont
        : NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
      // SF Mono intentionally covers terminal-oriented Latin and symbols, but
      // not every script a user's input method can commit. An explicit font
      // attribute does not make CTLine perform dependable fallback for missing
      // glyphs, which made valid Korean cells occupy width while rendering as
      // blank space. Resolve one concrete CoreText face for this grapheme while
      // preserving the base font's size and requested traits.
      let styledCoreFont = CTFontCreateWithName(
        styledBaseFont.fontName as CFString,
        styledBaseFont.pointSize,
        nil
      )
      let font = CTFontCreateForString(
        styledCoreFont,
        text as CFString,
        CFRange(location: 0, length: (text as NSString).length)
      )
      let attributed = NSAttributedString(
        string: text,
        attributes: [
          NSAttributedString.Key(kCTFontAttributeName as String): font,
          .foregroundColor: NSColor.white,
        ]
      )
      let line = CTLineCreateWithAttributedString(attributed)
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
      let placement = TerminalGlyphPlacementPolicy.resolve(
        lineWidth: lineWidth,
        tileWidth: CGFloat(width),
        columns: columns
      )
      context.setFillColor(gray: 1, alpha: 1)
      context.textMatrix = CGAffineTransform(scaleX: placement.horizontalScale, y: 1)
      let x = placement.originX / placement.horizontalScale
      let y = max(0, (CGFloat(height) - (ascent + descent)) * 0.5 + descent)
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(line, context)
    }
  }
#endif
