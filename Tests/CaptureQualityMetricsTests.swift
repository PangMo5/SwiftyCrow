// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

struct CaptureQualityMetricsTests {
  @Test
  func backgroundGateDetectsBrightRemnantsAndRejectsInvalidRegions() throws {
    let context = try #require(CGContext(
      data: nil,
      width: 12,
      height: 8,
      bitsPerComponent: 8,
      bytesPerRow: 48,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(try #require(CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      components: [0.8, 0.8, 0.8, 1]
    )))
    context.fill(CGRect(x: 0, y: 0, width: 12, height: 8))
    let expected = CaptureBackgroundExpectation(region: [0, 0, 12, 8], color: [204, 204, 204], maximumChannelError: 1)
    #expect(CaptureQualityMetrics.restoredBackgroundIssues(try #require(context.makeImage()), expected: [expected]).isEmpty)
    context.setFillColor(try #require(CGColor(
      colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
      components: [217.0 / 255, 217.0 / 255, 217.0 / 255, 1]
    )))
    context.fill(CGRect(x: 3, y: 3, width: 1, height: 1))
    let image = try #require(context.makeImage())
    #expect(!CaptureQualityMetrics.restoredBackgroundIssues(image, expected: [expected]).isEmpty)
    var invalid = expected
    invalid.region = [0, 0, Int.max, 8]
    #expect(CaptureQualityMetrics
      .restoredBackgroundIssues(image, expected: [invalid]) == ["Invalid restored-background expectation"])
  }

  @Test
  func scopedMeaningChecksDoNotBorrowCorrectWordsFromOtherParagraphs() {
    func line(_ source: String, _ target: String) -> OverlayLine {
      var value = OverlayLine(
        id: UUID(),
        source: .init(recognized: .init(boundingBoxNormalized: .zero, text: source), language: .init(identifier: "en"))
      )
      value.showTranslation(target, language: .init(identifier: "ko"))
      return value
    }
    let expected = [CaptureTranslationExpectation(
      sourcePrefix: "Unsigned variants",
      targetIncludes: ["부호"],
      targetExcludes: ["서명"]
    )]
    let incorrect = [line("Other paragraph", "부호가 없는 정수"), line("Unsigned variants can store numbers.", "서명되지 않은 변형")]
    #expect(CaptureQualityMetrics.translationIssues(incorrect, expected: expected).count == 2)
    #expect(CaptureQualityMetrics.translationIssues(
      [line("Unsigned variants can store numbers.", "부호가 없는 변형")],
      expected: expected
    ).isEmpty)
    #expect(!CaptureQualityMetrics.translationIssues([], expected: expected).isEmpty)
  }

  @Test
  func lineCountExpectationsCatchWrappingAtTheSameFontSize() {
    var line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(boundingBoxNormalized: .zero, text: "Label"),
      language: .init(identifier: "en")
    ))
    line.showTranslation("1.2. 안녕하세요, 세계!", language: .init(identifier: "ko"))
    func placement(width: CGFloat) -> OverlayPlacement {
      let frame = CGRect(x: 20, y: 20, width: width, height: 100)
      return .init(
        line: line,
        flow: .horizontal(.leftToRight),
        sourceFrame: frame,
        frame: frame,
        placementBounds: frame,
        fontSize: 12,
        lineHeightMultiple: 1,
        alignment: .leading
      )
    }
    let expected = [CaptureLineCountExpectation(source: "Label", maximum: 1)]
    #expect(CaptureQualityMetrics.lineCountIssues([placement(width: 200)], expected: expected).isEmpty)
    #expect(!CaptureQualityMetrics.lineCountIssues([placement(width: 70)], expected: expected).isEmpty)
    #expect(!CaptureQualityMetrics.lineCountIssues([], expected: expected).isEmpty)
    #expect(!CaptureQualityMetrics.lineCountIssues([placement(width: 200)], expected: [.init(source: "Label", maximum: 0)])
      .isEmpty)
  }

  @Test
  func rotatedOwnerChecksUsePhysicalCanvasCoordinates() {
    var line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(boundingBoxNormalized: .zero, text: "First"),
      language: .init(identifier: "en")
    ))
    line.showTranslation("A translated label", language: .init(identifier: "en"))
    let frame = CGRect(x: 30, y: 85, width: 140, height: 30)
    var first = OverlayPlacement(
      line: line,
      flow: .horizontal(.leftToRight),
      sourceFrame: .zero,
      frame: frame,
      placementBounds: frame,
      fontSize: 20,
      lineHeightMultiple: 1,
      alignment: .center
    )
    first.targetRotationRadians = .pi / 2
    line = OverlayLine(id: UUID(), source: line.source)
    line.source.text = "Second"
    line.showTranslation("Another translated label", language: .init(identifier: "en"))
    func other(_ frame: CGRect) -> OverlayPlacement {
      OverlayPlacement(
        line: line,
        flow: .horizontal(.leftToRight),
        sourceFrame: .zero,
        frame: frame,
        placementBounds: frame,
        fontSize: 20,
        lineHeightMultiple: 1,
        alignment: .center
      )
    }
    #expect(!CaptureQualityMetrics.ownerOverlapIssues([first, other(CGRect(x: 90, y: 50, width: 20, height: 60))]).isEmpty)
    #expect(CaptureQualityMetrics.ownerOverlapIssues([first, other(CGRect(x: 35, y: 90, width: 35, height: 20))]).isEmpty)
    #expect(!CaptureQualityMetrics.foreignRegionIssues(
      [first],
      canvas: CGSize(width: 200, height: 200),
      regions: [CGRect(x: 85, y: 30, width: 30, height: 140)]
    ).isEmpty)
    #expect(CaptureQualityMetrics.foreignRegionIssues(
      [first],
      canvas: CGSize(width: 200, height: 200),
      regions: [CGRect(x: 35, y: 90, width: 35, height: 20)]
    ).isEmpty)
  }

  @Test
  func paragraphOwnershipIgnoresVocalizationButStillRequiresEveryWordInOneUnit() {
    let expected = ["تشمل أبرز تطبيقات محرّكات البحث."]
    #expect(CaptureQualityMetrics.paragraphIssues(texts: ["تشمل أبرز تطبيقات محركات البحث."], expected: expected).isEmpty)
    #expect(!CaptureQualityMetrics.paragraphIssues(texts: ["تشمل أبرز تطبيقات", "محركات البحث."], expected: expected).isEmpty)
    #expect(!CaptureQualityMetrics.paragraphIssues(texts: ["تشمل أبرز محركات البحث."], expected: expected).isEmpty)
  }

  @Test
  func proseChecksRejectAnAccidentallyProtectedWordInsideATranslatedParagraph() {
    let text = "Read these types here."
    let base = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    var code = base
    code.fontDesign = .monospaced
    let source = OverlayLine.Source(
      recognized: .init(
        boundingBoxNormalized: .zero,
        text: text,
        appearance: base,
        styleRuns: [.init(
          range: (text as NSString).range(of: "types"),
          box: .zero,
          appearance: code
        )]
      ),
      language: .init(identifier: "en")
    )
    var line = OverlayLine(id: UUID(), source: source)
    line.showTranslation("이 types를 읽으세요.", language: .init(identifier: "ko"))
    #expect(!CaptureQualityMetrics.proseIssues(lines: [line], expected: ["types"]).isEmpty)
    line.source.styleRuns = []
    #expect(CaptureQualityMetrics.proseIssues(lines: [line], expected: ["types"]).isEmpty)
  }

  @Test
  func onePreservedLiteralCannotHideAnotherTranslatedOccurrence() {
    var known = OCRResult.Line(boundingBoxNormalized: .init(x: 0.1, y: 0.1, width: 0.2, height: 0.05), text: "usize")
    known.preservesSource = true
    let preserved = OverlayLine(id: UUID(), source: .init(recognized: known, language: .init(identifier: "en")))
    known.preservesSource = false
    known.boundingBoxNormalized.origin.y = 0.3
    var damaged = OverlayLine(id: UUID(), source: .init(recognized: known, language: .init(identifier: "en")))
    damaged.showTranslation("사용 크기", language: .init(identifier: "ko"))
    #expect(CaptureQualityMetrics.literalIssues(lines: [preserved, damaged], expected: ["usize"]).count == 1)
  }

  @Test
  func alignmentChecksRejectWrongAndMissingSubjects() {
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.05),
      text: "Alignment subject",
      alignment: .center
    ), language: .init(identifier: "en")))
    line.showTranslation("정렬을 확인합니다", language: .init(identifier: "ko"))
    let placements = OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1000, height: 800))
    #expect(CaptureQualityMetrics.alignmentIssues(placements, expected: [.init(source: "Alignment", alignment: "center")])
      .isEmpty)
    #expect(!CaptureQualityMetrics.alignmentIssues(placements, expected: [.init(source: "Alignment", alignment: "leading")])
      .isEmpty)
    #expect(!CaptureQualityMetrics.alignmentIssues(placements, expected: [.init(source: "Missing", alignment: "center")]).isEmpty)
  }

  @Test
  func fixedPitchStandaloneTokenRetainsSourceButMonospacedProseStillTranslates() {
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontDesign: .monospaced
    )
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: "usize", appearance: appearance),
      language: .init(identifier: "en")
    )
    var line = OverlayLine(id: UUID(), source: source)
    #expect(source.isProtectedLiteral)
    #expect(CaptureQualityMetrics.literalIssues(lines: [line], expected: ["usize"]).isEmpty)
    line.showTranslation("Usize", language: .init(identifier: "ko"))
    #expect(!CaptureQualityMetrics.literalIssues(lines: [line], expected: ["usize"]).isEmpty)
    var prose = source
    prose.text = "This is a monospaced paragraph"
    #expect(!prose.isProtectedLiteral)
  }

  @Test
  func unprotectedCoincidentalLiteralDoesNotPassTheProtectionCheck() {
    let recognized = OCRResult.Line(boundingBoxNormalized: .zero, text: "Use u32 here")
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation("u32를 사용하세요", language: .init(identifier: "ko"))
    #expect(!CaptureQualityMetrics.literalIssues(lines: [line], expected: ["u32"]).isEmpty)
  }

  @Test(arguments: [false, true])
  func foreignContainerChecksActualPaintInsteadOfOnlyTextFit(_ shaped: Bool) {
    let canvas = CGSize(width: 300, height: 200)
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "A paragraph",
      rowCount: 5,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
    line.showTranslation(
      "Translations must avoid the table while retaining the complete paragraph below it.",
      language: .init(identifier: "en")
    )
    let placement = OverlayPlacement(
      line: line,
      flow: .horizontal(.leftToRight),
      sourceFrame: CGRect(origin: .zero, size: canvas),
      frame: CGRect(origin: .zero, size: canvas),
      placementBounds: CGRect(origin: .zero, size: canvas),
      fontSize: 20,
      lineHeightMultiple: 1,
      alignment: .leading,
      textFlowRegions: shaped
        ? [
          CGRect(x: 100, y: 0, width: 200, height: 50),
          CGRect(x: 0, y: 50, width: 300, height: 150),
        ]
        : []
    )
    let issues = CaptureQualityMetrics.foreignRegionIssues(
      [placement],
      canvas: canvas,
      regions: [CGRect(x: 0, y: 0, width: 100, height: 50)]
    )
    #expect(issues.isEmpty == shaped)
    var captionLine = line
    captionLine.source.text = "Independent caption"
    let caption = OverlayPlacement(
      line: captionLine,
      flow: .horizontal(.leftToRight),
      sourceFrame: CGRect(x: 10, y: 10, width: 80, height: 25),
      frame: CGRect(x: 10, y: 10, width: 80, height: 25),
      placementBounds: CGRect(origin: .zero, size: canvas),
      fontSize: 12,
      lineHeightMultiple: 1,
      alignment: .leading
    )
    #expect(CaptureQualityMetrics.ownerOverlapIssues([placement, caption]).isEmpty == shaped)
  }

  @Test
  func readablePlainTextDoesNotPassARequiredLinkStyle() {
    let source = OCRResult.Line(
      boundingBoxNormalized: .zero,
      text: "A linked term",
      appearance: .init(background: .white, foreground: .black, confidence: 1)
    )
    var line = OverlayLine(
      id: UUID(),
      source: .init(recognized: source, language: .init(identifier: "en")),
      initialContent: .pending
    )
    line.showTranslation("링크된 용어", language: .init(identifier: "ko"))
    let expectation = CaptureStyleExpectation(source: "linked term", target: "용어", kind: "color")
    #expect(!CaptureQualityMetrics.styleIssues(lines: [line], expected: [expectation]).isEmpty)
  }

  @Test(arguments: [
    ("en", "ep the original files.", "Keep"),
    ("ko", "업 데이트 중에는 기기를 분리하지 마세요.", "업데이트"),
    ("zh-Hans", "更新过程中请勿断开。", "连接"),
  ])
  func nativeRecognitionDefectsCannotPassBecauseTranslationRendered(_ sample: (String, String, String)) {
    #expect(CaptureQualityMetrics.missingSourceText(
      sample.1,
      requiredText: [],
      requiredWords: [sample.2],
      language: sample.0
    ) ==
      [sample.2])
  }

  @Test
  func missingControlsAreIndependentFromParagraphCoverage() {
    #expect(CaptureQualityMetrics.missingSourceText(
      "Téléchargements Documentation",
      requiredText: ["Téléchargements", "Assistance"],
      requiredWords: [],
      language: "fr"
    ) == ["Assistance"])
  }
}
