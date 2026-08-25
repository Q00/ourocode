#if OUROCODE_GHOSTTY_METAL_SURFACE
import AppKit
import Foundation
import Metal

private func require(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
  }
}

@main
enum TerminalGlyphAtlasFixture {
  static func main() throws {
    guard let device = MTLCreateSystemDefaultDevice() else {
      FileHandle.standardError.write(Data("FAIL: Metal device unavailable\n".utf8))
      exit(1)
    }

    let desktop = try OuroGlyphAtlas(device: device)
    require(desktop.textureBytes == 4 * 1_024 * 1_024, "desktop atlas is not a fixed 4 MiB texture")
    require(desktop.cpuBackingBytes == desktop.textureBytes, "desktop atlas lacks one exact 4 MiB CPU backing")
    require(
      desktop.scratchBackingBytes
        == OuroGlyphAtlas.Budget.desktop.maximumTileWidth
          * OuroGlyphAtlas.Budget.desktop.maximumTileHeight,
      "desktop atlas scratch allocation escaped its fixed tile bound"
    )
    require(desktop.entryCount == 0, "new atlas unexpectedly retained glyph entries")
    require(desktop.liveMetadataBytes == 0, "new atlas unexpectedly retained metadata")

    let font = NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    let entryBound = OuroGlyphAtlas.Budget(
      width: 64,
      height: 64,
      metadataBytes: 1_024 * 1_024,
      maximumEntries: 1,
      maximumTileWidth: 32,
      maximumTileHeight: 32
    )
    let boundedEntries = try OuroGlyphAtlas(device: device, budget: entryBound)
    _ = try boundedEntries.resolve(
      text: "A",
      baseFont: font,
      cellWidth: 12,
      cellHeight: 24,
      columns: 1,
      bold: false,
      italic: false
    )
    require(boundedEntries.entryCount == 1, "first bounded glyph was not cached exactly once")
    do {
      _ = try boundedEntries.resolve(
        text: "B",
        baseFont: font,
        cellWidth: 12,
        cellHeight: 24,
        columns: 1,
        bold: false,
        italic: false
      )
      require(false, "entry cap admitted a second glyph")
    } catch OuroGlyphAtlasError.metadataBudgetExceeded {
      // The same fail-closed error covers the jointly checked entry and
      // metadata bounds without exposing either capacity to callers.
    }
    boundedEntries.reset()
    require(boundedEntries.entryCount == 0, "atlas reset retained glyph entries")
    require(boundedEntries.liveMetadataBytes == 0, "atlas reset retained metadata accounting")

    let textureBound = OuroGlyphAtlas.Budget(
      width: 16,
      height: 16,
      metadataBytes: 1_024 * 1_024,
      maximumEntries: 8,
      maximumTileWidth: 14,
      maximumTileHeight: 14
    )
    let boundedTexture = try OuroGlyphAtlas(device: device, budget: textureBound)
    _ = try boundedTexture.resolve(
      text: "A",
      baseFont: font,
      cellWidth: 14,
      cellHeight: 14,
      columns: 1,
      bold: false,
      italic: false
    )
    do {
      _ = try boundedTexture.resolve(
        text: "B",
        baseFont: font,
        cellWidth: 14,
        cellHeight: 14,
        columns: 1,
        bold: false,
        italic: false
      )
      require(false, "texture cap admitted a second full-shelf glyph")
    } catch OuroGlyphAtlasError.textureFull {
      // Expected: the texture is fixed and never grows.
    }

    let batchBudget = OuroGlyphAtlas.Budget(
      width: 512,
      height: 256,
      metadataBytes: 1_024 * 1_024,
      maximumEntries: 64,
      maximumTileWidth: 32,
      maximumTileHeight: 32
    )
    let batched = try OuroGlyphAtlas(device: device, budget: batchBudget)
    let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ012345")
    require(glyphs.count == 32, "batched upload fixture lost its glyph set")
    var resolvedTiles: [(glyph: Character, tile: OuroGlyphAtlas.Tile)] = []
    for glyph in glyphs {
      let tile = try batched.resolve(
        text: String(glyph),
        baseFont: font,
        cellWidth: 12,
        cellHeight: 24,
        columns: 1,
        bold: false,
        italic: false
      )
      guard let tile else {
        require(false, "non-space glyph did not resolve an atlas tile")
        continue
      }
      resolvedTiles.append((glyph, tile))
    }
    require(Set(resolvedTiles.map(\.tile.uv)).count == 32, "distinct glyphs aliased one atlas tile")
    require(batched.pendingGlyphUploadCount == 32, "glyphs uploaded eagerly instead of batching")
    require(batched.textureUploadCount == 0, "texture upload occurred before frame preparation completed")
    batched.flushPendingUpload()
    require(batched.pendingGlyphUploadCount == 0, "batched upload did not clear pending glyphs")
    require(batched.textureUploadCount == 1, "32 glyphs did not coalesce into one texture upload")
    require(batched.totalUploadRegionBytes > 0, "batched upload recorded no dirty bytes")
    require(
      batched.peakUploadRegionBytes <= batched.cpuBackingBytes,
      "one coalesced upload exceeded the fixed CPU atlas backing"
    )

    var pixels = [UInt8](repeating: 0, count: batchBudget.width * batchBudget.height)
    batched.texture.getBytes(
      &pixels,
      bytesPerRow: batchBudget.width,
      from: MTLRegionMake2D(0, 0, batchBudget.width, batchBudget.height),
      mipmapLevel: 0
    )
    require(pixels.contains(where: { $0 != 0 }), "batched texture upload produced a blank atlas")
    for resolved in resolvedTiles {
      let uv = resolved.tile.uv
      let minX = Int((uv.x * Float(batchBudget.width)).rounded())
      let minY = Int((uv.y * Float(batchBudget.height)).rounded())
      let maxX = Int((uv.z * Float(batchBudget.width)).rounded())
      let maxY = Int((uv.w * Float(batchBudget.height)).rounded())
      require(
        minX >= 0 && minY >= 0 && maxX <= batchBudget.width && maxY <= batchBudget.height
          && maxX - minX == 12 && maxY - minY == 24,
        "glyph \(resolved.glyph) produced invalid texture coordinates"
      )
      var tileHasInk = false
      for y in minY..<maxY where !tileHasInk {
        let start = y * batchBudget.width + minX
        tileHasInk = pixels[start..<(start + 12)].contains(where: { $0 != 0 })
      }
      require(tileHasInk, "glyph \(resolved.glyph) was blank after the coalesced GPU upload")
    }
    _ = try batched.resolve(
      text: "A",
      baseFont: font,
      cellWidth: 12,
      cellHeight: 24,
      columns: 1,
      bold: false,
      italic: false
    )
    batched.flushPendingUpload()
    require(batched.textureUploadCount == 1, "cached glyph triggered a redundant texture upload")

    let koreanTile = try batched.resolve(
      text: "한",
      baseFont: font,
      cellWidth: 12,
      cellHeight: 24,
      columns: 2,
      bold: false,
      italic: false
    )
    guard let koreanTile else {
      require(false, "Korean fallback glyph did not resolve an atlas tile")
      return
    }
    batched.flushPendingUpload()
    require(batched.textureUploadCount == 2, "Korean fallback glyph was not uploaded")
    let koreanMinX = Int((koreanTile.uv.x * Float(batchBudget.width)).rounded())
    let koreanMinY = Int((koreanTile.uv.y * Float(batchBudget.height)).rounded())
    let koreanMaxX = Int((koreanTile.uv.z * Float(batchBudget.width)).rounded())
    let koreanMaxY = Int((koreanTile.uv.w * Float(batchBudget.height)).rounded())
    require(
      koreanMaxX - koreanMinX == 24 && koreanMaxY - koreanMinY == 24,
      "Korean fallback glyph did not retain its two-column terminal slot"
    )
    var koreanPixels = [UInt8](repeating: 0, count: batchBudget.width * batchBudget.height)
    batched.texture.getBytes(
      &koreanPixels,
      bytesPerRow: batchBudget.width,
      from: MTLRegionMake2D(0, 0, batchBudget.width, batchBudget.height),
      mipmapLevel: 0
    )
    var koreanHasInk = false
    for y in koreanMinY..<koreanMaxY where !koreanHasInk {
      let start = y * batchBudget.width + koreanMinX
      koreanHasInk = koreanPixels[start..<(start + 24)].contains(where: { $0 != 0 })
    }
    require(koreanHasInk, "CoreText fallback rendered the committed Korean glyph blank")

    print(
      "PASS: fixed atlas batches 32 correct glyphs into one upload "
        + "(dirty peak \(batched.peakUploadRegionBytes) / CPU backing \(batched.cpuBackingBytes) bytes)"
    )
  }
}
#endif
