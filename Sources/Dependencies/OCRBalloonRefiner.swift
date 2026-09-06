// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - OCRBalloonRefiner

/// Reconstructs printed dialogue from enclosed paper regions. Document OCR can
/// split emphatic lettering into words, or read across two connected balloons.
/// Boundaries come from the image, never from a dictionary of expected dialogue.
enum OCRBalloonRefiner {
  static func refine(_ lines: [OCRResult.Line], in image: CGImage, language: Language) async throws -> [OCRResult.Line] {
    guard qualifies(lines), let raster = BalloonRaster(image: image, longestSide: 1024) else { return lines }
    let started = ContinuousClock.now
    let regions = raster.textRegions(around: lines)
    guard regions.count >= 2 else { return lines }
    var replacements = [(BalloonRegion, OCRResult.Line)]()
    // Bound native Vision work. Rechecking a handful of crops should not launch
    // one model request for every word in the document.
    for region in regions.prefix(24) {
      try Task.checkCancellation()
      guard let crop = raster.maskedCrop(of: image, region: region) else { continue }
      let pixelRect = region.pixelRect(in: image)
      let sourceRect = CGRect(
        x: pixelRect.minX / CGFloat(image.width),
        y: pixelRect.minY / CGFloat(image.height),
        width: pixelRect.width / CGFloat(image.width),
        height: pixelRect.height / CGFloat(image.height)
      )
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      if language.isAuto {
        request.automaticallyDetectsLanguage = true
      } else {
        request.recognitionLanguages = [language.localeLanguage]
      }
      let observations = try await request.perform(on: crop)
      let rows = observations.compactMap { observation -> (String, CGRect)? in
        guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.3 else { return nil }
        let box = observation.boundingBox.cgRect
        let mapped = CGRect(
          x: sourceRect.minX + box.minX * sourceRect.width,
          y: sourceRect.minY + (1 - box.maxY) * sourceRect.height,
          width: box.width * sourceRect.width,
          height: box.height * sourceRect.height
        )
        return (candidate.string, mapped)
      }.sorted { lhs, rhs in
        abs(lhs.1.midY - rhs.1.midY) <= min(lhs.1.height, rhs.1.height) * 0.45
          ? lhs.1.minX < rhs.1.minX
          : lhs.1.midY < rhs.1.midY
      }
      guard rows.count >= 2 else { continue }
      let text = joinedRows(rows.map(\.0))
      let originalLength = lines.filter { region.contains($0.boundingBoxNormalized.center) }.reduce(0) { $0 + $1.text.count }
      // Never replace an established region with a nearly empty crop result.
      guard text.count >= max(12, originalLength / 2) else { continue }
      let bounds = rows.dropFirst().reduce(rows[0].1) { $0.union($1.1) }
      let heights = rows.map { $0.1.height }.sorted()
      let glyphHeight = heights[heights.count / 2]
      var line = OCRResult.Line(
        boundingBoxNormalized: bounds,
        text: text,
        rowCount: rows.count,
        horizontalGlyphScale: glyphHeight,
        horizontalInkScale: glyphHeight,
        replacementPatches: rows.map { OverlaySourcePatch(box: $0.1) },
        alignment: .center,
        surface: OverlaySourceSurface(box: region.interiorBox, confidence: 1, clippingBox: region.box, clippingRows: region.spans)
      )
      line.isReconstructedTextRegion = true
      replacements.append((region, line))
    }
    guard !replacements.isEmpty else { return lines }
    Log.ocr
      .debug(
        "Reconstructed \(replacements.count, privacy: .public) printed text regions in \((ContinuousClock.now - started).loggedSeconds, privacy: .public)s"
      )
    let retained = lines.filter { line in
      !replacements.contains { region, _ in
        let box = line.boundingBoxNormalized
        let overlap = box.intersection(region.box)
        return region.contains(box.center)
          || (!overlap.isNull && overlap.width * overlap.height > box.width * box.height * 0.45)
      }
    }
    return (retained + replacements.map(\.1)).sorted {
      abs($0.boundingBoxNormalized.minY - $1.boundingBoxNormalized.minY) < 0.02
        ? $0.boundingBoxNormalized.minX < $1.boundingBoxNormalized.minX
        : $0.boundingBoxNormalized.minY < $1.boundingBoxNormalized.minY
    }
  }

  static func qualifies(_ lines: [OCRResult.Line]) -> Bool {
    guard lines.count >= 6, !lines.contains(where: \.isVerticalBlock) else { return false }
    let letters = lines.map(\.text).joined().unicodeScalars.filter { CharacterSet.letters.contains($0) }
    guard letters.count >= 80 else { return false }
    return letters.count(where: { CharacterSet.uppercaseLetters.contains($0) }) * 10 >= letters.count * 9
  }

  static func joinedRows(_ rows: [String]) -> String {
    rows.reduce("") { result, row in
      let row = row.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !result.isEmpty else { return row }
      return result + (result.hasSuffix("-") ? "" : " ") + row
    }
  }
}

// MARK: - BalloonRegion

struct BalloonRegion {
  let box: CGRect
  let spans: [CGRect]

  /// Largest rectangle inside the ink boundary. A balloon's bounding box can
  /// overlap its neighbor even though their actual interiors are disjoint.
  var interiorBox: CGRect {
    var best = CGRect.zero
    for start in spans.indices {
      var left = spans[start].minX
      var right = spans[start].maxX
      for end in start..<spans.count {
        left = max(left, spans[end].minX)
        right = min(right, spans[end].maxX)
        guard right > left else { break }
        let candidate = CGRect(x: left, y: spans[start].minY, width: right - left, height: spans[end].maxY - spans[start].minY)
        if candidate.width * candidate.height > best.width * best.height { best = candidate }
      }
    }
    return best.insetBy(dx: min(best.width * 0.04, 0.004), dy: min(best.height * 0.04, 0.003))
  }

  func pixelRect(in image: CGImage) -> CGRect {
    CGRect(
      x: box.minX * CGFloat(image.width),
      y: box.minY * CGFloat(image.height),
      width: box.width * CGFloat(image.width),
      height: box.height * CGFloat(image.height)
    ).integral
  }

  func contains(_ point: CGPoint) -> Bool {
    spans.contains { $0.contains(point) }
  }
}

// MARK: - BalloonRaster

/// Binary connected components retain ink boundaries even on aged, textured
/// paper. Fill enclosed glyph holes, then erode the interior to separate narrow
/// connectors between balloons. Grow the interiors back without crossing ink.
struct BalloonRaster {

  // MARK: Lifecycle

  init?(image: CGImage, longestSide: Int) {
    let scale = min(1, CGFloat(longestSide) / CGFloat(max(image.width, image.height)))
    width = max(1, Int(CGFloat(image.width) * scale))
    height = max(1, Int(CGFloat(image.height) * scale))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let data = context.data else { return nil }
    defer { withExtendedLifetime(context) { } }
    let bytes = data.bindMemory(to: UInt8.self, capacity: width * height * 4)
    paper = (0..<width * height).map { index in
      let offset = index * 4
      return (Double(bytes[offset]) * 0.2126 + Double(bytes[offset + 1]) * 0.7152 + Double(bytes[offset + 2]) * 0.0722) > 153
    }
  }

  // MARK: Internal

  let width: Int
  let height: Int
  let paper: [Bool]

  func textRegions(around lines: [OCRResult.Line]) -> [BalloonRegion] {
    let components = Self.components(paper, width: width, height: height)
    let glyphHeights = lines.map { $0.boundingBoxNormalized.height * CGFloat(height) / CGFloat(max(1, $0.rowCount)) }.sorted()
    let radius = max(2, min(min(width, height) / 24, Int(glyphHeights[glyphHeights.count / 2] * 0.65)))
    var result = [BalloonRegion]()
    for component in components where component.count >= 600 {
      if Task.isCancelled { break }
      let xs = component.map { $0 % width }
      let ys = component.map { $0 / width }
      let x0 = xs.min()!
      let x1 = xs.max()!
      let y0 = ys.min()!
      let y1 = ys.max()!
      guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1 else { continue }
      let box = normalized(x: x0, y: y0, width: x1 - x0 + 1, height: y1 - y0 + 1)
      guard lines.count(where: { box.contains($0.boundingBoxNormalized.center) }) >= 3 else { continue }
      let w = x1 - x0 + 3
      let h = y1 - y0 + 3
      var filled = [Bool](repeating: false, count: w * h)
      for index in component { filled[(index / width - y0 + 1) * w + index % width - x0 + 1] = true }
      // Flood the exterior only. Everything unreachable inside is paper or a
      // glyph hole, so lettering cannot break the subsequent interior erosion.
      var outside = [Bool](repeating: false, count: filled.count)
      var queue = [0]
      outside[0] = true
      var cursor = 0
      while cursor < queue.count {
        let index = queue[cursor]
        cursor += 1
        for next in Self.neighbors(index, width: w, height: h) where !outside[next] && !filled[next] {
          outside[next] = true
          queue.append(next)
        }
      }
      filled = outside.map { !$0 }
      var distance = filled.map { $0 ? w + h : 0 }
      for y in 1..<h {
        for x in 1..<w {
          let i = y * w + x
          distance[i] = min(distance[i], min(distance[i - 1], distance[i - w]) + 1)
        }
      }
      for y in stride(from: h - 2, through: 0, by: -1) {
        for x in stride(from: w - 2, through: 0, by: -1) {
          let i = y * w + x
          distance[i] = min(distance[i], min(distance[i + 1], distance[i + w]) + 1)
        }
      }
      let cores = Self.components(distance.map { $0 > radius }, width: w, height: h).filter { $0.count >= 400 }
      var owners = [Int](repeating: -1, count: filled.count)
      var depth = [Int](repeating: 0, count: filled.count)
      queue = []
      for (owner, core) in cores.enumerated() {
        for index in core { owners[index] = owner
          queue.append(index)
        }
      }
      cursor = 0
      while cursor < queue.count {
        let i = queue[cursor]
        cursor += 1
        guard depth[i] < radius - 2 else { continue }
        for next in Self.neighbors(i, width: w, height: h) where filled[next] && owners[next] == -1 {
          owners[next] = owners[i]
          depth[next] = depth[i] + 1
          queue.append(next)
        }
      }
      for owner in cores.indices {
        var spans = [CGRect]()
        for y in 0..<h {
          let columns = (0..<w).filter { owners[y * w + $0] == owner }
          guard let first = columns.first, let last = columns.last else { continue }
          spans.append(normalized(x: x0 + first - 1, y: y0 + y - 1, width: last - first + 1, height: 1))
        }
        guard let first = spans.first else { continue }
        let bounds = spans.dropFirst().reduce(first) { $0.union($1) }
        let region = BalloonRegion(box: bounds, spans: spans)
        let contained = lines.filter { region.contains($0.boundingBoxNormalized.center) }
        guard contained.count >= 3 else { continue }
        let textBounds = contained.dropFirst().reduce(contained[0].boundingBoxNormalized) { $0.union($1.boundingBoxNormalized) }
        guard bounds.width * bounds.height < textBounds.width * textBounds.height * 6 else { continue }
        result.append(region)
      }
    }
    return result
  }

  func maskedCrop(of image: CGImage, region: BalloonRegion) -> CGImage? {
    let rect = region.pixelRect(in: image)
    guard
      let crop = image.cropping(to: rect),
      let context = CGContext(
        data: nil,
        width: crop.width,
        height: crop.height,
        bitsPerComponent: 8,
        bytesPerRow: crop.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    guard let data = context.data else { return nil }
    let bytes = data.bindMemory(to: UInt8.self, capacity: crop.width * crop.height * 4)
    for y in 0..<crop.height {
      let globalY = (rect.minY + CGFloat(y) + 0.5) / CGFloat(image.height)
      let span = region.spans.first { globalY >= $0.minY && globalY < $0.maxY }
      for x in 0..<crop.width {
        let globalX = (rect.minX + CGFloat(x) + 0.5) / CGFloat(image.width)
        if span == nil || globalX < span!.minX || globalX >= span!.maxX {
          let i = (y * crop.width + x) * 4
          bytes[i] = 255
          bytes[i + 1] = 255
          bytes[i + 2] = 255
          bytes[i + 3] = 255
        }
      }
    }
    guard let masked = context.makeImage() else { return nil }
    let scale = max(1, min(3, 960 / CGFloat(masked.width)))
    guard
      let enlarged = CGContext(
        data: nil,
        width: Int(CGFloat(masked.width) * scale),
        height: Int(CGFloat(masked.height) * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    enlarged.interpolationQuality = .high
    enlarged.draw(masked, in: CGRect(x: 0, y: 0, width: enlarged.width, height: enlarged.height))
    return enlarged.makeImage()
  }

  // MARK: Private

  private static func neighbors(_ i: Int, width: Int, height: Int) -> [Int] {
    var result = [Int]()
    if i % width > 0 { result.append(i - 1) }
    if i % width + 1 < width { result.append(i + 1) }
    if i >= width { result.append(i - width) }
    if i + width < width * height { result.append(i + width) }
    return result
  }

  private static func components(_ mask: [Bool], width: Int, height: Int) -> [[Int]] {
    var visited = [Bool](repeating: false, count: mask.count)
    var result = [[Int]]()
    for start in mask.indices where mask[start] && !visited[start] {
      var queue = [start]
      visited[start] = true
      var cursor = 0
      while cursor < queue.count {
        let i = queue[cursor]
        cursor += 1
        for next in neighbors(i, width: width, height: height) where mask[next] && !visited[next] {
          visited[next] = true
          queue.append(next)
        }
      }
      result.append(queue)
    }
    return result
  }

  private func normalized(x: Int, y: Int, width: Int, height: Int) -> CGRect {
    CGRect(
      x: CGFloat(x) / CGFloat(self.width),
      y: CGFloat(y) / CGFloat(self.height),
      width: CGFloat(width) / CGFloat(self.width),
      height: CGFloat(height) / CGFloat(self.height)
    )
  }

}

extension CGRect {
  fileprivate var center: CGPoint {
    CGPoint(x: midX, y: midY)
  }
}
