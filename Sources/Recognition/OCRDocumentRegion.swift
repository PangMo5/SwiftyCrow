// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// A small document inside a large window must not lose glyph resolution to
/// empty margins. Overlapping inputs preserve full-image coverage; detected
/// text only refines their context and never decides which pixels are omitted.
enum OCRDocumentRegion {

  // MARK: Internal

  struct Input: Equatable, Sendable {
    var bounds: CGRect
    var ownership: [CGRect]
  }

  static func needsCropping(imageSize: CGSize, detectedText: [CGRect]) -> Bool {
    let longest = max(imageSize.width, imageSize.height)
    let glyphs = detectedText.map { min($0.width * imageSize.width, $0.height * imageSize.height) }
      .filter { $0.isFinite && $0 > 0 }.sorted()
    guard longest > 1600, !glyphs.isEmpty else { return false }
    return glyphs[glyphs.count / 2] * 1600 / longest < 12
  }

  /// Detached opaque content planes are bounded by the proven edge-connected
  /// backdrop, not by OCR detections. Missing text cannot shrink a document.
  static func surfaceBounds(in image: CGImage) -> [CGRect] {
    let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
    let width = max(1, Int(CGFloat(image.width) * scale))
    let height = max(1, Int(CGFloat(image.height) * scale))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return [] }
    context.interpolationQuality = .none
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return [] }
    let pixels = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
    guard let edge = EdgeBackgroundIndex(pixels: pixels, width: width, height: height) else { return [] }
    var visited = edge.connected
    var surfaces = [CGRect]()
    let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    for start in visited.indices where !visited[start] {
      var queue = [start]
      visited[start] = true
      var cursor = 0
      var left = start % width
      var right = left
      var top = start / width
      var bottom = top
      while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        left = min(left, x)
        right = max(right, x)
        top = min(top, y)
        bottom = max(bottom, y)
        for next in [
          x > 0 ? index - 1 : -1,
          x + 1 < width ? index + 1 : -1,
          y > 0 ? index - width : -1,
          y + 1 < height ? index + width : -1,
        ]
          where next >= 0 && !visited[next]
        {
          visited[next] = true
          queue.append(next)
        }
      }
      let area = (right - left + 1) * (bottom - top + 1)
      guard queue.count * 100 >= area * 85 else { continue }
      let box = CGRect(
        x: CGFloat(left) * canvas.width / CGFloat(width),
        y: CGFloat(top) * canvas.height / CGFloat(height),
        width: CGFloat(right - left + 1) * canvas.width / CGFloat(width),
        height: CGFloat(bottom - top + 1) * canvas.height / CGFloat(height)
      )
      guard
        min(box.width, box.height) >= 80,
        max(box.width, box.height) <= max(canvas.width, canvas.height) * 0.8
      else { continue }
      let coarse = box.insetBy(dx: -canvas.width / CGFloat(width), dy: -canvas.height / CGFloat(height))
        .integral.intersection(canvas)
      surfaces.append(refinedBounds(
        coarse,
        in: image,
        background: edge.color,
        horizontalBand: Int(ceil(canvas.width / CGFloat(width) * 2)) + 2,
        verticalBand: Int(ceil(canvas.height / CGFloat(height) * 2)) + 2
      ))
    }
    return surfaces.sorted { $0.width * $0.height > $1.width * $1.height }
  }

  /// Local surfaces get first ownership; a full-frame request owns everything
  /// else. At most three local inputs are added. Every source pixel remains in
  /// a request, even when text or surface detection is incomplete.
  static func inputs(imageSize: CGSize, detectedText: [CGRect], surfaceBounds: [CGRect] = []) -> [Input] {
    guard
      imageSize.width.isFinite, imageSize.height.isFinite,
      imageSize.width > 0, imageSize.height > 0
    else { return [] }
    let canvas = CGRect(origin: .zero, size: imageSize)
    let rows = detectedText.filter {
      [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) && $0.width > 0 && $0.height > 0
    }.map {
      CGRect(
        x: $0.minX * imageSize.width,
        y: $0.minY * imageSize.height,
        width: $0.width * imageSize.width,
        height: $0.height * imageSize.height
      ).intersection(canvas)
    }.filter { !$0.isNull && !$0.isEmpty }.sorted {
      if $0.minY != $1.minY { return $0.minY < $1.minY }
      if $0.minX != $1.minX { return $0.minX < $1.minX }
      if $0.width != $1.width { return $0.width < $1.width }
      return $0.height < $1.height
    }
    var remaining = [canvas]
    var result = [Input]()
    for surface in surfaceBounds.sorted(by: {
      let a = $0.width * $0.height
      let b = $1.width * $1.height
      if a != b { return a > b }
      if $0.minX != $1.minX { return $0.minX < $1.minX }
      return $0.minY < $1.minY
    }) {
      guard
        result.count < 3,
        [surface.minX, surface.minY, surface.width, surface.height].allSatisfy(\.isFinite),
        surface.width > 0, surface.height > 0
      else { continue }
      let bounds = surface.integral.intersection(canvas)
      guard !bounds.isNull, !bounds.isEmpty else { continue }
      var owned = remaining.map { $0.intersection(bounds) }.filter { !$0.isNull && !$0.isEmpty }
      // A known row crossing a crop boundary belongs to the full-frame input.
      // Never replace it with a clipped local hypothesis.
      for row in rows where !bounds.contains(row) && bounds.intersects(row) {
        owned = owned.flatMap { subtracting(row, from: $0) }
      }
      guard !owned.isEmpty else { continue }
      result.append(.init(bounds: bounds, ownership: owned))
      for piece in owned { remaining = remaining.flatMap { subtracting(piece, from: $0) } }
    }
    if !remaining.isEmpty { result.append(.init(bounds: canvas, ownership: remaining)) }
    return result
  }

  static func owner(of box: CGRect, in inputs: [Input], imageSize: CGSize) -> Int? {
    let center = CGPoint(x: box.midX * imageSize.width, y: box.midY * imageSize.height)
    return inputs.firstIndex { $0.ownership.contains { $0.contains(center) } }
  }

  /// Replanning an input must not discard evidence found by the full-capture
  /// detector. Keep both coordinate-consistent views within the same ownership.
  static func detections(
    in input: Input,
    imageSize: CGSize,
    global: [CGRect],
    local: [CGRect]
  ) -> [CGRect] {
    let bounds = input.bounds
    guard bounds.width > 0, bounds.height > 0, imageSize.width > 0, imageSize.height > 0 else { return [] }
    let mapped = global.filter { owner(of: $0, in: [input], imageSize: imageSize) == 0 }.map { box in
      CGRect(
        x: (box.minX * imageSize.width - bounds.minX) / bounds.width,
        y: (box.minY * imageSize.height - bounds.minY) / bounds.height,
        width: box.width * imageSize.width / bounds.width,
        height: box.height * imageSize.height / bounds.height
      )
    }
    let localInput = Input(
      bounds: CGRect(origin: .zero, size: bounds.size),
      ownership: input.ownership.map { $0.offsetBy(dx: -bounds.minX, dy: -bounds.minY) }
    )
    let owned = local.filter { owner(of: $0, in: [localInput], imageSize: bounds.size) == 0 }
    if bounds == CGRect(origin: .zero, size: imageSize), local == global { return owned }
    return owned + OCRCoverage.uncovered(mapped, by: owned)
  }

  /// Compose independently analyzed inputs without changing their physical
  /// typography, restoration ownership or text-flow geometry.
  static func remap(_ document: VisionTextRecognizer.Document, crop: CGRect, imageSize: CGSize) -> VisionTextRecognizer.Document {
    let region = CGRect(
      x: crop.minX / imageSize.width,
      y: crop.minY / imageSize.height,
      width: crop.width / imageSize.width,
      height: crop.height / imageSize.height
    )
    func box(_ value: CGRect) -> CGRect {
      CGRect(
        x: region.minX + value.minX * region.width,
        y: region.minY + value.minY * region.height,
        width: value.width * region.width,
        height: value.height * region.height
      )
    }
    func appearance(_ value: OverlaySourceAppearance) -> OverlaySourceAppearance {
      var result = value
      result.inkHeightScale *= region.height
      result.fontSizeScale *= region.height
      return result
    }
    return .init(lines: document.lines.map { original in
      var line = original
      line.boundingBoxNormalized = box(line.boundingBoxNormalized)
      line.orientedBox = line.orientedBox.map(box)
      line.imageAspectRatio = imageSize.width / imageSize.height
      line.horizontalGlyphScale *= region.height
      line.horizontalInkScale *= region.height
      line.horizontalLineAdvanceScale *= region.height
      line.verticalCharScale *= region.width
      line.appearance = appearance(line.appearance)
      line.layoutBounds = line.layoutBounds.map(box)
      line.textFlowRegions = line.textFlowRegions.map(box)
      line.layoutExclusions = line.layoutExclusions.map(box)
      if var surface = line.surface {
        surface.box = box(surface.box)
        surface.clippingBox = surface.clippingBox.map(box)
        surface.clippingRows = surface.clippingRows.map(box)
        line.surface = surface
      }
      if var cell = line.tableCell {
        cell.box = box(cell.box)
        line.tableCell = cell
      }
      line.recognitionContainer = line.recognitionContainer.map(box)
      line.recognitionContextBounds = line.recognitionContextBounds.map(box)
      line.replacementPatches = line.replacementPatches.map { original in
        var patch = original
        patch.box = box(patch.box)
        patch.renderingBox = patch.renderingBox.map(box)
        patch.clippingBox = patch.clippingBox.map(box)
        patch.appearance = appearance(patch.appearance)
        return patch
      }
      line.styleRuns = line.styleRuns.map { original in
        var run = original
        run.box = box(run.box)
        run.inkBox = run.inkBox.map(box)
        run.appearance = appearance(run.appearance)
        return run
      }
      line.spacingAnchors = line.spacingAnchors.map { .init(range: $0.range, box: box($0.box)) }
      return line
    }, containers: document.containers.map(box), tableCells: document.tableCells.map { original in
      var cell = original
      cell.box = box(cell.box)
      return cell
    })
  }

  // MARK: Private

  /// The low-resolution component supplies context and a conservative search
  /// bound. Resolve only its perimeter at source resolution: extra backdrop
  /// pixels change Vision's document preprocessing even though text is intact.
  /// Only exact, opaque backdrop pixels are removed; shadows/antialiasing and
  /// unknown content stay in the input. No full-resolution canvas is allocated.
  private static func refinedBounds(
    _ bounds: CGRect,
    in image: CGImage,
    background: OverlayColor,
    horizontalBand: Int,
    verticalBand: Int
  ) -> CGRect {
    let red = UInt8((background.red * 255).rounded())
    let green = UInt8((background.green * 255).rounded())
    let blue = UInt8((background.blue * 255).rounded())
    func offset(in strip: CGRect, rows: Bool, reversed: Bool) -> Int? {
      guard
        let crop = image.cropping(to: strip),
        let raster = CGContext(
          data: nil,
          width: crop.width,
          height: crop.height,
          bitsPerComponent: 8,
          bytesPerRow: crop.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let bytes = raster.data?.assumingMemoryBound(to: UInt8.self)
      else { return nil }
      raster.interpolationQuality = .none
      raster.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      let depth = rows ? crop.height : crop.width
      let span = rows ? crop.width : crop.height
      for distance in 0..<depth {
        let position = reversed ? depth - distance - 1 : distance
        for perpendicular in 0..<span {
          let x = rows ? perpendicular : position
          let y = rows ? position : perpendicular
          let index = (y * crop.width + x) * 4
          if bytes[index + 3] != 255 || bytes[index] != red || bytes[index + 1] != green || bytes[index + 2] != blue {
            return distance
          }
        }
      }
      return nil
    }
    let horizontal = min(bounds.width, CGFloat(horizontalBand))
    let vertical = min(bounds.height, CGFloat(verticalBand))
    guard
      let left = offset(
        in: CGRect(x: bounds.minX, y: bounds.minY, width: horizontal, height: bounds.height),
        rows: false,
        reversed: false
      ),
      let right = offset(
        in: CGRect(x: bounds.maxX - horizontal, y: bounds.minY, width: horizontal, height: bounds.height),
        rows: false,
        reversed: true
      ),
      let top = offset(
        in: CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: vertical),
        rows: true,
        reversed: false
      ),
      let bottom = offset(
        in: CGRect(x: bounds.minX, y: bounds.maxY - vertical, width: bounds.width, height: vertical),
        rows: true,
        reversed: true
      ),
      bounds.width > CGFloat(left + right), bounds.height > CGFloat(top + bottom)
    else { return bounds }
    return CGRect(
      x: bounds.minX + CGFloat(left),
      y: bounds.minY + CGFloat(top),
      width: bounds.width - CGFloat(left + right),
      height: bounds.height - CGFloat(top + bottom)
    )
  }

  private static func subtracting(_ cut: CGRect, from box: CGRect) -> [CGRect] {
    let overlap = box.intersection(cut)
    guard !overlap.isNull, !overlap.isEmpty else { return [box] }
    return [
      CGRect(x: box.minX, y: box.minY, width: box.width, height: overlap.minY - box.minY),
      CGRect(x: box.minX, y: overlap.maxY, width: box.width, height: box.maxY - overlap.maxY),
      CGRect(x: box.minX, y: overlap.minY, width: overlap.minX - box.minX, height: overlap.height),
      CGRect(x: overlap.maxX, y: overlap.minY, width: box.maxX - overlap.maxX, height: overlap.height),
    ].filter { !$0.isEmpty }
  }

}
