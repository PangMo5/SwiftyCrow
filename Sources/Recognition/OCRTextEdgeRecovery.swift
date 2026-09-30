// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Recheck prose only when visible ink extends beyond the recognized regions.
/// This recovers clipped prefixes and short tails without rereading every frame.
enum OCRTextEdgeRecovery {

  // MARK: Internal

  struct RowGap: Sendable {
    var bounds: CGRect
    var glyphHeight: CGFloat
    var context: [OCRResult.Line]
  }

  /// Aligned physical rows can expose a detector blind spot without assuming
  /// its wording. A short paragraph may disappear as a whole, so paragraph
  /// spacing need not be an exact multiple of the established line advance.
  static func rowGaps(in lines: [OCRResult.Line], imageSize: CGSize) -> [RowGap] {
    guard imageSize.width > 0, imageSize.height > 0 else { return [] }
    let canvas = CGRect(origin: .zero, size: imageSize)
    func pixels(_ box: CGRect) -> CGRect {
      CGRect(
        x: box.minX * imageSize.width,
        y: box.minY * imageSize.height,
        width: box.width * imageSize.width,
        height: box.height * imageSize.height
      )
    }
    let rows = lines.filter {
      !$0.isVerticalBlock && $0.rowCount == 1 && $0.tableCell == nil && !$0.preservesSource
        && abs($0.rotationRadians) < 0.05 && $0.text.count >= 2
        && !OCRTextSemantics.isCode($0.text) && !OCRTextSemantics.isIdentifier($0.text)
    }.map { (line: $0, box: pixels($0.boundingBoxNormalized)) }.filter {
      $0.box.height >= 6 && $0.box.height <= imageSize.height * 0.1 && $0.box.width >= $0.box.height
    }.sorted {
      if $0.box.minY != $1.box.minY { return $0.box.minY < $1.box.minY }
      if $0.box.minX != $1.box.minX { return $0.box.minX < $1.box.minX }
      return $0.box.width < $1.box.width
    }
    var visited = Set<[Int]>()
    var gaps = [RowGap]()
    for anchor in rows.indices {
      for trailing in [false, true] {
        let a = rows[anchor].box
        let peers = rows.indices.filter { index in
          let b = rows[index].box
          let edge = trailing ? abs(a.maxX - b.maxX) : abs(a.minX - b.minX)
          return edge <= min(a.height, b.height) * 0.6
            && min(a.height, b.height) / max(a.height, b.height) >= 0.6
        }
        guard
          peers.count >= 5, visited.insert(peers).inserted,
          Set(peers.compactMap { rows[$0].line.recognitionGroupID }).count >= 3
        else { continue }
        let ordered = peers.sorted { rows[$0].box.midY < rows[$1].box.midY }
        let heights = peers.map { rows[$0].box.height }.sorted()
        let height = heights[heights.count / 2]
        let advances = zip(ordered, ordered.dropFirst()).map { rows[$1].box.midY - rows[$0].box.midY }
          // Vision's boxes include ascenders, superscripts and padding; their
          // height can exceed the physical row advance in ordinary prose.
          .filter { $0 >= height * 0.8 && $0 <= height * 2.8 }.sorted()
        guard advances.count >= 3 else { continue }
        let advance = advances[advances.count / 2]
        guard advances.count(where: { abs($0 - advance) <= height * 0.25 }) >= 3 else { continue }
        for (upper, lower) in zip(ordered, ordered.dropFirst()) {
          let a = rows[upper].box
          let b = rows[lower].box
          let distance = b.midY - a.midY
          guard
            distance >= advance * 2 - height * 0.35,
            distance <= advance * 4 + height * 0.35
          else { continue }
          let center = (a.midY + b.midY) / 2
          let singleRow = abs(distance - advance * 2) <= height * 0.35
          let top = singleRow ? max(a.maxY + 2, center - height * 0.7) : a.maxY + 2
          let bottom = singleRow ? min(b.minY - 2, center + height * 0.7) : b.minY - 2
          let bounds = CGRect(
            x: min(a.minX, b.minX) - height * 0.3,
            y: top,
            width: max(a.maxX, b.maxX) - min(a.minX, b.minX) + height * 0.6,
            height: bottom - top
          ).integral.intersection(canvas)
          guard
            bounds.height >= height * 0.8,
            !lines.contains(where: { pixels($0.boundingBoxNormalized).intersects(bounds) }),
            !gaps.contains(where: { $0.bounds.intersects(bounds) })
          else { continue }
          gaps.append(.init(bounds: bounds, glyphHeight: height, context: [rows[upper].line, rows[lower].line]))
        }
      }
    }
    return gaps.sorted { $0.bounds.minY == $1.bounds.minY ? $0.bounds.minX < $1.bounds.minX : $0.bounds.minY < $1.bounds.minY }
  }

  static func recoverRows(
    _ lines: [OCRResult.Line],
    image: CGImage,
    language: Language,
    recognize: @Sendable (CGRect, Language, CGFloat) async throws -> [OCRResult.Line]
  ) async throws -> [OCRResult.Line] {
    let size = CGSize(width: image.width, height: image.height)
    var result = lines
    var requests = 0
    for gap in rowGaps(in: lines, imageSize: size) {
      try Task.checkCancellation()
      guard hasRowInk(in: image, bounds: gap.bounds) else { continue }
      let hint = language.isAuto
        ? LanguageDetectionClient.liveValue.detect(gap.context.map(\.text).joined(separator: " "), 0.65) ?? language
        : language
      let candidates = try await recognize(gap.bounds, hint, gap.glyphHeight)
      let group = (result.compactMap(\.recognitionGroupID).max() ?? -1) + 1
      let accepted = candidates.filter { candidate in
        let box = candidate.boundingBoxNormalized
        let pixels = CGRect(
          x: box.minX * size.width,
          y: box.minY * size.height,
          width: box.width * size.width,
          height: box.height * size.height
        )
        let overlap = pixels.intersection(gap.bounds)
        return !candidate.isVerticalBlock && candidate.recognitionConfidence >= 0.5
          && candidate.text.unicodeScalars.count(where: CharacterSet.letters.contains) >= 2
          && !overlap.isNull && pixels.width * pixels.height > 0
          && overlap.width * overlap.height >= pixels.width * pixels.height * 0.9
      }.map { candidate in
        var candidate = candidate
        candidate.recognitionGroupID = group
        return candidate
      }
      if !accepted.isEmpty { result = OCRCandidateReconciler.adding(accepted, to: result) }
      requests += 1
      if requests == 4 { break }
    }
    return result
  }

  static func recover(_ lines: [OCRResult.Line], image: CGImage, language: Language) async throws -> [OCRResult.Line] {
    var result = lines
    let groups = Dictionary(
      grouping: lines.filter { !$0.isVerticalBlock && $0.recognitionGroupID != nil },
      by: { $0.recognitionGroupID! }
    )
    var requests = 0
    for id in groups.keys.sorted() {
      guard
        let group = groups[id], group.map(\.text).joined().count >= 24,
        !group
          .contains(where: { $0.preservesSource || OCRTextSemantics.isCode($0.text) || OCRTextSemantics.isIdentifier($0.text) }),
        let crop = recoveryCrop(group, all: lines, image: image)
      else { continue }
      try Task.checkCancellation()
      let hint = language.isAuto
        ? LanguageDetectionClient.liveValue.detect(group.map(\.text).joined(separator: " "), 0.65) ?? language
        : language
      let candidates = try await VisionTextRecognizer.additionalText(
        in: image,
        language: hint,
        crop: crop,
        minimumGlyphHeight: group
          .map {
            $0.boundingBoxNormalized.height * CGFloat(image.height)
          }
          .min() ?? 20,
        preferredScale: 2
      )
      result = merging(candidates, into: result, groupID: id)
      requests += 1
      if requests == 4 { break }
    }
    return result
  }

  static func merging(_ candidates: [OCRResult.Line], into primary: [OCRResult.Line], groupID: Int) -> [OCRResult.Line] {
    var result = primary
    func normalized(_ text: String) -> String {
      text.filter { !$0.isWhitespace }.lowercased()
    }
    for var candidate in candidates {
      let b = candidate.boundingBoxNormalized
      if
        let index = result.indices.first(where: { i in
          let old = result[i]
          let a = old.boundingBoxNormalized
          return old.recognitionGroupID == groupID && normalized(candidate.text).count > normalized(old.text).count
            && normalized(candidate.text).contains(normalized(old.text))
            && abs(a.midY - b.midY) <= max(a.height, b.height) * 0.4 && min(a.height, b.height) / max(a.height, b.height) > 0.6
        })
      {
        candidate.recognitionGroupID = groupID
        candidate.followingSeparator = result[index].followingSeparator
        candidate.continuesToNextLine = result[index].continuesToNextLine
        if candidate.recognitionLanguages.isEmpty { candidate.recognitionLanguages = result[index].recognitionLanguages }
        candidate.alignment = result[index].alignment
        result[index] = candidate
        continue
      }
      guard
        candidate.text.count <= 8, candidate.recognitionConfidence >= 0.5,
        !result.contains(where: { old in
          let overlap = b.intersection(old.boundingBoxNormalized)
          return !overlap.isNull && overlap.width * overlap.height > b.width * b.height * 0.35
        }), let previous = result.indices.filter({ result[$0].recognitionGroupID == groupID }).max(by: {
          result[$0].boundingBoxNormalized.maxY < result[$1].boundingBoxNormalized.maxY
        })
      else { continue }
      let a = result[previous].boundingBoxNormalized
      guard
        b.minY >= a.midY, b.minY - a.maxY < a.height,
        abs(a.minX - b.minX) * candidate.imageAspectRatio < a.height,
        min(a.height, b.height) / max(a.height, b.height) > 0.5
      else { continue }
      candidate.recognitionGroupID = groupID
      candidate.alignment = result[previous].alignment
      if
        let last = result[previous].text.last, let first = candidate.text.first,
        last.unicodeScalars.allSatisfy({ (0x3040...0x9FFF).contains($0.value) }),
        first.unicodeScalars.allSatisfy({ (0x3040...0x9FFF).contains($0.value) })
      {
        result[previous].followingSeparator = ""
      }
      result.insert(candidate, at: previous + 1)
    }
    return result
  }

  // MARK: Private

  /// Blank spacing and one-pixel dividers are not missing text. Sample only
  /// each proposed row; never allocate another full-capture raster here.
  private static func hasRowInk(in image: CGImage, bounds: CGRect) -> Bool {
    guard
      let crop = image.cropping(to: bounds),
      let raster = CGContext(
        data: nil,
        width: crop.width,
        height: crop.height,
        bitsPerComponent: 8,
        bytesPerRow: crop.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let pixels = raster.data?.assumingMemoryBound(to: UInt8.self)
    else { return false }
    raster.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
    let border = (0..<crop.width).flatMap { [$0, (crop.height - 1) * crop.width + $0] }
    let background = (0..<3).map { channel in
      let values = border.map { Int(pixels[$0 * 4 + channel]) }.sorted()
      return values[values.count / 2]
    }
    var ink = 0
    var occupiedRows = 0
    for y in 0..<crop.height {
      var count = 0
      for x in 0..<crop.width {
        let index = (y * crop.width + x) * 4
        if (0..<3).contains(where: { abs(Int(pixels[index + $0]) - background[$0]) >= 35 }) { count += 1 }
      }
      ink += count
      if count >= 2 { occupiedRows += 1 }
    }
    return occupiedRows >= 3 && occupiedRows <= crop.height * 9 / 10
      && ink >= max(6, crop.width * crop.height / 200) && ink < crop.width * crop.height / 2
  }

  private static func recoveryCrop(_ group: [OCRResult.Line], all: [OCRResult.Line], image: CGImage) -> CGRect? {
    let bounds = group.dropFirst().reduce(group[0].boundingBoxNormalized) { $0.union($1.boundingBoxNormalized) }
    let h = (group.map(\.boundingBoxNormalized.height).min() ?? 0) * CGFloat(image.height)
    let crop = CGRect(
      x: bounds.minX * CGFloat(image.width),
      y: bounds.minY * CGFloat(image.height),
      width: bounds.width * CGFloat(image.width),
      height: bounds.height * CGFloat(image.height)
    )
    .insetBy(dx: -max(12, h * 0.8), dy: -max(12, h * 0.8)).integral.intersection(CGRect(
      x: 0,
      y: 0,
      width: image.width,
      height: image.height
    ))
    guard
      let cut = image.cropping(to: crop), let context = CGContext(
        data: nil,
        width: cut.width,
        height: cut.height,
        bitsPerComponent: 8,
        bytesPerRow: cut.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(cut, in: CGRect(x: 0, y: 0, width: cut.width, height: cut.height))
    guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
    let corners = [0, (cut.width - 1) * 4, (cut.height - 1) * cut.width * 4, (cut.height * cut.width - 1) * 4]
    let bg = (0..<3).map { channel in corners.map { Int(data[$0 + channel]) }.sorted()[2] }
    guard corners.allSatisfy({ o in (0..<3).allSatisfy { abs(Int(data[o + $0]) - bg[$0]) < 24 } }) else { return nil }
    let covered = all.map { line in
      let b = line.boundingBoxNormalized
      return CGRect(
        x: b.minX * CGFloat(image.width) - crop.minX,
        y: b.minY * CGFloat(image.height) - crop.minY,
        width: b.width * CGFloat(image.width),
        height: b.height * CGFloat(image.height)
      ).insetBy(dx: -2, dy: -2)
    }.filter { $0.intersects(CGRect(x: 0, y: 0, width: cut.width, height: cut.height)) }
    var ink = 0
    for y in 0..<cut.height { for x in 0..<cut.width {
      let o = (y * cut.width + x) * 4
      guard
        (0..<3).contains(where: { abs(Int(data[o + $0]) - bg[$0]) > 80 }), !covered.contains(where: { $0.contains(CGPoint(
          x: x,
          y: y
        )) })
      else { continue }
      ink += 1
      if ink >= max(8, Int(h * 0.6)) { return crop }
    }}
    return nil
  }
}
