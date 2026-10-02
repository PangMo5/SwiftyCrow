// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Testing
@testable import SwiftyCrow

struct OCRGlyphRasterSupportTests {

  // MARK: Internal

  @Test(arguments: ["Arial", "Georgia", "Verdana", "Menlo", "Baskerville", "Hiragino Sans", "PingFang SC"], [12.0, 18.0, 24.0])
  func readableTextAcrossFontsAndScriptsIsNotRejected(_ family: String, _ size: Double) throws {
    let font = try #require(NSFont(name: family, size: size))
    for text in ["巴、", "i凸", "く", "相槌", "山", "정수", "Q", "RGB", "Д", "Ω", "é"] {
      let image = try render(text, font: font)
      let evidence = try #require(OCRGlyphRasterSupport.evidence(text: text, image: image, background: white))
      #expect(!OCRGlyphRasterSupport.contradicts(evidence), "\(family) \(size) \(text): \(evidence)")
    }
  }

  @Test(arguments: [12.0, 18.0, 24.0])
  func aDownwardChevronDoesNotOwnHiraganaPixels(_ size: Double) throws {
    let context = try bitmap(width: 80, height: 60)
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.setLineWidth(size / 8)
    context.move(to: CGPoint(x: 20, y: 35))
    context.addLine(to: CGPoint(x: 20 + size / 2, y: 35 - size / 2))
    context.addLine(to: CGPoint(x: 20 + size, y: 35))
    context.strokePath()
    let image = try #require(context.makeImage())
    let evidence = try #require(OCRGlyphRasterSupport.evidence(
      text: "く",
      image: image,
      background: white
    ))
    #expect(OCRGlyphRasterSupport.contradicts(evidence))
  }

  @Test
  func tableValuesAndVerticalTextRetainTheirIndependentOwnership() throws {
    let context = try bitmap(width: 100, height: 100)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 20, y: 20, width: 40, height: 3))
    var table = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8), text: "く")
    table.tableCell = .init(table: 0, row: 1, column: 1, box: table.boundingBoxNormalized)
    table.appearance.background = white
    var vertical = table
    vertical.tableCell = nil
    vertical.isVerticalBlock = true
    #expect(OCRGlyphRasterSupport.rejectingUnsupportedSymbols(
      .init(lines: [table, vertical]),
      image: try #require(context.makeImage())
    ).lines == [table, vertical])
  }

  // MARK: Private

  private var white: OverlayColor {
    .init(red: 1, green: 1, blue: 1, alpha: 1)
  }

  private func bitmap(width: Int, height: Int) throws -> CGContext {
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context
  }

  private func render(_ text: String, font: NSFont) throws -> CGImage {
    let line = CTLineCreateWithAttributedString(NSAttributedString(
      string: text,
      attributes: [.font: font, .foregroundColor: NSColor.black]
    ))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).integral
    let context = try bitmap(width: Int(bounds.width) + 8, height: Int(bounds.height) + 8)
    context.textPosition = CGPoint(x: 4 - bounds.minX, y: 4 - bounds.minY)
    CTLineDraw(line, context)
    return try #require(context.makeImage())
  }
}
