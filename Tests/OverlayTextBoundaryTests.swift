// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

struct OverlayTextBoundaryTests {
  @Test(arguments: ["plain", "control", "table", "whitespace", "rotated", "vertical"], [CGFloat(1), 2, 3])
  @MainActor
  func everyTargetRespectsItsOriginalTextBox(_ kind: String, _ scale: CGFloat) throws {
    let size = CGSize(width: 600 * scale, height: 400 * scale)
    let box = CGRect(x: 0.4, y: 0.3, width: 0.08, height: 0.05)
    var source = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Export",
      imageAspectRatio: 1.5,
      horizontalGlyphScale: 0.05,
      appearance: .init(
        background: .white,
        foreground: .init(
          red: 0.05,
          green: 0.3,
          blue: 0.8,
          alpha: 1
        ),
        confidence: 1,
        fontSizeScale: 0.04,
        fontWeight: .regular
      )
    )
    switch kind {
    case "control": source.surface = .init(box: CGRect(x: 0.375, y: 0.285, width: 0.14, height: 0.08), confidence: 1)

    case "table": source.tableCell = .init(
        table: 0,
        row: 0,
        column: 0,
        box: CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.2)
      )

    case "whitespace": source.layoutBounds = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8)

    case "rotated":
      source.rotationRadians = 0.2
      source.orientedBox = CGRect(x: 0.405, y: 0.3075, width: 0.07, height: 0.035)

    case "vertical": source.isVerticalBlock = true
      source.verticalCharScale = 0.03

    default: break
    }
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
    line.showTranslation("Umfangreiche Dokumente exportieren", language: .init(identifier: "de"))
    let placements = OverlayLayoutEngine.placements(for: [line], in: size)
    #expect(placements.count == 1)
    #expect(CaptureQualityMetrics.sourceBoundaryIssues(placements, canvas: size).isEmpty)
    let image = try #require(OverlayRasterRenderer.render(lines: [line], size: size, prefersHorizontalTextLayout: false))
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let copied = bytes.withUnsafeMutableBytes { storage -> Bool in
      guard
        let context = CGContext(
          data: storage.baseAddress,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      return true
    }
    #expect(copied)
    let boundary = CGRect(
      x: box.minX * size.width,
      y: box.minY * size.height,
      width: box.width * size.width,
      height: box.height * size.height
    ).integral
    var painted = 0
    var outside = 0
    for y in 0..<image.height { for x in 0..<image.width {
      let offset = (y * image.width + x) * 4
      if
        Int(bytes[offset + 2]) - Int(bytes[offset]) > 40,
        Int(bytes[offset + 2]) - Int(bytes[offset + 1]) > 20
      {
        painted += 1
        if !boundary.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { outside += 1 }
      }
    } }
    #expect(painted > 0)
    #expect(outside == 0)
  }

  @Test
  func clippingAtTheCaptureEdgeCannotMoveTheOriginalTextRegion() throws {
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: -0.01, y: 0.1, width: 0.1, height: 0.05),
      text: "Export",
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: 0.04,
        fontWeight: .regular
      )
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
    line.showTranslation("내보내기", language: .init(identifier: "ko"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 600, height: 400)).first)
    #expect(placement.frame.minX == 0)
    #expect(placement.frame.maxX <= 54)
  }
}
