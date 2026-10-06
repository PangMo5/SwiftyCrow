// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Short overlapping recognition hypotheses cannot independently own the same
/// pixels. A local reread resolves their segmentation before styling/translation.
enum OCRConflictRecovery {
  static func recover(_ lines: [OCRResult.Line], image: CGImage, language: Language) async throws -> [OCRResult.Line] {
    let candidates = lines.indices.filter {
      !lines[$0].preservesSource && lines[$0].text.count <= 12 && lines[$0].recognitionConfidence < 0.6
    }
    var visited = Set<Int>()
    var clusters = [[Int]]()
    for index in candidates where !visited.contains(index) {
      var group = [index]
      visited.insert(index)
      var cursor = 0
      while cursor < group.count {
        let a = lines[group[cursor]].boundingBoxNormalized
        cursor += 1
        for other in candidates where !visited.contains(other) {
          // Even a small shared strip can be a crossed row/column hypothesis.
          // Waiting for a large overlap lets later coalescing turn those into
          // one wide owner on top of another. Acceptance still requires a
          // stronger, non-overlapping reread covering every old owner.
          if overlap(a, lines[other].boundingBoxNormalized) >= 0.1 {
            group.append(other)
            visited.insert(other)
          }
        }
      }
      if group.count > 1 { clusters.append(group) }
    }
    // Include a clipped neighboring fragment once an actual overlap has
    // established a conflict. Cropping through that fragment would otherwise
    // repeat the original bad segmentation and lose the first glyph.
    let strongMembers = Set(clusters.flatMap { $0 })
    for index in candidates where !strongMembers.contains(index) {
      let best = clusters.indices.compactMap { group -> (Int, CGFloat)? in
        let score = clusters[group].map { overlap(lines[index].boundingBoxNormalized, lines[$0].boundingBoxNormalized) }
          .max() ?? 0
        return score > 0 ? (group, score) : nil
      }.max { $0.1 < $1.1 }
      if let best { clusters[best.0].append(index) }
    }
    guard !clusters.isEmpty else { return lines }
    var removed = Set<Int>()
    var recovered = [OCRResult.Line]()
    for group in clusters.prefix(4) {
      let hint = language.isAuto
        ? LanguageDetectionClient.liveValue.detect(group.map { lines[$0].text }.joined(separator: " "), 0.65) ?? language
        : language
      let boxes = group.map { lines[$0].boundingBoxNormalized }
      let box = boxes.dropFirst().reduce(boxes[0]) { $0.union($1) }
      // A dense cluster can end halfway through the next glyph. One observed
      // glyph of context gives that neighboring word a complete OCR input.
      let glyphs = group.map { index -> CGFloat in
        let line = lines[index]
        return line.isVerticalBlock
          ? (line.verticalCharScale > 0 ? line.verticalCharScale : line.boundingBoxNormalized.width) * CGFloat(image.width)
          : (line.horizontalGlyphScale > 0 ? line.horizontalGlyphScale : line.boundingBoxNormalized.height) *
          CGFloat(image.height)
      }.sorted()
      let compact = group.allSatisfy { lines[$0].text.count <= 3 }
      let pad = max(
        3,
        compact
          ? glyphs[glyphs.count / 2]
          : min(box.width * CGFloat(image.width), box.height * CGFloat(image.height)) * 0.18
      )
      let crop = CGRect(
        x: box.minX * CGFloat(image.width),
        y: box.minY * CGFloat(image.height),
        width: box.width * CGFloat(image.width),
        height: box.height * CGFloat(image.height)
      )
      .insetBy(dx: -pad, dy: -pad).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
      try Task.checkCancellation()
      let fresh = try await VisionTextRecognizer.additionalText(
        in: image,
        language: hint,
        crop: crop,
        minimumGlyphHeight: min(crop.width, crop.height) / 3,
        preferredScale: 2
      )
      guard
        !fresh.isEmpty, fresh.allSatisfy({ $0.recognitionConfidence >= 0.45 }),
        fresh.map(\.text).joined().count >= group.map({ lines[$0].text.count }).max()!,
        coversOwners(boxes, with: fresh.map(\.boundingBoxNormalized)),
        fresh.indices.allSatisfy({ a in fresh.indices.allSatisfy { b in
          a == b || overlap(fresh[a].boundingBoxNormalized, fresh[b].boundingBoxNormalized) < 0.35
        } })
      else { continue }
      // Include a truncated neighboring hypothesis only when the new observed
      // glyph box claims its actual pixels with stronger recognition evidence.
      let claimed = Set(lines.indices.filter { index in
        !lines[index].preservesSource && lines[index].recognitionConfidence < 0.6 && lines[index].text.count <= 12 && fresh
          .contains {
            overlap($0.boundingBoxNormalized, lines[index].boundingBoxNormalized) >= 0.65
              && $0.recognitionConfidence > lines[index].recognitionConfidence
          }
      }).union(group)
      removed.formUnion(claimed)
      recovered += fresh
    }
    return lines.indices.filter { !removed.contains($0) }.map { lines[$0] } + recovered
  }

  static func coversOwners(_ owners: [CGRect], with replacements: [CGRect]) -> Bool {
    owners.allSatisfy { owner in
      let area = owner.width * owner.height
      guard area > 0 else { return false }
      let covered = replacements.reduce(CGFloat.zero) { total, replacement in
        let intersection = owner.intersection(replacement)
        return total + (intersection.isNull ? 0 : intersection.width * intersection.height)
      }
      return covered / area >= 0.65
    }
  }

  static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let intersection = a.intersection(b)
    let area = min(a.width * a.height, b.width * b.height)
    guard !intersection.isNull, area > 0 else { return 0 }
    return intersection.width * intersection.height / area
  }
}
