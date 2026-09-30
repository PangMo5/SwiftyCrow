// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Observed text surface polarity")
struct SourceAppearancePolarityTests {

  // MARK: Internal

  @Test
  func citationBracketsDoNotChangeTheParagraphToAMonospacedFont() async throws {
    let context = try makeContext(width: 400, height: 80)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 80))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    for x in stride(from: 12, to: 380, by: 14) { context.fill(CGRect(x: x, y: 30, width: 7, height: 20)) }
    let text = "Eine gewöhnliche Beschreibung mit Quellenangabe.[1.2]"
    let box = CGRect(x: 0.02, y: 0.3, width: 0.94, height: 0.4)
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: .init(lines: [
      .init(
        boundingBoxNormalized: box,
        text: text,
        styleRuns: [.init(range: NSRange(location: 0, length: text.utf16.count), box: box)]
      )
    ]), from: try #require(context.makeImage()))
    #expect(result.lines.first?.appearance.fontDesign == .standard)
  }

  @Test
  func aSingleCJKLexicalRunRetainsItsInternalLinkColor() async throws {
    let context = try makeContext(width: 240, height: 80)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 80))
    for index in 0..<6 {
      context.setFillColor((2...3).contains(index)
        ? CGColor(red: 0.15, green: 0.35, blue: 0.8, alpha: 1)
        : CGColor(gray: 0.1, alpha: 1))
      context.fill(CGRect(x: 12 + index * 35, y: 29, width: 23, height: 22))
    }
    let text = "文章链接正文"
    let anchors = (0..<6).map { OCRTextAnchor(
      range: NSRange(location: $0, length: 1),
      box: CGRect(x: Double(10 + $0 * 35) / 240, y: 0.3, width: 27.0 / 240, height: 0.4)
    ) }
    let box = anchors.dropFirst().reduce(anchors[0].box) { $0.union($1.box) }
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      styleRuns: [.init(range: NSRange(location: 0, length: 6), box: box)],
      spacingAnchors: anchors
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: try #require(context.makeImage())
    )
    let actual = try #require(result.lines.first)
    let blue = actual.styleRuns.filter { $0.appearance.foreground.blue - $0.appearance.foreground.red > 0.3 }
    #expect(blue.map { (text as NSString).substring(with: $0.range) }.joined() == "链接")
    #expect(actual.appearance.foreground.blue - actual.appearance.foreground.red < 0.15)
  }

  @Test
  func paddedHeadingRangeDoesNotEnlargeItsBracketedEditControl() async throws {
    let context = try makeContext(width: 240, height: 100)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 100))
    context.setFillColor(CGColor(gray: 0.1, alpha: 1))
    context.fill(CGRect(x: 20, y: 34, width: 70, height: 32))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    for x in [110, 120, 132, 147] { context.fill(CGRect(x: x, y: 44, width: 7, height: 12)) }
    let runs = [(0, 2, 18.0, 74.0), (2, 1, 108.0, 10.0), (3, 2, 119.0, 24.0), (5, 1, 145.0, 12.0)].map {
      OverlaySourceStyleRun(
        range: NSRange(location: $0.0, length: $0.1),
        box: CGRect(x: $0.2 / 240, y: 0.3, width: $0.3 / 240, height: 0.4)
      )
    }
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.07, y: 0.3, width: 0.6, height: 0.4),
      text: "标题〔编辑〕",
      styleRuns: runs
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [source]),
      from: try #require(context.makeImage())
    )
    #expect(result.lines.map(\.text) == ["标题", "〔编辑〕"])
    let heading = try #require(result.lines.first)
    let accessory = try #require(result.lines.last)
    #expect(accessory.boundingBoxNormalized.height < heading.boundingBoxNormalized.height * 0.6)
    #expect(accessory.horizontalInkScale < heading.horizontalInkScale * 0.6)
  }

  @Test
  func aGradientFillIsOneSurfaceAcrossHistogramBuckets() async throws {
    let context = try makeContext(width: 160, height: 160)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 160, height: 160))
    // Small channel variations cross quantization boundaries without becoming
    // separate surfaces. White letter strokes sit on this colored fill.
    for y in 20..<140 {
      let green = CGFloat(145 + y % 27) / 255
      let blue = CGFloat(103 + y % 13) / 255
      context.setFillColor(CGColor(red: 0.97, green: green, blue: blue, alpha: 1))
      context.fill(CGRect(x: 60, y: y, width: 40, height: 1))
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for y in stride(from: 35, to: 120, by: 28) {
      context.fill(CGRect(x: 64, y: y, width: 32, height: 5))
      context.fill(CGRect(x: 76, y: y - 7, width: 5, height: 20))
    }
    let box = CGRect(x: 62.0 / 160, y: 30.0 / 160, width: 36.0 / 160, height: 100.0 / 160)
    let rubyBox = CGRect(x: 108.0 / 160, y: 45.0 / 160, width: 8.0 / 160, height: 30.0 / 160)
    let line = OCRResult.Line(
      boundingBoxNormalized: box.union(rubyBox),
      text: "表示",
      orientedBox: box,
      isVerticalBlock: true,
      replacementPatches: [.init(box: box), .init(box: rubyBox)],
      styleRuns: [.init(range: NSRange(location: 0, length: 2), box: box)]
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: try #require(context.makeImage())
    )
    let appearance = try #require(result.lines.first?.appearance)
    #expect(appearance.background.red > 0.85)
    #expect(appearance.background.blue < 0.6)
    #expect(appearance.foreground.blue > 0.85)
    let surface = try #require(result.lines.first?.surface)
    #expect(SourcePatchClipping.surface(for: .init(box: box), within: surface) != nil)
    #expect(SourcePatchClipping.surface(for: .init(box: rubyBox), within: surface) == nil)
    let paperPatch = try #require(result.lines.first?.replacementPatches.first { $0.box.intersects(rubyBox) })
    #expect(paperPatch.appearance.background.red > 0.95)
    #expect(paperPatch.appearance.background.blue > 0.95)
  }

  @Test
  func nearbyArtworkDoesNotInvertTheTextSurface() async throws {
    let context = try makeContext(width: 220, height: 120)
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 220, height: 120))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 45, y: 40, width: 130, height: 40))
    context.setFillColor(CGColor(red: 0.97, green: 0.6, blue: 0.42, alpha: 1))
    context.fill(CGRect(x: 45, y: 70, width: 130, height: 10))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 45, y: 40, width: 130, height: 10))
    for x in stride(from: 65, to: 150, by: 30) {
      context.fill(CGRect(x: x, y: 54, width: 7, height: 12))
    }
    let box = CGRect(x: 60.0 / 220, y: 40.0 / 120, width: 100.0 / 220, height: 40.0 / 120)
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: .init(lines: [
      .init(boundingBoxNormalized: box, text: "Read!", replacementPatches: [.init(box: box)])
    ]), from: try #require(context.makeImage()))
    let appearance = try #require(result.lines.first?.appearance)
    #expect(appearance.background.red > 0.85)
    #expect(appearance.foreground.red < 0.15)
  }

  // MARK: Private

  private func makeContext(width: Int, height: Int) throws -> CGContext {
    try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
  }
}
