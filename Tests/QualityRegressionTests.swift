// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CustomDump
import Foundation
import ImageIO
import Testing
@testable import SwiftyCrow

@Suite("Quality audit regressions")
struct QualityRegressionTests {
  @Test
  func ordinaryJapaneseInkDoesNotTriggerRubyCropping() {
    #expect(JapaneseRubyOCRCorrector.baseBandStart(rowInk: Array(repeating: 20, count: 36)) == nil)
    #expect(JapaneseRubyOCRCorrector.baseBandStart(rowInk: [0, 0, 10, 10, 0, 0] + Array(repeating: 20, count: 30)) == nil)
  }

  @Test
  func separateSmallRubyBandHasAnObservedCropBoundary() {
    let rows = Array(repeating: 5, count: 8) + Array(repeating: 0, count: 5) + Array(repeating: 20, count: 27)
    expectNoDifference(JapaneseRubyOCRCorrector.baseBandStart(rowInk: rows), 0.3)
  }

  @Test(arguments: [
    "export API_URL=https://example.org",
    "swift test --filter CaptureFeatureTests",
    "let timeout: Double = 0.8",
    "if result.isEmpty { return nil ›",
    "return nil"
  ])
  func codeIsProtectedWithoutRelyingOnFontSampling(_ text: String) {
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text),
      language: Locale.Language(identifier: "en")
    )
    #expect(source.isProtectedLiteral)
  }

  @Test(arguments: ["https://example.org/docs", "MIT", "AGPL-3.0-only", "v3.2.1"])
  func technicalIdentifiersRemainLiteral(_ text: String) {
    #expect(OCRTextSemantics.isIdentifier(text))
  }

  @Test
  func ordinaryEnglishInstructionsAreNotCode() {
    #expect(!OCRTextSemantics.isCode("If the address is incorrect, the package will not be delivered."))
    #expect(!OCRTextSemantics.isCode("Export the review to your coding agent."))
  }

  @Test
  func codeRowsAreNeverStitchedIntoAProseParagraph() {
    let result = OCRResult(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.03), text: "let x = 1", recognitionGroupID: 1),
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.24, width: 0.5, height: 0.03), text: "let y = 2", recognitionGroupID: 1),
    ])
    expectNoDifference(result.coalescingParagraphFragments(), result)
  }

  @Test
  func labelUsesOneExplicitTechnicalValueAsContext() {
    let sources = [
      OverlayLine.Source(
        recognized: .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03), text: "release"),
        language: Locale.Language(identifier: "en")
      ),
      OverlayLine.Source(
        recognized: .init(boundingBoxNormalized: CGRect(x: 0.22, y: 0.2, width: 0.1, height: 0.03), text: "v3.2.1"),
        language: Locale.Language(identifier: "en")
      ),
    ]
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    expectNoDifference(OverlayTranslationPolicy.trailingContext(at: 0, in: sources), "v3.2.1")
  }

  @Test
  func verticalGeometryOverridesMisleadingDirectionMetadata() {
    #expect(OCRGeometry.isVertical(
      text: "電車は午後三時に出発します",
      topLeft: CGPoint(x: 0.8, y: 0.9),
      topRight: CGPoint(x: 0.8, y: 0.2),
      imageSize: CGSize(width: 1200, height: 720),
      declaredVertical: false
    ))
    #expect(!OCRGeometry.isVertical(
      text: "A rotated English caption",
      topLeft: CGPoint(x: 0.8, y: 0.9),
      topRight: CGPoint(x: 0.8, y: 0.2),
      imageSize: CGSize(width: 1200, height: 720),
      declaredVertical: false
    ))
  }

  @Test
  func rotatedRowsJoinInTheirAlignedPlane() {
    let angle: CGFloat = 0.07
    let a = CGRect(x: 0.1, y: 0.2, width: 0.65, height: 0.04)
    let b = CGRect(x: 0.102, y: 0.25, width: 0.12, height: 0.04)
    func world(_ rect: CGRect) -> CGRect {
      let x = rect.midX
      let y = rect.midY
      return CGRect(
        x: x * cos(angle) - y * sin(angle) - rect.width / 2,
        y: x * sin(angle) + y * cos(angle) - rect.height / 2,
        width: rect.width,
        height: rect.height
      )
    }
    let result = OCRResult(lines: [
      .init(
        boundingBoxNormalized: world(a),
        text: "The deadline is Friday",
        rotationRadians: angle,
        orientedBox: world(a),
        recognitionGroupID: 1
      ),
      .init(
        boundingBoxNormalized: world(b),
        text: "at noon.",
        rotationRadians: angle,
        orientedBox: world(b),
        recognitionGroupID: 1
      ),
    ]).coalescingParagraphFragments()
    expectNoDifference(result.lines.count, 1)
    expectNoDifference(result.lines.first?.text, "The deadline is Friday at noon.")
    expectNoDifference(result.lines.first?.rotationRadians, angle)
  }

  @Test
  func modelChoiceUsesInstalledModelsAndPreservesAnAvailablePreference() {
    expectNoDifference(
      TranslationModelResolver.choose(preferred: .lowLatency, preferredInstalled: true, alternativeInstalled: true),
      .lowLatency
    )
    expectNoDifference(
      TranslationModelResolver.choose(preferred: .lowLatency, preferredInstalled: false, alternativeInstalled: true),
      .highFidelity
    )
    #expect(TranslationModelResolver
      .choose(preferred: .highFidelity, preferredInstalled: false, alternativeInstalled: false) == nil)
  }

  @Test
  func latinCaptionDoesNotInheritArabicPageLanguage() {
    let client = LanguageDetectionClient(detect: { text, confidence in
      if text == "Platform 4 Departure 15:30" { return confidence > 0 ? nil : Language(code: "en") }
      return Language(code: "ar")
    })
    expectNoDifference(
      client.resolveSources(for: ["يرجى إغلاق الباب", "Platform 4 Departure 15:30"], configured: .auto),
      [Language(code: "ar"), Language(code: "en")]
    )
  }

  @Test
  func maskBoundsReachInkOutsideTheOCRBox() throws {
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 60,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 60))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 30, y: 20, width: 6, height: 20))
    let image = try #require(context.makeImage())
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.3, y: 22.0 / 60, width: 0.06, height: 16.0 / 60), appearance: appearance)
    let result = SourceRestorationBuilder.applying(
      to: OCRResult(lines: [.init(
        boundingBoxNormalized: patch.box,
        text: "Sample",
        appearance: appearance,
        replacementPatches: [patch]
      )]),
      image: image
    )
    let restored = try #require(result.lines.first?.replacementPatches.first)
    #expect(restored.box.minY <= 20.0 / 60)
    #expect(restored.box.maxY >= 40.0 / 60)
  }

  @Test
  func mixedScriptHypothesesKeepEachReliableScriptAndIndependentGeometry() throws {
    let raw = "Open／閉じる／71"
    let spans = [(0, 4), (4, 1), (5, 3), (8, 1), (9, 2)]
    let runs = spans.enumerated().map { i, range in
      OverlaySourceStyleRun(
        range: NSRange(location: range.0, length: range.1),
        box: CGRect(x: CGFloat(i) * 0.15, y: 0.2, width: 0.1, height: 0.04)
      )
    }
    let original = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0.2, width: 0.8, height: 0.04),
      text: raw,
      styleRuns: runs
    )
    let result = try #require(OCRLineRefiner.splitMixedLine(original, hypothesis: "Open / EL 3 / 닫기"))
    expectNoDifference(result.map(\.text), ["Open", "／", "閉じる", "／", "닫기"])
    #expect(result.last!.needsReview)
    expectNoDifference(OCRResult(lines: result).coalescingParagraphFragments().lines, result)
  }

  @Test
  func eraserExclusionsProtectSeparatorsAndPendingNeighbors() {
    let slash = OverlayLine(
      id: UUID(),
      source: .init(
        recognized: .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.3, width: 0.02, height: 0.05), text: "/"),
        language: Locale.Language(identifier: "en")
      )
    )
    let frames = OverlayLayoutEngine.protectedSourceFrames(for: [slash], in: CGSize(width: 1000, height: 500), displayScale: 2)
    expectNoDifference(frames, [CGRect(x: 199.5, y: 149.5, width: 21, height: 26)])
  }

  @Test
  func absorbingRubyKeepsTheOriginalBaseTextFrame() throws {
    let baseBox = CGRect(x: 0.1, y: 0.247, width: 0.6, height: 0.05)
    let result = OCRResult(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.06, height: 0.02), text: "しゅうごう"),
      .init(boundingBoxNormalized: baseBox, text: "集合時間は九時です。"),
    ]).absorbingRubyAnnotations()
    expectNoDifference(result.lines.count, 1)
    let line = try #require(result.lines.first)
    expectNoDifference(line.orientedBox, baseBox)
    #expect(line.replacementPatches.contains { $0.box == baseBox })
  }

  @Test
  func aShortWrappedContinuationKeepsItsSentenceContext() {
    let upper = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 0.8,
      fontWeight: .semibold
    )
    var lower = upper
    lower.foregroundConfidence = 0.3
    lower.fontWeight = .regular
    let result = OCRResult(lines: [
      .init(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04),
        text: "Last entry is at four thirty. The building closes",
        recognitionGroupID: 1,
        appearance: upper
      ),
      .init(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.245, width: 0.12, height: 0.04),
        text: "at five.",
        recognitionGroupID: 2,
        appearance: lower
      ),
    ]).coalescingParagraphFragments()
    expectNoDifference(result.lines.map(\.text), ["Last entry is at four thirty. The building closes at five."])
  }

  @Test
  func nonLatinLabelsAreNotVersionLiterals() {
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: "予約番号：AB-2048"),
      language: Locale.Language(identifier: "ja")
    )
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: [source]))
  }

  @Test
  func textureRestorationRetainsMultipleBackgroundColors() throws {
    let context = try #require(CGContext(
      data: nil,
      width: 180,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    for x in stride(from: 0, to: 180, by: 30) {
      let shade = CGFloat((x / 30) % 3) * 0.12 + 0.15
      context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
      context.fill(CGRect(x: x, y: 0, width: 30, height: 80))
    }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 75, y: 30, width: 8, height: 20))
    let image = try #require(context.makeImage())
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.27, green: 0.27, blue: 0.27, alpha: 1),
      foreground: .white,
      confidence: 1
    )
    let box = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Read this message",
      appearance: appearance,
      replacementPatches: [OverlaySourcePatch(box: box, appearance: appearance)]
    )
    let result = SourceRestorationBuilder.applying(to: OCRResult(lines: [line]), image: image)
    let data = try #require(result.lines.first?.replacementPatches.first?.restorationPNG)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let tile = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    #expect(tile.width > 100)
    expectNoDifference(result.lines[0].text, line.text)
  }

  @Test
  func clippedCaptureRetainsItsSourceOriginInsteadOfStretching() throws {
    let geometry = try ScreenCaptureRegionGeometry(
      requested: CGRect(x: -50, y: 750, width: 400, height: 200),
      display: CGRect(x: 0, y: 0, width: 1440, height: 900)
    )
    expectNoDifference(geometry.intersection, CGRect(x: 0, y: 750, width: 350, height: 150))
    expectNoDifference(geometry.sourceRect, CGRect(x: 0, y: 0, width: 350, height: 150))
    #expect(throws: ScreenCaptureError.emptyRegion) {
      try ScreenCaptureRegionGeometry(
        requested: CGRect(x: -500, y: 0, width: 100, height: 100),
        display: CGRect(x: 0, y: 0, width: 1440, height: 900)
      )
    }
  }

  @Test @MainActor
  func questionableOCRIsFlaggedWithoutChangingItsWords() {
    let text = "The fomerw twory arbe qzxq request cannot be sent."
    let result = OCRQualityAssessment.markingUncertainText(in: OCRResult(lines: [.init(
      boundingBoxNormalized: .zero,
      text: text
    )]))
    expectNoDifference(result.lines[0].text, text)
    #expect(result.lines[0].needsReview)
  }
}
