// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Overlay source appearance")
struct OverlaySourceAppearanceAnalyzerTests {

  // MARK: Internal

  @Test
  func findsLightBackgroundAndDarkForegroundAroundGlyphs() throws {
    let image = try makeImage(
      background: CGColor(gray: 0.94, alpha: 1),
      glyph: CGColor(gray: 0.04, alpha: 1)
    )
    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(patch.appearance.background.red > 0.85)
    #expect(patch.appearance.foreground.red < 0.1)
    #expect(patch.appearance.confidence > 0.5)
    #expect(analyzed.lines[0].horizontalInkScale > 0.45)
    #expect(analyzed.lines[0].horizontalInkScale < 0.6)
  }

  @Test
  func findsDarkBackgroundAndLightForegroundAroundGlyphs() throws {
    let image = try makeImage(
      background: CGColor(gray: 0.06, alpha: 1),
      glyph: CGColor(gray: 0.96, alpha: 1)
    )
    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(patch.appearance.background.red < 0.15)
    #expect(patch.appearance.foreground.red > 0.9)
    #expect(patch.appearance.confidence > 0.5)
  }

  @Test
  func preservesColoredSourceGlyphs() throws {
    let image = try makeImage(
      background: CGColor(gray: 0, alpha: 1),
      glyph: CGColor(red: 0.05, green: 0.52, blue: 1, alpha: 1)
    )
    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: image
    )
    let foreground = try #require(analyzed.lines.first?.appearance.foreground)

    #expect(foreground.blue > 0.9)
    #expect(foreground.green > foreground.red * 4)
  }

  @Test
  func shortColoredBulletDoesNotBecomeTheLineForeground() throws {
    let image = try makeRepositoryMetadataImage()
    let text = "• Swift"
    let bulletBox = CGRect(x: 0.10, y: 0.30, width: 0.08, height: 0.40)
    let wordBox = CGRect(x: 0.24, y: 0.30, width: 0.52, height: 0.40)
    let line = OCRResult.Line(
      boundingBoxNormalized: bulletBox.union(wordBox),
      text: text,
      replacementPatches: [
        OverlaySourcePatch(box: bulletBox),
        OverlaySourcePatch(box: wordBox),
      ],
      styleRuns: [
        OverlaySourceStyleRun(range: NSRange(location: 0, length: 1), box: bulletBox),
        OverlaySourceStyleRun(range: NSRange(location: 2, length: 5), box: wordBox),
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let result = try #require(analyzed.lines.first)

    #expect(result.appearance.foreground.red > result.appearance.foreground.blue * 0.8)
    #expect(result.appearance.foreground.red < 0.8)
    #expect(!result.styleRuns[0].appearance.isUnderlined)
  }

  @Test
  func thickerGlyphCoverageProducesHeavierWeight() throws {
    let thin = try makeImage(
      background: CGColor(gray: 0, alpha: 1),
      glyph: CGColor(gray: 1, alpha: 1),
      glyphWidth: 4
    )
    let thick = try makeImage(
      background: CGColor(gray: 0, alpha: 1),
      glyph: CGColor(gray: 1, alpha: 1),
      glyphWidth: 20
    )
    let thinAppearance = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: thin
    ).lines[0].appearance
    let thickAppearance = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: thick
    ).lines[0].appearance

    #expect(thinAppearance.fontWeight.rawValue < thickAppearance.fontWeight.rawValue)
    #expect(thinAppearance.inkCoverage < thickAppearance.inkCoverage)
  }

  @Test
  func consolidatesWordPatchesOnOneFlatBackground() throws {
    let image = try makeImage(background: CGColor(gray: 0.1, alpha: 1), glyph: nil)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4),
      text: "Two words",
      replacementPatches: [
        OverlaySourcePatch(box: CGRect(x: 0.22, y: 0.35, width: 0.2, height: 0.3)),
        OverlaySourcePatch(box: CGRect(x: 0.58, y: 0.35, width: 0.2, height: 0.3)),
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines[0].replacementPatches.count == 1)
    #expect(analyzed.lines[0].replacementPatches[0].box == line.boundingBoxNormalized)
  }

  @Test
  func keepsWordPatchesWhenAControlCrossesDifferentBackgrounds() throws {
    let image = try makeSplitBackgroundImage()
    let patches = [
      OverlaySourcePatch(box: CGRect(x: 0.12, y: 0.35, width: 0.22, height: 0.3)),
      OverlaySourcePatch(box: CGRect(x: 0.66, y: 0.35, width: 0.22, height: 0.3)),
    ]
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4),
      text: "Split control",
      replacementPatches: patches
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines[0].replacementPatches.count == 2)
  }

  @Test
  func samplesInlineCodeSurfaceInsideLongWordBox() throws {
    let image = try makeInlineCodeImage()
    let text = ".github/instructions/*.instructions.md"
    let source = CGRect(x: 0.25, y: 0.39, width: 0.5, height: 0.22)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: text,
      replacementPatches: [OverlaySourcePatch(box: source)],
      styleRuns: [
        OverlaySourceStyleRun(
          range: NSRange(location: 0, length: (text as NSString).length),
          box: source
        )
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let style = try #require(analyzed.lines.first?.styleRuns.first?.appearance)
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(style.background.red > 0.11)
    #expect(style.background.red < 0.2)
    #expect(patch.appearance.background == style.background)
    #expect(!patch.erasesDistinctSurface)
    #expect(style.fontDesign == .monospaced)
  }

  @Test
  func highContrastCompactFillIsBackgroundRatherThanUnderlineInk() throws {
    let image = try makeHighContrastInlineCodeImage()
    let text = "build 2.10.0"
    let source = CGRect(x: 0.2, y: 0.34, width: 0.6, height: 0.32)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: text,
      replacementPatches: [OverlaySourcePatch(box: source)],
      styleRuns: [
        OverlaySourceStyleRun(
          range: NSRange(location: 0, length: (text as NSString).length),
          box: source
        )
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let style = try #require(analyzed.lines.first?.styleRuns.first?.appearance)

    #expect(style.background.red > 0.8)
    #expect(style.foreground.red < 0.4)
    #expect(!style.isUnderlined)
  }

  @Test
  func embeddedInlineCodeErasesItsOldSurfaceToTheParentBackground() throws {
    let image = try makeInlineCodeImage()
    let code = ".github/instructions/*.instructions.md"
    let text = "Run \(code) now"
    let codeBox = CGRect(x: 0.25, y: 0.39, width: 0.5, height: 0.22)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.25, width: 0.9, height: 0.5),
      text: text,
      replacementPatches: [
        OverlaySourcePatch(box: CGRect(x: 0.05, y: 0.39, width: 0.15, height: 0.22)),
        OverlaySourcePatch(box: codeBox),
        OverlaySourcePatch(box: CGRect(x: 0.80, y: 0.39, width: 0.15, height: 0.22)),
      ],
      styleRuns: [
        OverlaySourceStyleRun(range: (text as NSString).range(of: code), box: codeBox)
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let analyzedLine = try #require(analyzed.lines.first)
    let erasers = analyzedLine.replacementPatches.filter(\.erasesDistinctSurface)
    let eraser = try #require(
      erasers.max {
        $0.box.width * $0.box.height < $1.box.width * $1.box.height
      }
    )

    #expect(eraser.appearance.background.red < 0.1)
    #expect(eraser.box.width > codeBox.width)
    #expect(eraser.box.height > codeBox.height)
  }

  @Test
  func separatelyRecognizedInlineCodeIsReclassifiedAfterRowCoalescing() throws {
    let image = try makeInlineCodeImage()
    let code = ".github/instructions/*.instructions.md"
    let leftBox = CGRect(x: 0.05, y: 0.39, width: 0.15, height: 0.22)
    let codeBox = CGRect(x: 0.25, y: 0.39, width: 0.5, height: 0.22)
    let rightBox = CGRect(x: 0.80, y: 0.39, width: 0.15, height: 0.22)
    let lines = [
      OCRResult.Line(
        boundingBoxNormalized: leftBox,
        text: "Run",
        replacementPatches: [OverlaySourcePatch(box: leftBox)],
        styleRuns: [OverlaySourceStyleRun(range: NSRange(location: 0, length: 3), box: leftBox)]
      ),
      OCRResult.Line(
        boundingBoxNormalized: codeBox,
        text: code,
        replacementPatches: [OverlaySourcePatch(box: codeBox)],
        styleRuns: [
          OverlaySourceStyleRun(
            range: NSRange(location: 0, length: (code as NSString).length),
            box: codeBox
          )
        ]
      ),
      OCRResult.Line(
        boundingBoxNormalized: rightBox,
        text: "now",
        replacementPatches: [OverlaySourcePatch(box: rightBox)],
        styleRuns: [OverlaySourceStyleRun(range: NSRange(location: 0, length: 3), box: rightBox)]
      ),
    ]

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: lines),
      from: image
    )
    let line = try #require(analyzed.lines.first)

    #expect(analyzed.lines.count == 1)
    #expect(line.text == "Run \(code) now")
    #expect(line.replacementPatches.contains { $0.erasesDistinctSurface })
    #expect(line.appearance.background.red < 0.1)
  }

  @Test
  func hyphenatedStandaloneBadgeKeepsItsOwnSurface() throws {
    let image = try makeStandaloneBadgeImage()
    let text = "On-device"
    let lineBox = CGRect(x: 0.31, y: 0.39, width: 0.38, height: 0.22)
    let line = OCRResult.Line(
      boundingBoxNormalized: lineBox,
      text: text,
      replacementPatches: [
        OverlaySourcePatch(box: CGRect(x: 0.33, y: 0.39, width: 0.08, height: 0.22)),
        OverlaySourcePatch(box: CGRect(x: 0.42, y: 0.39, width: 0.04, height: 0.22)),
        OverlaySourcePatch(box: CGRect(x: 0.47, y: 0.39, width: 0.20, height: 0.22)),
      ],
      styleRuns: [
        OverlaySourceStyleRun(range: NSRange(location: 0, length: 2), box: CGRect(x: 0.33, y: 0.39, width: 0.08, height: 0.22)),
        OverlaySourceStyleRun(range: NSRange(location: 2, length: 1), box: CGRect(x: 0.42, y: 0.39, width: 0.04, height: 0.22)),
        OverlaySourceStyleRun(range: NSRange(location: 3, length: 6), box: CGRect(x: 0.47, y: 0.39, width: 0.20, height: 0.22)),
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let analyzedLine = try #require(analyzed.lines.first)

    #expect(analyzedLine.replacementPatches.allSatisfy { !$0.erasesDistinctSurface })
    #expect(analyzedLine.replacementPatches.allSatisfy { $0.appearance.background.blue > 0.25 })
  }

  @Test
  func compactSurfaceIgnoresParentColorLeakingIntoOCRBox() throws {
    let image = try makeLeakingBadgeImage()
    let source = CGRect(x: 0.29, y: 0.38, width: 0.42, height: 0.32)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "High-fidelity",
      horizontalGlyphScale: source.height,
      replacementPatches: [OverlaySourcePatch(box: source)],
      styleRuns: [
        OverlaySourceStyleRun(
          range: NSRange(location: 0, length: ("High-fidelity" as NSString).length),
          box: source
        )
      ]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let analyzedLine = try #require(analyzed.lines.first)

    #expect(analyzedLine.surface != nil)
    #expect(analyzedLine.appearance.background.red > 0.85)
    #expect(analyzedLine.appearance.foreground.red > 0.3)
    #expect(analyzedLine.appearance.foreground.blue > 0.6)
    #expect(analyzedLine.horizontalInkScale > 0.05)
  }

  @Test
  func clampsSamplingAtImageEdges() throws {
    let image = try makeImage(
      background: CGColor(red: 0.18, green: 0.65, blue: 0.42, alpha: 1),
      glyph: nil
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.96, y: 0.96, width: 0.08, height: 0.08),
      text: "edge",
      replacementPatches: [OverlaySourcePatch(box: CGRect(x: 0.96, y: 0.96, width: 0.08, height: 0.08))]
    )
    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(patch.appearance.confidence > 0.9)
    #expect(patch.appearance.background.green > 0.55)
  }

  @Test
  func findsClosedFlatSurfaceAroundSourceText() throws {
    let image = try makeBubbleImage()
    let source = CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "Text",
      replacementPatches: [OverlaySourcePatch(box: source)]
    )
    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let surface = try #require(analyzed.lines.first?.surface)

    #expect(surface.confidence > 0.5)
    #expect(surface.box.width > 0.55)
    #expect(surface.box.width < 0.85)
    #expect(surface.box.contains(CGPoint(x: source.midX, y: source.midY)))
    let clippingBox = try #require(surface.clippingBox)
    #expect(clippingBox.contains(surface.box))
    #expect(clippingBox.width > surface.box.width)
    #expect(surface.cornerRadiusFraction == 0.35)
  }

  @Test
  func framedDocumentIsNotTreatedAsOneTextSurface() throws {
    let image = try makeFramedDocumentImage()
    let source = CGRect(x: 0.3, y: 0.04, width: 0.4, height: 0.08)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "Document title",
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines.first?.surface == nil)
  }

  @Test
  func extendsVerticalRestorationOnlyToNearbyMissedInk() throws {
    let image = try makeVerticalMissedGlyphImage()
    let source = CGRect(x: 0.44, y: 0.35, width: 0.12, height: 0.25)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "ています",
      isVerticalBlock: true,
      verticalCharScale: 0.12,
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)
    let surface = try #require(analyzed.lines.first?.surface)

    #expect(patch.box.minY < source.minY)
    #expect(patch.box.maxY > source.maxY)
    #expect(surface.box.contains(patch.box))
  }

  @Test
  func restoresChromaticRubyWithoutCrossingTheBorderAboveIt() throws {
    let image = try makeChromaticRubyImage()
    let source = CGRect(x: 0.25, y: 0.55, width: 0.5, height: 0.22)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "ナイフ型石器",
      horizontalGlyphScale: source.height,
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let patches = try #require(analyzed.lines.first?.replacementPatches)
    let ruby = try #require(patches.first { $0.box.minY < source.minY })

    #expect(ruby.box.minY > 0.44)
    #expect(ruby.box.maxY <= source.minY)
  }

  // MARK: Private

  private func sourceResult() -> OCRResult {
    let patch = CGRect(x: 0.32, y: 0.18, width: 0.36, height: 0.64)
    return OCRResult(lines: [
      OCRResult.Line(
        boundingBoxNormalized: patch,
        text: "Text",
        replacementPatches: [OverlaySourcePatch(box: patch)]
      )
    ])
  }

  private func makeImage(
    background: CGColor,
    glyph: CGColor?,
    glyphWidth: CGFloat = 12
  ) throws -> CGImage {
    let width = 100
    let height = 100
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(background)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let glyph {
      context.setFillColor(glyph)
      context.fill(CGRect(x: 50 - glyphWidth / 2, y: 24, width: glyphWidth, height: 52))
    }
    return try #require(context.makeImage())
  }

  private func makeBubbleImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 200,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fillEllipse(in: CGRect(x: 20, y: 12, width: 160, height: 176))
    context.setStrokeColor(CGColor(gray: 0.02, alpha: 1))
    context.setLineWidth(4)
    context.strokeEllipse(in: CGRect(x: 20, y: 12, width: 160, height: 176))
    context.setFillColor(CGColor(gray: 0.02, alpha: 1))
    context.fill(CGRect(x: 91, y: 58, width: 18, height: 84))
    return try #require(context.makeImage())
  }

  private func makeRepositoryMetadataImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.04, green: 0.06, blue: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    context.setFillColor(CGColor(red: 0.98, green: 0.30, blue: 0.22, alpha: 1))
    context.fillEllipse(in: CGRect(x: 22, y: 42, width: 12, height: 12))
    context.setFillColor(CGColor(red: 0.58, green: 0.60, blue: 0.64, alpha: 1))
    for x in stride(from: 52, through: 142, by: 18) {
      context.fill(CGRect(x: x, y: 34, width: 10, height: 32))
    }
    return try #require(context.makeImage())
  }

  private func makeFramedDocumentImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 200,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 200))
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 3, y: 3, width: 194, height: 194))
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 60, y: 174, width: 80, height: 10))
    return try #require(context.makeImage())
  }

  private func makeVerticalMissedGlyphImage() throws -> CGImage {
    let width = 200
    let height = 240
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fillEllipse(in: CGRect(x: 28, y: 16, width: 144, height: 208))
    context.setStrokeColor(CGColor(gray: 0.02, alpha: 1))
    context.setLineWidth(4)
    context.strokeEllipse(in: CGRect(x: 28, y: 16, width: 144, height: 208))
    context.setFillColor(CGColor(gray: 0.02, alpha: 1))
    context.fill(CGRect(x: 94, y: 96, width: 12, height: 48))
    context.fill(CGRect(x: 94, y: 70, width: 12, height: 16))
    context.fill(CGRect(x: 94, y: 154, width: 12, height: 16))
    return try #require(context.makeImage())
  }

  private func makeChromaticRubyImage() throws -> CGImage {
    let width = 200
    let height = 140
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: 0.2, alpha: 1))
    context.fill(CGRect(x: 48, y: 67, width: 104, height: 2))
    context.setFillColor(CGColor(red: 0.88, green: 0.40, blue: 0.20, alpha: 1))
    context.fill(CGRect(x: 58, y: 78, width: 84, height: 25))
    for x in stride(from: 72, through: 128, by: 14) {
      context.fill(CGRect(x: x, y: 72, width: 7, height: 4))
    }
    return try #require(context.makeImage())
  }

  private func makeSplitBackgroundImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 50, height: 100))
    context.setFillColor(CGColor(gray: 0.35, alpha: 1))
    context.fill(CGRect(x: 50, y: 0, width: 50, height: 100))
    return try #require(context.makeImage())
  }

  private func makeInlineCodeImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.04, green: 0.055, blue: 0.07, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    context.setFillColor(CGColor(red: 0.14, green: 0.16, blue: 0.19, alpha: 1))
    context.fill(CGRect(x: 38, y: 33, width: 124, height: 34))
    context.setFillColor(CGColor(gray: 0.92, alpha: 1))
    for x in stride(from: 52, through: 146, by: 8) {
      context.fill(CGRect(x: x, y: 41, width: 3, height: 18))
    }
    return try #require(context.makeImage())
  }

  private func makeStandaloneBadgeImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    context.setFillColor(CGColor(red: 0.58, green: 0.48, blue: 0.92, alpha: 1))
    context.fill(CGRect(x: 58, y: 33, width: 84, height: 34))
    context.setFillColor(CGColor(gray: 0.12, alpha: 1))
    for x in stride(from: 68, through: 128, by: 8) {
      context.fill(CGRect(x: x, y: 41, width: 3, height: 18))
    }
    return try #require(context.makeImage())
  }

  private func makeLeakingBadgeImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 240,
      height: 120,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.09, green: 0.095, blue: 0.11, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 120))
    context.setFillColor(CGColor(red: 0.93, green: 0.90, blue: 1, alpha: 1))
    context.addPath(CGPath(
      roundedRect: CGRect(x: 45, y: 42, width: 150, height: 36),
      cornerWidth: 18,
      cornerHeight: 18,
      transform: nil
    ))
    context.fillPath()
    context.setFillColor(CGColor(red: 0.45, green: 0.28, blue: 0.76, alpha: 1))
    for x in stride(from: 76, through: 164, by: 8) {
      context.fill(CGRect(x: x, y: 51, width: 4, height: 18))
    }
    return try #require(context.makeImage())
  }

  private func makeHighContrastInlineCodeImage() throws -> CGImage {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
    context.setFillColor(CGColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 40, y: 34, width: 120, height: 32))
    context.setFillColor(CGColor(red: 0.20, green: 0.22, blue: 0.26, alpha: 1))
    for x in stride(from: 54, through: 144, by: 9) {
      context.fill(CGRect(x: x, y: 42, width: 3, height: 16))
    }
    return try #require(context.makeImage())
  }
}
