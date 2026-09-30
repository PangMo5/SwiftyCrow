// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

/// A visual wrap is not evidence of a word-space in Hangul. Re-read the same
/// glyphs in one strip; accept only boundary spacing, never changed characters.
enum OCRSoftWrapRefiner {

  // MARK: Internal

  static func refine(_ lines: [OCRResult.Line], image: CGImage) async throws -> [OCRResult.Line] {
    var result = lines
    let groups = Dictionary(
      grouping: lines.indices.filter { lines[$0].recognitionGroupID != nil && !lines[$0].isVerticalBlock },
      by: { lines[$0].recognitionGroupID! }
    )
    var requests = 0
    for id in groups.keys.sorted() {
      let indices = groups[id]!.sorted { lines[$0].boundingBoxNormalized.minY < lines[$1].boundingBoxNormalized.minY }
      let rows = indices.map { lines[$0] }
      guard
        (2...8).contains(rows.count), rows.allSatisfy({ row in
          abs(sin(row.rotationRadians)) * row.boundingBoxNormalized.width * CGFloat(image.width)
            <= max(2, row.boundingBoxNormalized.height * CGFloat(image.height) * 0.15)
        }),
        rows.map(\.text).joined().unicodeScalars.count(where: { (0xAC00...0xD7A3).contains($0.value) }) >= 12,
        zip(rows, rows.dropFirst()).contains(where: { a, b in
          a.followingSeparator == " " && hangul(a.text.last) && hangul(b.text.first)
        }),
        let strip = strip(rows, image: image)
      else { continue }
      try Task.checkCancellation()
      var request = RecognizeTextRequest()
      request.recognitionLevel = .accurate
      request.usesLanguageCorrection = true
      request.automaticallyDetectsLanguage = false
      request.recognitionLanguages = [Locale.Language(identifier: "ko")]
      try VisionTextRecognizer.configure(&request)
      let candidate = try await request.perform(on: strip).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
      if let separators = confirmedSeparators(candidate: candidate, rows: rows.map(\.text)) {
        for (offset, index) in indices.enumerated() where offset + 1 < indices.count {
          result[index].followingSeparator = separators[offset]
        }
      }
      requests += 1
      if requests == 4 { break }
    }
    return result
  }

  static func confirmedSeparators(candidate: String, rows: [String]) -> [String?]? {
    func letters(_ value: String) -> String {
      String(value.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace }.reversed()
        .drop(while: { $0.unicodeScalars.allSatisfy(CharacterSet.punctuationCharacters.contains) }).reversed())
    }
    guard !candidate.isEmpty, letters(candidate) == letters(rows.joined()) else { return nil }
    let separators = OCRParagraphLineGrouping.separators(paragraphTranscript: candidate, lineTranscripts: rows)
    guard separators.dropLast().allSatisfy({ $0 != nil }) else { return nil }
    return separators
  }

  // MARK: Private

  private static func hangul(_ char: Character?) -> Bool {
    char.map { $0.unicodeScalars.allSatisfy { (0xAC00...0xD7A3).contains($0.value) } } ?? false
  }

  private static func strip(_ rows: [OCRResult.Line], image: CGImage) -> CGImage? {
    let boxes = rows.map { row in
      let b = row.boundingBoxNormalized
      return CGRect(
        x: b.minX * CGFloat(image.width),
        y: b.minY * CGFloat(image.height),
        width: b.width * CGFloat(image.width),
        height: b.height * CGFloat(image.height)
      )
    }
    guard let first = boxes.first, boxes.allSatisfy({ abs($0.minX - first.minX) < first.height * 0.5 }) else { return nil }
    var crops = [CGImage]()
    var background: CGColor?
    for (i, box) in boxes.enumerated() {
      var rect = box
      if i + 1 < boxes.count { rect.size.height = min(rect.height, (box.midY + boxes[i + 1].midY) / 2 - rect.minY) }
      if i > 0 { let top = max(rect.minY, (box.midY + boxes[i - 1].midY) / 2)
        rect.size.height = rect.maxY - top
        rect.origin.y = top
      }
      guard
        let crop = image.cropping(to: rect.integral),
        let ctx = CGContext(
          data: nil,
          width: crop.width,
          height: crop.height,
          bitsPerComponent: 8,
          bytesPerRow: crop.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return nil }
      ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      guard let pixels = ctx.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
      let bg = (0..<3).map { Int(pixels[$0]) }
      if background == nil { background = CGColor(
        red: CGFloat(bg[0]) / 255,
        green: CGFloat(bg[1]) / 255,
        blue: CGFloat(bg[2]) / 255,
        alpha: 1
      ) }
      var left = crop.width
      var right = -1
      for x in 0..<crop.width { for y in 0..<crop.height {
        let offset = (y * crop.width + x) * 4
        if (0..<3).reduce(0, { $0 + abs(Int(pixels[offset + $1]) - bg[$1]) }) > 102 { left = min(left, x)
          right = max(right, x)
        }
      }}
      guard
        right >= left,
        let trimmed = crop.cropping(to: CGRect(x: left, y: 0, width: right - left + 1, height: crop.height))
      else { return nil }
      crops.append(trimmed)
    }
    let width = crops.reduce(8) { $0 + $1.width + 2 }
    let height = (crops.map(\.height).max() ?? 0) + 8
    guard width <= 3600, height <= 180 else { return nil }
    let scale = min(2.0, Double(4096) / Double(width))
    guard
      let ctx = CGContext(
        data: nil,
        width: Int(Double(width) * scale),
        height: Int(Double(height) * scale),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    ctx.setFillColor(background!)
    ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
    ctx.scaleBy(x: scale, y: scale)
    var x = 4
    for crop in crops { ctx.draw(crop, in: CGRect(x: x, y: 4, width: crop.width, height: crop.height))
      x += crop.width + 2
    }
    return ctx.makeImage()
  }
}
