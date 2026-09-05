// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CustomDump
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Printed dialogue regions")
struct OCRBalloonRefinerTests {

  // MARK: Internal

  @Test
  func joinsPrintedWrapsWithoutSplittingHyphenatedWords() {
    expectNoDifference(OCRBalloonRefiner.joinedRows(["A SUPER-", "ELASTIC SUIT", "FITS."]), "A SUPER-ELASTIC SUIT FITS.")
  }

  @Test
  func leavesOrdinaryProseAndVerticalTextOnDocumentPath() {
    let caps = (0..<12).map { _ in row("A COMPLETE PRINTED SENTENCE", x: 0.1, y: 0.1) }
    #expect(OCRBalloonRefiner.qualifies(caps))
    var prose = caps
    for i in prose.indices { prose[i].text = "A normal sentence in a web article." }
    #expect(!OCRBalloonRefiner.qualifies(prose))
    prose = caps
    prose[0].isVerticalBlock = true
    #expect(!OCRBalloonRefiner.qualifies(prose))
    #expect(!OCRBalloonRefiner.qualifies(Array(caps.prefix(4))))
  }

  @Test
  func reconstructedRegionsDoNotMergeAcrossNeighboringBalloons() {
    var first = row("THE FIRST COMPLETE SENTENCE.", x: 0.1, y: 0.2)
    first.isReconstructedTextRegion = true
    var second = row("THE SECOND COMPLETE SENTENCE.", x: 0.1, y: 0.26)
    second.isReconstructedTextRegion = true
    let source = OCRResult(lines: [first, second])
    expectNoDifference(source.coalescingParagraphFragments(), source)
  }

  @Test
  func findsSeparateInteriorsAcrossNarrowConnectors() throws {
    let image = try bubbles()
    let raster = try #require(BalloonRaster(image: image, longestSide: 1024))
    let lines = [0.28, 0.38, 0.48, 0.58].flatMap { y in
      [row("FIRST SENTENCE", x: 0.12, y: y), row("SECOND SENTENCE", x: 0.62, y: y)]
    }
    let regions = raster.textRegions(around: lines).sorted { $0.box.minX < $1.box.minX }
    expectNoDifference(regions.count, 2)
    guard regions.count == 2 else { return }
    #expect(!regions[0].interiorBox.intersects(regions[1].interiorBox))
    #expect(regions[0].contains(CGPoint(x: 0.2, y: 0.4)))
    #expect(!regions[0].contains(CGPoint(x: 0.7, y: 0.4)))
    #expect(raster.maskedCrop(of: image, region: regions[0]) != nil)
  }

  @Test
  func pageBackgroundIsNotATextContainer() throws {
    let context = try #require(CGContext(
      data: nil,
      width: 480,
      height: 200,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 480, height: 200))
    let image = try #require(context.makeImage())
    let raster = try #require(BalloonRaster(image: image, longestSide: 1024))
    let lines = [0.3, 0.4, 0.5].map { row("TEXT ON A PAGE", x: 0.2, y: $0) }
    #expect(raster.textRegions(around: lines).isEmpty)
  }

  @Test
  func textFitsInsideInteriorInsteadOfOverlappingAdjacentSourceBounds() throws {
    var recognized = row("A COMPLETE SENTENCE IN A BALLOON", x: 0.1, y: 0.2)
    recognized.rowCount = 4
    recognized.boundingBoxNormalized.size.height = 0.3
    recognized.isReconstructedTextRegion = true
    recognized.surface = OverlaySourceSurface(box: CGRect(x: 0.14, y: 0.23, width: 0.15, height: 0.22), confidence: 1)
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: Locale.Language(identifier: "en")))
    line.showTranslation("말풍선 안에 들어가는 완전한 문장입니다.", language: Locale.Language(identifier: "ko"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1000, height: 1000)).first)
    expectNoDifference(placement.frame, CGRect(x: 140, y: 230, width: 150, height: 220))
    expectNoDifference(placement.alignment, .center)
    #expect(placement.frame.maxX < placement.sourceFrame.maxX)
  }

  // MARK: Private

  private func row(_ text: String, x: CGFloat, y: CGFloat) -> OCRResult.Line {
    .init(boundingBoxNormalized: CGRect(x: x, y: y, width: 0.25, height: 0.05), text: text)
  }

  private func bubbles() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 480,
      height: 240,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.25, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 480, height: 240))
    context.setFillColor(CGColor(gray: 0.85, alpha: 1))
    context.fillEllipse(in: CGRect(x: 20, y: 35, width: 200, height: 160))
    context.fillEllipse(in: CGRect(x: 260, y: 35, width: 200, height: 160))
    context.fill(CGRect(x: 200, y: 110, width: 80, height: 4))
    // Dark enclosed glyph-like islands must not fragment the paper interior.
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    for x in [80, 120, 320, 360] { context.fill(CGRect(x: x, y: 95, width: 8, height: 12)) }
    return try #require(context.makeImage())
  }
}
