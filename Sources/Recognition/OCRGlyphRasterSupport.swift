// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Synchronization

/// OCR confidence is not evidence that a region contains letters. Small symbol
/// hypotheses must also agree with readable glyph shapes before owning pixels.
enum OCRGlyphRasterSupport {

  // MARK: Internal

  struct Evidence: Sendable {
    var similarity: CGFloat
    var aspectRatio: CGFloat
  }

  static func evidence(text: String, image: CGImage, background: OverlayColor) -> Evidence? {
    guard
      (1...3).contains(text.count), text.contains(where: \.isLetter),
      let observed = feature(image, background: background)
    else { return nil }
    let references: [Feature]
    if let cached = cache.withLock({ $0[text] }) { references = cached }
    else {
      references = fonts.values.compactMap { reference(text: text, font: $0) }
      guard references.count == fonts.values.count else { return nil }
      cache.withLock { if $0.count >= 512 { $0.removeAll(keepingCapacity: true) }
        $0[text] = references
      }
    }
    let similarities = references.map { reference in
      zip(observed.values, reference.values).reduce(CGFloat.zero) { $0 + $1.0 * $1.1 }
    }
    let ratios = references.map { max(observed.aspect / $0.aspect, $0.aspect / observed.aspect) }
    return Evidence(similarity: similarities.max() ?? 0, aspectRatio: ratios.min() ?? 1)
  }

  static func contradicts(_ evidence: Evidence) -> Bool {
    evidence.similarity < 0.3 || (evidence.similarity < 0.7 && evidence.aspectRatio > 1.4)
  }

  static func rejectingUnsupportedSymbols(_ result: OCRResult, image: CGImage) -> OCRResult {
    let width = CGFloat(image.width)
    let height = CGFloat(image.height)
    return OCRResult(lines: result.lines.filter { line in
      guard
        !line.preservesSource, !line.isVerticalBlock, line.rowCount == 1,
        (1...3).contains(line.text.count), line.tableCell == nil,
        abs(line.rotationRadians) < 0.04, !OCRTextSemantics.isIdentifier(line.text),
        !OCRTextSemantics.isCode(line.text)
      else { return true }
      let box = CGRect(
        x: line.boundingBoxNormalized.minX * width,
        y: line.boundingBoxNormalized.minY * height,
        width: line.boundingBoxNormalized.width * width,
        height: line.boundingBoxNormalized.height * height
      )
      .insetBy(dx: -1, dy: -1).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
      guard
        let crop = image.cropping(to: box),
        let evidence = evidence(text: line.text, image: crop, background: line.appearance.background)
      else { return true }
      return !contradicts(evidence)
    })
  }

  // MARK: Private

  private struct Feature: Sendable { var values: [CGFloat]
    var aspect: CGFloat
  }

  private final class Fonts: @unchecked Sendable {
    let values = ["Arial", "Times New Roman", "Georgia", "Verdana", "Menlo", "Hiragino Sans", "PingFang SC"].map {
      CTFontCreateWithName($0 as CFString, 32, nil)
    }
  }

  private static let fonts = Fonts()
  private static let cache = Mutex<[String: [Feature]]>([:])

  private static func reference(text: String, font: CTFont) -> Feature? {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor.black]
    ))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).integral
    let width = Int(bounds.width) + 4
    let height = Int(bounds.height) + 4
    guard
      width > 4, height > 4, let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.textPosition = CGPoint(x: 2 - bounds.minX, y: 2 - bounds.minY)
    CTLineDraw(line, context)
    return context.makeImage().flatMap { feature($0, background: .init(red: 1, green: 1, blue: 1, alpha: 1)) }
  }

  private static func feature(_ image: CGImage, background: OverlayColor) -> Feature? {
    let width = image.width
    let height = image.height
    guard
      width > 2, height > 2, width <= 65_536 / height,
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let rgb = [background.red, background.green, background.blue]
    let contrast = (0..<width * height).map { index in
      (0..<3).map { abs(CGFloat(bytes[index * 4 + $0]) / 255 - rgb[$0]) }.max()!
    }
    guard let peak = contrast.max(), peak > 0.2 else { return nil }
    let points = contrast.indices.filter { contrast[$0] >= peak * 0.35 }
    guard
      let minX = points.map({ $0 % width }).min(), let maxX = points.map({ $0 % width }).max(),
      let minY = points.map({ $0 / width }).min(), let maxY = points.map({ $0 / width }).max()
    else { return nil }
    var values = [CGFloat](repeating: 0, count: 1024)
    for index in points {
      let x = min(31, (index % width - minX) * 31 / max(1, maxX - minX))
      let y = min(31, (index / width - minY) * 31 / max(1, maxY - minY))
      values[y * 32 + x] += contrast[index] / peak
    }
    var blurred = [CGFloat](repeating: 0, count: 1024)
    for y in 0..<32 { for x in 0..<32 { for dy in -1...1 { for dx in -1...1 {
      let nx = x + dx
      let ny = y + dy
      if nx >= 0, nx < 32, ny >= 0, ny < 32 {
        blurred[y * 32 + x] += values[ny * 32 + nx] * CGFloat((dx == 0 ? 2 : 1) * (dy == 0 ? 2 : 1)) / 16
      }
    } } } }
    let norm = sqrt(blurred.reduce(0) { $0 + $1 * $1 })
    guard norm > 0 else { return nil }
    return Feature(values: blurred.map { $0 / norm }, aspect: CGFloat(maxX - minX + 1) / CGFloat(maxY - minY + 1))
  }
}
