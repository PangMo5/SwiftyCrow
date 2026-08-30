// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Overlay layout engine")
struct OverlayLayoutEngineTests {

  // MARK: Internal

  struct EdgeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let box: CGRect

    var testDescription: String {
      name
    }
  }

  struct PageAlignmentCase: Sendable, CustomTestStringConvertible {
    let name: String
    let box: CGRect
    let expected: OverlayTextAlignment

    var testDescription: String {
      name
    }
  }

  @Test(arguments: [
    EdgeCase(name: "left", box: CGRect(x: 0.01, y: 0.2, width: 0.06, height: 0.3)),
    EdgeCase(name: "right", box: CGRect(x: 0.93, y: 0.2, width: 0.06, height: 0.3)),
    EdgeCase(name: "top", box: CGRect(x: 0.45, y: 0.01, width: 0.06, height: 0.3)),
    EdgeCase(name: "bottom", box: CGRect(x: 0.45, y: 0.69, width: 0.06, height: 0.3)),
  ])
  func translationUsesOriginalFrameAtCanvasEdges(_ testCase: EdgeCase) throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let line = translatedLine(
      box: testCase.box,
      sourceIsVertical: true,
      text: "Sorry for dropping by so suddenly, Yukie-san.",
      target: "en-US"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    let safe = CGRect(origin: .zero, size: canvas).insetBy(dx: 4, dy: 4)
    #expect(safe.contains(placement.sourceFrame))
    #expect(safe.contains(placement.frame))
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
    #expect(placement.fontSize >= 4)
  }

  @Test
  func rightEdgeTranslationDoesNotExpandTowardTheInterior() throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let box = CGRect(x: 0.89, y: 0.04, width: 0.07, height: 0.2)
    let line = translatedLine(
      box: box,
      sourceIsVertical: true,
      text: "I have something important to tell you today.",
      target: "en-US"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.frame.maxX <= canvas.width - 4)
  }

  @Test
  func longTranslationStaysInsideDetectedSourceSurface() throws {
    let canvas = CGSize(width: 1_024, height: 1_536)
    var line = translatedLine(
      box: CGRect(x: 0.06, y: 0.04, width: 0.07, height: 0.23),
      sourceIsVertical: true,
      text: "Sorry for dropping by so suddenly, Yukie-san.",
      target: "en-US"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.025, y: 0.02, width: 0.115, height: 0.27),
      confidence: 0.9
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    let surface = pixelRect(line.source.surface!.box, canvas: canvas)

    #expect(surface.contains(placement.frame))
    #expect(placement.placementBounds.contains(placement.frame))
    #expect(CoreTextTypesetter.horizontalWordsFit(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      constrainedToWidth: placement.frame.width
    ))
  }

  @Test
  func tinyHorizontalSourceShrinksTranslationInsteadOfGrowing() throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let box = CGRect(x: 0.1, y: 0.1, width: 0.03, height: 0.025)
    let line = translatedLine(
      box: box,
      sourceIsVertical: false,
      text: "Readable translated sentence.",
      target: "en-US"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.fontSize <= 8)
    #expect(placement.lineLimit ?? 0 >= 1)
  }

  @Test
  func shorterHorizontalTranslationKeepsOriginalSourceRowWidth() throws {
    let canvas = CGSize(width: 1_000, height: 500)
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.06),
      sourceIsVertical: false,
      text: "짧음",
      target: "ko"
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
  }

  @Test
  func compactHorizontalControlUsesItsDetectedSurface() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.40, y: 0.40, width: 0.10, height: 0.03),
      sourceIsVertical: false,
      text: "안정된 상태",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.39, y: 0.385, width: 0.14, height: 0.06),
      confidence: 0.8
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame.width > placement.sourceFrame.width)
    #expect(placement.frame.height > placement.sourceFrame.height)
    #expect(placement.frame.contains(
      CGPoint(x: placement.sourceFrame.midX, y: placement.sourceFrame.midY)
    ))
  }

  @Test
  func compactControlInfersCenterAlignmentFromItsSurfaceMargins() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3227, y: 0.3605, width: 0.0363, height: 0.0163),
      text: "Stable",
      horizontalGlyphScale: 0.0163,
      alignment: .leading,
      surface: OverlaySourceSurface(
        box: CGRect(x: 0.3212, y: 0.3500, width: 0.0426, height: 0.0333),
        confidence: 0.8
      )
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("안정된", language: Locale.Language(identifier: "ko-KR"))
    let surfaceFrame = pixelRect(line.source.surface!.box, canvas: canvas)

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.alignment == .center)
    #expect(abs(placement.frame.midX - surfaceFrame.midX) < 0.01)
    #expect(placement.frame.height > placement.sourceFrame.height)
  }

  @Test
  func leadingCompactControlRetainsItsVisualPadding() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.102, y: 0.40, width: 0.05, height: 0.03),
      text: "Status",
      horizontalGlyphScale: 0.03,
      alignment: .leading,
      surface: OverlaySourceSurface(
        box: CGRect(x: 0.10, y: 0.385, width: 0.10, height: 0.06),
        confidence: 0.8
      )
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("상태", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.alignment == .leading)
    #expect(placement.frame.minX > placement.sourceFrame.minX)
  }

  @Test(arguments: [
    PageAlignmentCase(
      name: "wide hero on the page center axis",
      box: CGRect(x: 0.14, y: 0.13, width: 0.74, height: 0.08),
      expected: .center
    ),
    PageAlignmentCase(
      name: "left edge label",
      box: CGRect(x: 0.01, y: 0.25, width: 0.12, height: 0.04),
      expected: .leading
    ),
    PageAlignmentCase(
      name: "right edge label",
      box: CGRect(x: 0.87, y: 0.25, width: 0.12, height: 0.04),
      expected: .trailing
    ),
  ])
  func pageGeometryOverridesIncorrectVisionAlignment(_ testCase: PageAlignmentCase) throws {
    var line = translatedLine(
      box: testCase.box,
      sourceIsVertical: false,
      text: "짧은 번역",
      target: "ko-KR"
    )
    line.source.alignment = .leading

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_000, height: 600)).first
    )

    #expect(placement.alignment == testCase.expected)
  }

  @Test
  func pageCenteredHeroDoesNotCenterAVisuallySeparateCardColumn() {
    var eyebrow = translatedLine(
      id: lineID(0),
      box: CGRect(x: 0.45, y: 0.07, width: 0.10, height: 0.03),
      sourceIsVertical: false,
      text: "프로필",
      target: "ko-KR"
    )
    var hero = translatedLine(
      id: lineID(1),
      box: CGRect(x: 0.14, y: 0.13, width: 0.72, height: 0.08),
      sourceIsVertical: false,
      text: "한 번에 전체 설정을 변경하세요.",
      target: "ko-KR"
    )
    var cardBody = translatedLine(
      id: lineID(2),
      box: CGRect(x: 0.40, y: 0.65, width: 0.20, height: 0.16),
      sourceIsVertical: false,
      sourceRows: 4,
      text: "카드 본문은 원본의 왼쪽 정렬을 유지합니다.",
      target: "ko-KR"
    )
    eyebrow.source.alignment = .leading
    hero.source.alignment = .leading
    cardBody.source.alignment = .leading

    let placements = OverlayLayoutEngine.placements(
      for: [eyebrow, hero, cardBody],
      in: CGSize(width: 1_000, height: 600)
    )

    #expect(placements.first { $0.line.id == eyebrow.id }?.alignment == .center)
    #expect(placements.first { $0.line.id == hero.id }?.alignment == .center)
    #expect(placements.first { $0.line.id == cardBody.id }?.alignment == .leading)
  }

  @Test
  func largeCardSurfaceDoesNotOverrideParagraphAlignment() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.18, y: 0.30, width: 0.20, height: 0.15),
      sourceIsVertical: false,
      sourceRows: 3,
      text: "원본 카드 본문의 왼쪽 정렬을 유지합니다.",
      target: "ko-KR"
    )
    line.source.alignment = .leading
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.08, y: 0.20, width: 0.40, height: 0.35),
      confidence: 0.8
    )

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: canvas).first
    )

    #expect(placement.alignment == .leading)
  }

  @Test
  func heroTitleCanExceedTheOldFixedFontCap() throws {
    let canvas = CGSize(width: 2_170, height: 1_352)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1424, y: 0.1329, width: 0.7384, height: 0.0746),
      text: "Switch your whole setup at once.",
      horizontalGlyphScale: 0.0740,
      horizontalInkScale: 0.0580,
      alignment: .center
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "한 번에 전체 설정을 변경하세요.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize > 72)
    #expect(CoreTextTypesetter.fits(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      flow: placement.flow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
  }

  @Test
  func horizontalCardTitleDoesNotExpandToTheWholeCardSurface() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.12, y: 0.20, width: 0.20, height: 0.05),
      sourceIsVertical: false,
      text: "번역된 카드 제목",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.08, y: 0.10, width: 0.40, height: 0.70),
      confidence: 0.8
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
  }

  @Test
  func horizontalControlUsesWordGlyphHeightInsteadOfIconInflatedLineBox() throws {
    let canvas = CGSize(width: 1_196, height: 610)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.67, y: 0.72, width: 0.18, height: 0.076),
      text: "+ Add bypass",
      horizontalGlyphScale: 0.07,
      horizontalInkScale: 0.034
    )
    var line = OverlayLine(
      id: UUID(0),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en")
      ),
      initialContent: .pending
    )
    line.showTranslation("+ 우회 추가", language: Locale.Language(identifier: "ko"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize < 33)
    #expect(placement.fontSize > 26)
  }

  @Test
  func multilineWebBodyUsesItsVisionRowScaleInsteadOfThinInkHeight() throws {
    let canvas = CGSize(width: 2_172, height: 1_216)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0756, y: 0.6551, width: 0.2358, height: 0.1816),
      text: "Pull a workspace to the top, bottom, left, or right. The two blocks tile beside each other with separate BSP layouts, and windows stay on their own side.",
      rowCount: 5,
      horizontalGlyphScale: 0.0279,
      horizontalInkScale: 0.0150
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "작업 공간을 위쪽, 아래쪽, 왼쪽 또는 오른쪽으로 당기십시오. 두 개의 블록은 별도의 BSP 레이아웃으로 나란히 타일링되며, 창문은 각각 다른 쪽에 유지됩니다.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 31)
    #expect(placement.fontSize <= 33)
    #expect(CoreTextTypesetter.fits(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      flow: placement.flow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
  }

  @Test
  func smallLowContrastFooterTrustsItsVisionGlyphBox() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.06, y: 0.87, width: 0.15, height: 0.021),
      text: "Last updated five minutes ago",
      horizontalGlyphScale: 0.0184,
      horizontalInkScale: 0.00625
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("마지막 업데이트는 5분 전입니다", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 17)
    #expect(placement.fontSize <= 18)
  }

  @Test
  func smallMultilineTableCellBalancesLineBoxAndInkScale() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.55, y: 0.46, width: 0.30, height: 0.045),
      text: "Use one balanced body frame without absorbing the next table row.",
      rowCount: 2,
      horizontalGlyphScale: 0.0212,
      horizontalInkScale: 0.007
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "다음 표 행을 흡수하지 않고 균형 잡힌 본문 프레임을 사용하십시오.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 16)
    #expect(placement.fontSize <= 18)
  }

  @Test
  func compactBoldLabelDoesNotInflateItsPointSize() throws {
    let canvas = CGSize(width: 1_880, height: 1_438)
    func makeLine(weight: OverlayFontWeight) -> OverlayLine {
      var appearance = OverlaySourceAppearance.fallback
      appearance.fontWeight = weight
      let recognized = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.12, y: 0.45, width: 0.04, height: 0.019),
        text: "Tool",
        horizontalGlyphScale: 0.019,
        appearance: appearance
      )
      var line = OverlayLine(
        id: UUID(),
        source: OverlayLine.Source(
          recognized: recognized,
          language: Locale.Language(identifier: "en-US")
        ),
        initialContent: .pending
      )
      line.showTranslation("도구", language: Locale.Language(identifier: "ko-KR"))
      return line
    }

    let regular = try #require(OverlayLayoutEngine.placements(for: [makeLine(weight: .regular)], in: canvas).first)
    let bold = try #require(OverlayLayoutEngine.placements(for: [makeLine(weight: .bold)], in: canvas).first)

    #expect(bold.fontSize <= regular.fontSize + 0.5)
    #expect(bold.fontSize >= 20)
  }

  @Test
  func compactTranslationRetainsTheSourceGlyphScale() throws {
    let canvas = CGSize(width: 1_024, height: 1_536)
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontWeight = .medium
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.75625, y: 0.8125, width: 0.15625, height: 0.01042),
      text: "明日また会いましょう",
      horizontalGlyphScale: 16 / canvas.height,
      appearance: appearance
    )
    var line = OverlayLine(
      id: UUID(0),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP")
      ),
      initialContent: .pending
    )
    line.showTranslation("내일 다시 만나요.", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 13)
  }

  @Test
  func furiganaInflatedBodyUsesTheBaseGlyphScale() throws {
    let canvas = CGSize(width: 1_314, height: 1_898)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.045, y: 0.546, width: 0.437, height: 0.102),
      text: "木のぼうの先にくくりつけて、動物や魚をとるためのやりとして使われた。",
      rowCount: 3,
      horizontalGlyphScale: 0.0355,
      horizontalInkScale: 0.0101
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "나무 막대 끝에 묶어 동물이나 물고기를 잡는 창으로 사용되었습니다.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 32)
    #expect(placement.fontSize <= 38)
    #expect(CoreTextTypesetter.fits(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      flow: placement.flow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
  }

  @Test
  func verticalSourceKeepsNarrowRestorationBleedNearBubbleEdges() {
    let canvas = CGSize(width: 1_000, height: 1_000)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.2))
    let horizontal = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      in: canvas,
      displayScale: 1
    )
    let vertical = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .vertical(characterScale: 0.04, progression: .rightToLeft),
      in: canvas,
      displayScale: 1
    )

    #expect(horizontal.minX < vertical.minX)
    #expect(horizontal.minY == 199)
    #expect(vertical.minY == 198)
    #expect(vertical.width <= 106)
    #expect(horizontal.width >= 128)
  }

  @Test
  func multilineHorizontalPatchGetsOnlyVerticalAntialiasingBleed() {
    let canvas = CGSize(width: 2_000, height: 1_200)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.025))
    let singleLine = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      in: canvas,
      displayScale: 2
    )
    let multiline = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 5),
      in: canvas,
      displayScale: 2
    )

    #expect(singleLine.minY >= 719)
    #expect(singleLine.maxY <= 751)
    #expect(multiline.minY < singleLine.minY)
    #expect(multiline.maxY > singleLine.maxY)
    #expect(multiline.minY >= 717)
    #expect(multiline.maxY <= 753)
  }

  @Test
  func horizontalTranslationKeepsTheSourceTopEdge() throws {
    let canvas = CGSize(width: 2_178, height: 1_228)
    let line = translatedLine(
      box: CGRect(x: 0.38808, y: 0.675, width: 0.22674, height: 0.1317),
      sourceIsVertical: false,
      sourceRows: 4,
      text: "Conservative, Balanced, Fast 중에서 선택하고 Amado가 급격한 신호 손실을 걸러내게 하십시오.",
      target: "ko-KR"
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(abs(placement.frame.minY - placement.sourceFrame.minY) < 0.5)
  }

  @Test
  func tallerHorizontalTranslationShrinksInsideSource() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.36, y: 0.42, width: 0.16, height: 0.035),
      sourceIsVertical: false,
      text: "번역문이 원문보다 여러 줄 길어지면 추가된 높이만큼 위와 아래로 나누어 확장합니다.",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.25, y: 0.25, width: 0.40, height: 0.40),
      confidence: 0.9
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
  }

  @Test
  func widerVerticalTranslationShrinksInsideSource() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.44, y: 0.25, width: 0.05, height: 0.28),
      sourceIsVertical: true,
      text: "번역문이 길어져 세로쓰기 열이 늘어나더라도 원문의 중심 위치를 유지합니다.",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.28, y: 0.18, width: 0.38, height: 0.42),
      confidence: 0.9
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
  }

  @Test
  func pendingVerticalSourceDoesNotCreateAReplacementChip() {
    let canvas = CGSize(width: 1_024, height: 480)
    let line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .pending
    )
    #expect(line.textFlow == .vertical(.rightToLeft))
    #expect(OverlayLayoutEngine.placements(for: [line], in: canvas).isEmpty)
  }

  @Test
  func fixedTranslationFrameDoesNotCoverPendingSourceText() throws {
    let canvas = CGSize(width: 2_178, height: 1_228)
    let pending = sourceLine(
      id: UUID(1),
      box: CGRect(x: 0.43605, y: 0.07474, width: 0.13663, height: 0.03359),
      sourceIsVertical: false,
      initialContent: .pending
    )
    let heading = translatedLine(
      id: UUID(2),
      box: CGRect(x: 0.16555, y: 0.13639, width: 0.68491, height: 0.09125),
      sourceIsVertical: false,
      text: "걸어 나가세요. 귀하의 Mac이 종료됩니다.",
      target: "ko-KR"
    )

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [pending, heading], in: canvas).first
    )
    let pendingFrame = pixelRect(pending.source.box, canvas: canvas)
    let intersection = placement.frame.intersection(pendingFrame)

    #expect(intersection.isNull || intersection.isEmpty)
  }

  @Test
  func sameWritingSystemSourceLeavesOriginalPixelsUntouched() {
    let line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .source
    )
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_024, height: 480)).isEmpty)
  }

  @Test
  func verticalTranslationUsesCoreTextFrameThatFits() throws {
    let canvas = CGSize(width: 600, height: 600)
    let line = translatedLine(
      box: CGRect(x: 0.4, y: 0.1, width: 0.16, height: 0.55),
      sourceIsVertical: true,
      text: "2026年8月27日です。OKなら今すぐ始めよう。",
      target: "ja"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    #expect(placement.line.textFlow == .vertical(.rightToLeft))
    #expect(CoreTextTypesetter.fits(
      text: line.displayedText,
      language: line.displayedLanguage,
      flow: line.textFlow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
    let image = CoreTextTypesetter.verticalGlyphImage(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      size: placement.frame.size,
      scale: 2,
      progression: .rightToLeft
    )
    #expect(image != nil)
  }

  @Test
  func horizontalAccessibilityPreferenceReflowsVerticalTranslation() throws {
    let line = translatedLine(
      box: CGRect(x: 0.4, y: 0.1, width: 0.16, height: 0.55),
      sourceIsVertical: true,
      text: "今日は晴れです",
      target: "ja"
    )
    let placement = try #require(
      OverlayLayoutEngine.placements(
        for: [line],
        in: CGSize(width: 600, height: 600),
        prefersHorizontalTextLayout: true
      ).first
    )
    #expect(placement.flow == .horizontal(.leftToRight))
    #expect(placement.lineLimit != nil)
  }

  @Test
  func horizontalArabicUsesTrailingAlignment() throws {
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.1),
      sourceIsVertical: false,
      text: "لدي شيء مهم لأخبرك به",
      target: "ar"
    )
    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 400)).first
    )
    #expect(placement.line.textFlow == .horizontal(.rightToLeft))
    #expect(placement.alignment == .trailing)
  }

  @Test
  func verticalOriginHorizontalTranslationIsCentered() throws {
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.3),
      sourceIsVertical: true,
      text: "A horizontal translation",
      target: "en-US"
    )
    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 400)).first
    )
    #expect(placement.alignment == .center)
  }

  @Test
  func adjacentSourceFramesRemainSeparate() {
    let canvas = CGSize(width: 1_000, height: 500)
    let first = translatedLine(
      id: UUID(1),
      box: CGRect(x: 0.40, y: 0.2, width: 0.06, height: 0.28),
      sourceIsVertical: true,
      text: "The first translated sentence is readable.",
      target: "en-US"
    )
    let second = translatedLine(
      id: UUID(2),
      box: CGRect(x: 0.54, y: 0.2, width: 0.06, height: 0.28),
      sourceIsVertical: true,
      text: "The second translated sentence is readable.",
      target: "en-US"
    )
    let placements = OverlayLayoutEngine.placements(for: [first, second], in: canvas)
    #expect(placements.count == 2)
    let intersection = placements[0].frame.intersection(placements[1].frame)
    #expect(intersection.isNull || intersection.isEmpty)
  }

  @Test
  func observedProblemMatrixHasSixContainedNonOverlappingLabels() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let rows: [(CGRect, String)] = [
      (CGRect(x: 0.89375, y: 0.03958, width: 0.06875, height: 0.19167), "I have something important to tell you today."),
      (CGRect(x: 0.05937, y: 0.03750, width: 0.06563, height: 0.22708), "Sorry for dropping by so suddenly, Yukie-san."),
      (CGRect(x: 0.58750, y: 0.38333, width: 0.05938, height: 0.12083), "I still cannot believe it."),
      (CGRect(x: 0.42187, y: 0.38125, width: 0.06250, height: 0.11458), "Is that really true?"),
      (CGRect(x: 0.40625, y: 0.68125, width: 0.05625, height: 0.10417), "If that is OK, let us start right now."),
      (CGRect(x: 0.06250, y: 0.68125, width: 0.05625, height: 0.10833), "It is August 27, 2026."),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: true,
        text: row.1,
        target: "en-US"
      )
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    let safeBounds = CGRect(origin: .zero, size: canvas).insetBy(dx: 4, dy: 4)

    #expect(placements.count == 6)
    #expect(placements.allSatisfy { safeBounds.contains($0.frame) && safeBounds.contains($0.sourceFrame) })
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
    #expect(placements.allSatisfy { placement in
      centerDistance(placement.frame, placement.sourceFrame)
        <= max(24, placement.sourceFrame.width / 2)
    })
    #expect(placements.allSatisfy { $0.fontSize >= 4 })
    let adjacentDistances = placements[2...3].map {
      centerDistance($0.frame, $0.sourceFrame)
    }
    #expect(
      adjacentDistances.allSatisfy { $0 <= 30 },
      "Adjacent center distances: \(adjacentDistances)"
    )
    #expect(
      abs(adjacentDistances[0] - adjacentDistances[1]) < 1,
      "Adjacent center distances: \(adjacentDistances)"
    )
    #expect(placements.allSatisfy { placement in
      CoreTextTypesetter.fits(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        flow: placement.flow,
        fontSize: placement.fontSize,
        in: placement.frame.size
      )
    })
  }

  @Test
  func observedTamilProblemMatrixKeepsAdjacentLabelsSeparate() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let sentence = "இது தெளிவாக வாசிக்கக்கூடிய சோதனை வாக்கியம்."
    let rows: [(CGRect, String)] = [
      (CGRect(x: 0.89375, y: 0.03958, width: 0.06875, height: 0.19167), sentence),
      (CGRect(x: 0.05937, y: 0.03750, width: 0.06563, height: 0.22708), "\(sentence) \(sentence)"),
      (CGRect(x: 0.58750, y: 0.38333, width: 0.05938, height: 0.12083), sentence),
      (CGRect(x: 0.42187, y: 0.38125, width: 0.06250, height: 0.11458), "ஆம்."),
      (CGRect(x: 0.40625, y: 0.68125, width: 0.05625, height: 0.10417), "OK · \(sentence)"),
      (CGRect(x: 0.06250, y: 0.68125, width: 0.05625, height: 0.10833), "2026 · \(sentence)"),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: true,
        text: row.1,
        target: "ta-Taml-IN"
      )
    }

    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)

    #expect(placements.count == 6)
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test
  func observedNormalMatrixHasFourNonOverlappingLabelsAfterCoalescing() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let rows: [(CGRect, Bool, String)] = [
      (CGRect(x: 0.11562, y: 0.04792, width: 0.06875, height: 0.20833), true, "The weather is nice today."),
      (
        CGRect(x: 0.09030, y: 0.44436, width: 0.34095, height: 0.07231),
        false,
        "The weather is nice today. Let us meet here again next weekend."
      ),
      (CGRect(x: 0.60000, y: 0.64792, width: 0.06250, height: 0.11875), true, "Yes, I am looking forward to it."),
      (CGRect(x: 0.38750, y: 0.64583, width: 0.05938, height: 0.14167), true, "Let us meet again tomorrow."),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: row.1,
        sourceRows: index == 1 ? 3 : 1,
        text: row.2,
        target: "en-US"
      )
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    #expect(placements.count == 4)
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test
  func unavailableTranslationAlsoLeavesSourceUntouched() {
    var line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .pending
    )
    line.showUnavailable()
    #expect(line.isUnavailable)
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_024, height: 480)).isEmpty)
  }

  @Test
  func degenerateCanvasProducesFiniteContainedFrames() {
    let line = translatedLine(
      box: CGRect(x: -2, y: 4, width: 10, height: 0),
      sourceIsVertical: false,
      text: "Text",
      target: "en-US"
    )
    let canvas = CGSize(width: 3, height: 2)
    let placements = OverlayLayoutEngine.placements(for: [line], in: canvas)
    #expect(placements.count == 1)
    #expect(placements[0].frame.minX.isFinite)
    #expect(placements[0].frame.minY.isFinite)
    #expect(CGRect(origin: .zero, size: canvas).contains(placements[0].frame))
  }

  // MARK: Private

  private func translatedLine(
    id: UUID = UUID(0),
    box: CGRect,
    sourceIsVertical: Bool,
    sourceRows: Int = 1,
    text: String,
    target: String
  ) -> OverlayLine {
    var line = sourceLine(
      id: id,
      box: box,
      sourceIsVertical: sourceIsVertical,
      sourceRows: sourceRows,
      initialContent: .pending
    )
    line.showTranslation(text, language: Locale.Language(identifier: target))
    return line
  }

  private func sourceLine(
    id: UUID = UUID(0),
    box: CGRect,
    sourceIsVertical: Bool,
    sourceRows: Int = 1,
    initialContent: OverlayLine.InitialContent
  ) -> OverlayLine {
    let recognized = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "今日は大切な話があります",
      rowCount: sourceIsVertical ? 2 : sourceRows,
      isVerticalBlock: sourceIsVertical,
      verticalCharScale: sourceIsVertical ? max(0.018, box.width / 2) : 0
    )
    return OverlayLine(
      id: id,
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja")
      ),
      initialContent: initialContent
    )
  }

  private func pixelRect(_ normalized: CGRect, canvas: CGSize) -> CGRect {
    CGRect(
      x: normalized.minX * canvas.width,
      y: normalized.minY * canvas.height,
      width: normalized.width * canvas.width,
      height: normalized.height * canvas.height
    )
  }

  private func pairwiseNonOverlapping(_ frames: [CGRect]) -> Bool {
    for lhs in frames.indices {
      for rhs in frames.indices where rhs > lhs {
        let intersection = frames[lhs].intersection(frames[rhs])
        if !intersection.isNull, !intersection.isEmpty { return false }
      }
    }
    return true
  }

  private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
  }

  private func lineID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
  }
}
