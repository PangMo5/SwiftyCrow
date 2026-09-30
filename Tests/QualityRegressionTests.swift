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
  @Test(arguments: ["こんにちは�世界", "안녕하세요�세계", "مرحبا�بالعالم", "שלום�עולם", "Bonjour�monde"])
  @MainActor
  func undecodableSourceTextIsFlaggedWithoutAnEnglishDictionary(_ text: String) {
    let result = OCRQualityAssessment.markingUncertainText(in: .init(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1), text: text)
    ]))
    #expect(result.lines[0].needsReview)
    #expect(result.lines[0].preservesSource)
  }

  @Test
  func restorationRemovesEverySourceTextColorOnOneSurface() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 200,
      height: 60,
      bitsPerComponent: 8,
      bytesPerRow: 800,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 60))
    context.setFillColor(CGColor(gray: 0.95, alpha: 1))
    context.fill(CGRect(x: 25, y: 20, width: 35, height: 18))
    context.setFillColor(CGColor(red: 0.05, green: 0.5, blue: 1, alpha: 1))
    context.fill(CGRect(x: 85, y: 20, width: 70, height: 18))
    let white = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    var blue = white
    blue.foreground = OverlayColor(red: 0.05, green: 0.5, blue: 1, alpha: 1)
    let box = CGRect(x: 0.1, y: 0.3, width: 0.7, height: 0.4)
    let source = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Apps 作者 رابط",
      appearance: white,
      replacementPatches: [.init(box: box, appearance: white)],
      styleRuns: [.init(
        range: NSRange(location: 5, length: 8),
        box: CGRect(x: 0.4, y: 0.3, width: 0.4, height: 0.4),
        appearance: blue
      )],
      surface: .init(box: box, confidence: 1)
    )
    let result = await SourceRestorationBuilder.applying(to: .init(lines: [source]), image: try #require(context.makeImage()))
    let png = try #require(result.lines[0].replacementPatches.first?.restorationPNG)
    let imageSource = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
    let rendered = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    rendered.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(rendered.data).assumingMemoryBound(to: UInt8.self)
    #expect((0..<image.width * image.height).allSatisfy { Int(pixels[$0 * 4 + 2]) - Int(pixels[$0 * 4]) < 80 })
  }

  @Test
  func malformedModelOutputIsNotRenderedAsTranslation() {
    #expect(!TranslationTextStructure.isUsableResponse("... 담요에서만 ��어���다..."))
    #expect(!TranslationTextStructure.isUsableResponse(" \n "))
    #expect(TranslationTextStructure.isUsableResponse("총알은 담요에 맞고 튕겨 나갔습니다."))
    #expect(TranslationTextStructure.isUsableResponse("Symbols: ✓ → ★"))
  }

  @Test
  @MainActor
  func romanizedTermsInMixedScriptProseRemainTranslatable() {
    let text = "The tsuchi changes to zuchi as an instance of rendaku （連濁）."
    let result = OCRQualityAssessment.markingUncertainText(in: .init(lines: [
      .init(boundingBoxNormalized: .zero, text: text, recognitionConfidence: 0.42)
    ]), language: Language(code: "en"))
    #expect(result.lines[0].text == text)
    #expect(!result.lines[0].preservesSource)
  }

  @Test
  @MainActor
  func spellingUncertaintyDoesNotSilentlySuppressProseTranslation() {
    let text = "Chiden under six travel tree. A tickch cannot be exchanged char exparture."
    let result = OCRQualityAssessment.markingUncertainText(in: OCRResult(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.1), text: text, recognitionConfidence: 0.43),
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.1), text: text, recognitionConfidence: 0.95),
    ]), language: Language(code: "en"))
    #expect(result.lines[0].needsReview)
    #expect(!result.lines[0].preservesSource)
    #expect(!result.lines[1].preservesSource)
  }

  @Test
  @MainActor
  func uncertainLabelRetainsReviewHintWithoutChangingItsTranslationOwnership() {
    let result = OCRQualityAssessment.markingUncertainText(in: OCRResult(lines: [
      .init(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1),
        text: "More nolitics coverade",
        recognitionConfidence: 0.49
      ),
      .init(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.3, width: 0.5, height: 0.1),
        text: "More politics coverage",
        recognitionConfidence: 0.9
      ),
    ]), language: Language(code: "en"))
    #expect(result.lines[0].needsReview)
    #expect(!result.lines[0].preservesSource)
    #expect(!result.lines[1].preservesSource)
  }

  @Test
  func resampledGlyphFringesDoNotBecomeBackgroundTexture() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 180,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 180, height: 80))
    for x in stride(from: 28, to: 155, by: 16) {
      // Two gray edge pixels simulate enlarged, antialiased black glyphs.
      context.setFillColor(CGColor(gray: 0.75, alpha: 1))
      context.fill(CGRect(x: x - 2, y: 22, width: 12, height: 36))
      context.setFillColor(CGColor(gray: 0.02, alpha: 1))
      context.fill(CGRect(x: x, y: 24, width: 8, height: 32))
    }
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1),
      foreground: OverlayColor(red: 0.02, green: 0.02, blue: 0.02, alpha: 1),
      confidence: 1
    )
    let box = CGRect(x: 20.0 / 180, y: 0.25, width: 140.0 / 180, height: 0.5)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "We still have time.",
      appearance: appearance,
      replacementPatches: [OverlaySourcePatch(box: box, appearance: appearance)]
    )
    let result = await SourceRestorationBuilder.applying(
      to: OCRResult(lines: [line]),
      image: try #require(context.makeImage())
    )
    let patch = try #require(result.lines.first?.replacementPatches.first)
    #expect(patch.restorationPNG == nil)
    expectNoDifference(patch.appearance.background, appearance.background)
    expectNoDifference(result.lines.first?.text, line.text)
  }

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

  @Test(arguments: ["①", "❷", "Ⅳ", "²", "½", "١٢"])
  func numericSymbolsKeepTheirOriginalVisualForm(_ text: String) {
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text),
      language: Locale.Language(identifier: "ja")
    )
    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: [source]))
  }

  @Test(arguments: ["① Important", "四人", "一番", "One person"])
  func numericSymbolsDoNotProtectSurroundingProse(_ text: String) {
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text),
      language: Locale.Language(identifier: "ja")
    )
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: [source]))
  }

  @Test
  func metadataAndTranslationContextStayWithinTheirDocument() {
    var label = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.03), text: "release")
    label.recognitionContextID = 0
    var value = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.22, y: 0.2, width: 0.1, height: 0.03), text: "v3.2.1")
    value.recognitionContextID = 1
    let sources = [label, value].map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "en")) }
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: sources) == nil)
  }

  @Test
  func aVerticalTitleDoesNotShareAVisualRowWithEveryOverlappingLabel() {
    let title = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.8, y: 0.1, width: 0.05, height: 0.7),
      text: "縦書きの題名",
      isVerticalBlock: true,
      verticalCharScale: 0.04
    )
    let peers = ["API", "Label", "Other"].enumerated().map { index, text in
      OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.2, y: 0.2 + Double(index) * 0.15, width: 0.1, height: 0.03), text: text)
    }
    let sources = ([title] + peers).map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "ja")) }
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: sources) == nil)
  }

  @Test
  func aVerticalLiteralDoesNotSupplyContextToAnAdjacentHorizontalLabel() {
    let label = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.03), text: "release")
    let value = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.32, y: 0.1, width: 0.03, height: 0.7),
      text: "v3.2.1",
      isVerticalBlock: true
    )
    let sources = [label, value].map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "en")) }
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: sources) == nil)
  }

  @Test
  func aWrappedHorizontalLabelKeepsItsTrailingValueContext() {
    let label = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.08),
      text: "release",
      rowCount: 2
    )
    let value = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.32, y: 0.22, width: 0.1, height: 0.03), text: "v3.2.1")
    let sources = [label, value].map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "en")) }
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: sources) == "v3.2.1")
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
  func maskBoundsReachInkOutsideTheOCRBox() async throws {
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
    let result = await SourceRestorationBuilder.applying(
      to: OCRResult(lines: [.init(
        boundingBoxNormalized: patch.box,
        text: "Sample",
        appearance: appearance,
        replacementPatches: [patch]
      )]),
      image: image
    )
    let restored = try #require(result.lines.first?.replacementPatches.first)
    #expect(restored.box == patch.box)
    let renderingBox = try #require(restored.renderingBox)
    #expect(renderingBox.minY <= 20.0 / 60)
    #expect(renderingBox.maxY >= 40.0 / 60)
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
    var slash = OverlayLine(
      id: UUID(),
      source: .init(
        recognized: .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.3, width: 0.02, height: 0.05), text: "/"),
        language: Locale.Language(identifier: "en")
      )
    )
    slash.source.replacementPatches[0].renderingBox = CGRect(x: 0.15, y: 0.2, width: 0.1, height: 0.2)
    let frames = OverlayLayoutEngine.protectedSourceFrames(
      for: [slash],
      placements: [],
      in: CGSize(width: 1000, height: 500),
      displayScale: 2
    )
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
  func textureRestorationRetainsMultipleBackgroundColors() async throws {
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
    let result = await SourceRestorationBuilder.applying(to: OCRResult(lines: [line]), image: image)
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
