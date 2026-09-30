// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct RealWebStructureTests {
  @Test(arguments: [
    ["An overview of this behavior", "continues across physical lines", "until the final sentence."],
    ["تشمل التطبيقات التي تظهر في هذه الواجهة", "مجموعة من الأدوات التي تساعد", "على قراءة المحتوى بسهولة."],
    ["この文章は画面に表示された内容について", "改行をまたいで説明を続けます", "最後まで一つの段落として読みます。"],
  ])
  func aDetachedFirstBodyRowRetainsItsFollowingParagraph(_ texts: [String]) {
    let lines = texts.enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.2, y: 0.2 + Double(index) * 0.03, width: 0.4, height: 0.02),
        text: text,
        horizontalGlyphScale: 0.02,
        recognitionGroupID: index == 0 ? 1 : 2,
        appearance: .init(
          background: .white,
          foreground: .init(
            red: index == 0 ? 0.3 : 0.2,
            green: index == 0 ? 0.3 : 0.2,
            blue: index == 0 ? 0.3 : 0.2,
            alpha: 1
          ),
          confidence: 1,
          foregroundConfidence: index == 0 ? 0.06 : 0.04,
          fontSizeScale: 0.022,
          fontWeight: index == 0 ? .semibold : .regular
        )
      )
    }
    #expect(OCRResult(lines: lines).coalescingParagraphFragments().lines.count == 1)
    var heading = lines[0]
    heading.appearance.foregroundConfidence = 0.8
    heading.appearance.fontWeight = .bold
    #expect(OCRResult(lines: [heading] + lines.dropFirst()).coalescingParagraphFragments().lines.count == 2)
  }

  @Test
  func nativeWrappingConnectsStyledRowsWithoutAbsorbingAnUnrelatedHeading() {
    var emphasized = OverlaySourceAppearance.fallback
    emphasized.confidence = 1
    emphasized.foregroundConfidence = 1
    emphasized.fontWeight = .bold
    emphasized.foreground = .init(red: 0.1, green: 0.3, blue: 0.9, alpha: 1)
    var ordinary = OverlaySourceAppearance.fallback
    ordinary.confidence = 1
    ordinary.foregroundConfidence = 1
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.04),
      text: "A highlighted beginning",
      recognitionGroupID: 4,
      appearance: emphasized,
      recognitionLanguages: ["en"],
      continuesToNextLine: true
    )
    let next = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.25, width: 0.5, height: 0.04),
      text: "continues in ordinary text.",
      recognitionGroupID: 4,
      appearance: ordinary,
      recognitionLanguages: ["en"]
    )
    #expect(OCRResult(lines: [first, next]).coalescingParagraphFragments().lines.count == 1)
    var heading = first
    heading.text = "Independent heading"
    heading.continuesToNextLine = false
    #expect(OCRResult(lines: [heading, next]).coalescingParagraphFragments().lines.count == 2)
    var separate = next
    separate.recognitionGroupID = 5
    #expect(OCRResult(lines: [first, separate]).coalescingParagraphFragments().lines.count == 2)
  }

  @Test(arguments: ["en", "ar"])
  func targetWritingDirectionDoesNotMoveTheSourceReadingEdge(_ source: String) throws {
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.25, height: 0.04),
      text: source == "ar" ? "تطبيقات الذكاء الاصطناعي" : "Artificial intelligence applications"
    ), language: .init(identifier: source)))
    line.showTranslation(
      source == "ar" ? "인공지능 응용 분야" : "تطبيقات الذكاء الاصطناعي",
      language: .init(identifier: source == "ar" ? "ko" : "ar")
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1200, height: 800)).first)
    #expect(placement.alignment == (source == "ar" ? .trailing : .leading))
  }

  @Test
  func paddedColumnBoxesDoNotSplitAContiguousSentence() {
    let left = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.4, y: 0.2, width: 0.02, height: 0.08),
      text: "文章",
      isVerticalBlock: true,
      verticalCharScale: 0.02,
      recognitionGroupID: 1
    )
    let right = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.412, y: 0.2, width: 0.056, height: 0.08),
      text: "最初の",
      isVerticalBlock: true,
      verticalCharScale: 0.02,
      recognitionGroupID: 1
    )
    #expect(OCRResult(lines: [left, right]).coalescingParagraphFragments().lines.map(\.text) == ["最初の文章"])
    // Two hypotheses of the same physical column must still remain separate
    // here; duplicate reconciliation owns their replacement, not concatenation.
    var sameColumn = right
    sameColumn.boundingBoxNormalized = CGRect(x: 0.4, y: 0.2, width: 0.02, height: 0.08)
    #expect(OCRResult(lines: [left, sameColumn]).coalescingParagraphFragments().lines.count == 2)
  }

  @Test
  func rubyErasureMarginsDoNotSeparateNeighboringTextColumns() throws {
    let columns = [
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.4, y: 0.2, width: 0.02, height: 0.08),
        text: "漢字中",
        isVerticalBlock: true,
        verticalCharScale: 0.02,
        recognitionGroupID: 1
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.43, y: 0.2, width: 0.02, height: 0.08),
        text: "次の文",
        isVerticalBlock: true,
        verticalCharScale: 0.02,
        recognitionGroupID: 1
      ),
    ]
    let ruby = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.423, y: 0.2, width: 0.017, height: 0.04),
      text: "かんじ",
      isVerticalBlock: true,
      verticalCharScale: 0.008
    )
    let original = OCRResult(lines: columns).coalescingParagraphFragments()
    let annotated = OCRResult(lines: columns + [ruby]).absorbingRubyAnnotations().coalescingParagraphFragments()
    #expect(original.lines.count == 1)
    #expect(annotated.lines.map(\.text) == original.lines.map(\.text))
    #expect(try #require(annotated.lines.first).replacementPatches.contains(where: \.isAnnotation))
  }

  @Test(arguments: [false, true], [800.0, 1600, 3424])
  func analysisKeepsPhysicalGlyphSamplesWithinItsBudget(_ vertical: Bool, _ width: Double) {
    let size = CGSize(width: width, height: 600)
    let lines = (0..<8).map { index in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: 0.2,
          y: 0.1 + Double(index) * 0.08,
          width: (vertical ? 24 : 300) / width,
          height: (vertical ? 120 : 24) / 600
        ),
        text: "文章の領域",
        imageAspectRatio: width / 600,
        isVerticalBlock: vertical,
        verticalCharScale: vertical ? 24 / width : 0,
        horizontalGlyphScale: vertical ? 0 : 24 / 600
      )
    }
    let side = OCRGeometry.analysisRasterLongestSide(for: lines, imageSize: size)
    #expect(side >= 1024 && side <= 2048)
    #expect(24 * min(1, Double(side) / width) >= 12)
  }

  @Test(arguments: ["en", "ar"], [OverlayTextAlignment.leading, .center, .trailing])
  func indistinguishableRowsUseSourceReadingDirection(_ language: String, _ hint: OverlayTextAlignment) throws {
    let rows = [
      CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.025),
      CGRect(x: 0.2, y: 0.24, width: 0.4, height: 0.025),
    ]
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: rows[0].union(rows[1]),
      text: language == "ar" ? "التعلم والاستدلال وتمثيل المعرفة" : "Learning and reasoning across visible rows",
      imageAspectRatio: 1.5,
      rowCount: rows.count,
      styleRuns: rows.enumerated().map { index, box in
        OverlaySourceStyleRun(range: NSRange(location: index, length: 1), box: box)
      },
      alignment: hint
    ), language: .init(identifier: language)))
    line.showTranslation("학습, 추론, 지식 표현", language: .init(identifier: "ko"))
    #expect(line.source.rowAlignmentEvidence == .ambiguous)
    #expect(try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1200, height: 800)).first)
      .alignment == (language == "ar" ? .trailing : .leading))
  }

  @Test(arguments: [800.0, 3424, 10000])
  func emptyCanvasMarginsCannotChangeParagraphAlignment(_ canvasWidth: Double) {
    let rows = (0..<20).map { index -> CGRect in
      let width: Double = index == 19 ? 368 : 400
      let y = Double(10 + index * 18) / 600
      return CGRect(x: 20 / canvasWidth, y: y, width: width / canvasWidth, height: 12.0 / 600)
    }
    #expect(OCRGeometry.horizontalAlignment(forRows: rows, imageAspectRatio: canvasWidth / 600) == .leading)
  }

  @Test
  func similarLengthRowsDoNotGainFalseCenterEvidenceInAWideCanvas() {
    let rows = [
      CGRect(x: 0.624123833, y: 0.753101804, width: 0.047897195, height: 0.018847191),
      CGRect(x: 0.626464844, y: 0.773833713, width: 0.043945313, height: 0.016962471),
    ]
    #expect(OCRGeometry.horizontalAlignment(forRows: rows, imageAspectRatio: 3424.0 / 1060) == nil)
    let cropped = rows.map { CGRect(
      x: ($0.minX - 0.3) / 0.4,
      y: $0.minY,
      width: $0.width / 0.4,
      height: $0.height
    ) }
    #expect(OCRGeometry.horizontalAlignment(forRows: cropped, imageAspectRatio: 1369.6 / 1060) == nil)
  }

  @Test(arguments: [OverlayTextAlignment.leading, .center, .trailing])
  func completeRowsKeepTheShortFinalRowAsAlignmentEvidence(_ expected: OverlayTextAlignment) throws {
    let widths: [CGFloat] = [0.38, 0.4, 0.4, 0.4, 0.4, 0.4, 0.4, 0.16]
    let rows = widths.enumerated().map { index, width in
      let x: CGFloat =
        switch expected {
        case .leading: 0.2 + (index == 0 ? 0.02 : 0)
        case .center: 0.5 - width / 2
        case .trailing: 0.8 - width - (index == 0 ? 0.02 : 0)
        }
      return CGRect(x: x, y: 0.1 + CGFloat(index) * 0.03, width: width, height: 0.025)
    }
    #expect(OCRGeometry.horizontalAlignment(forRows: rows, imageAspectRatio: 1.5) == expected)
    // Split each row into style fragments: they must not vote independently.
    let runs = rows.enumerated().flatMap { index, box in
      [
        OverlaySourceStyleRun(
          range: NSRange(location: index * 2, length: 1),
          box: CGRect(x: box.minX, y: box.minY, width: box.width * 0.3, height: box.height)
        ),
        OverlaySourceStyleRun(
          range: NSRange(location: index * 2 + 1, length: 1),
          box: CGRect(x: box.minX + box.width * 0.3, y: box.minY, width: box.width * 0.7, height: box.height)
        ),
      ]
    }
    let recognized = OCRResult.Line(
      boundingBoxNormalized: rows.reduce(.null) { $0.union($1) },
      text: "This paragraph keeps its original row alignment.",
      imageAspectRatio: 1.5,
      rowCount: rows.count,
      styleRuns: runs,
      alignment: expected == .center ? .leading : .center
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation("원본 문단의 행 정렬을 유지합니다.", language: .init(identifier: "ko"))
    #expect(line.source.rowAlignment == expected)
    #expect(try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1200, height: 800)).first)
      .alignment == expected)
  }

  @Test
  func anIndentedQuoteCannotCenterItsLeadingParagraph() {
    let boxes = [
      CGRect(x: 0.22, y: 0.51, width: 0.284, height: 0.154),
      CGRect(x: 0.274, y: 0.695, width: 0.174, height: 0.088),
    ]
    let lines = boxes.enumerated().map { index, box in
      var line = OverlayLine(id: UUID(), source: .init(
        recognized: .init(
          boundingBoxNormalized: box,
          text: index == 0
            ? "A left aligned article paragraph"
            : "An indented quotation",
          rowCount: index == 0 ? 5 : 3,
          alignment: index == 0 ? .leading : nil
        ),
        language: .init(identifier: "en")
      ))
      line.showTranslation(index == 0 ? "왼쪽으로 정렬된 기사 본문" : "들여쓴 인용문", language: .init(identifier: "ko"))
      return line
    }
    #expect(OverlayLayoutEngine.placements(for: lines, in: CGSize(width: 1200, height: 820))
      .allSatisfy { $0.alignment == .leading })
  }

  @Test
  func ambiguousArabicRowsRetainTheirSourceEdgeInAKoreanTranslation() throws {
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: CGRect(x: 0.27, y: 0.5, width: 0.5, height: 0.08),
      text: "تشمل الأهداف التقليدية التعلم والاستدلال وتمثيل المعرفة",
      rowCount: 2
    ), language: .init(identifier: "ar")))
    line.showTranslation("전통적인 목표에는 학습과 추론, 지식 표현이 포함됩니다.", language: .init(identifier: "ko"))
    #expect(try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1200, height: 820)).first)
      .alignment == .trailing)
  }

  @Test
  func aViewportEdgeCannotRightAlignLeadingMultilineProse() throws {
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: CGRect(x: 0.52, y: 0.1, width: 0.46, height: 0.2),
      text: "Visible lines of a clipped article",
      rowCount: 6,
      alignment: .leading
    ), language: .init(identifier: "en")))
    line.showTranslation("화면에 보이는 기사의 일부입니다.", language: .init(identifier: "ko"))
    #expect(try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 620, height: 820)).first)
      .alignment == .leading)
  }

  @Test(arguments: [
    ["この段落は", "画面の構造を", "確認しながら", "翻訳します。"],
    ["이 문장은", "화면 구조를", "확인하면서", "번역합니다."],
    ["هذه الفقرة", "تستمر عبر", "عدة أسطر", "في الشاشة."],
    ["הפסקה הזאת", "ממשיכה דרך", "כמה שורות", "על המסך."],
  ])
  func shortUncasedRowsUseGeometryRatherThanLatinCharacterCounts(_ texts: [String]) {
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 0.9,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.025,
      fontWeight: .regular
    )
    let lines = texts.enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.2, y: 0.1 + Double(index) * 0.035, width: 0.3, height: 0.025),
        text: text,
        recognitionGroupID: index < 2 ? 1 : 2,
        appearance: appearance
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 1)
    #expect(result.lines.first?.rowCount == 4)
  }

  @Test(arguments: [false, true], [false, true])
  func physicalParagraphRowsPreserveUncasedSentenceContinuity(_ mirrored: Bool, _ completed: Bool) {
    let texts = [
      "تشمل أبرز التطبيقات محركات البحث المتقدمة",
      "وروبوتات المحادثة والمساعدات" + (completed ? ".[5]" : ""),
      "الافتراضية والمركبات ذاتية القيادة",
      "وتحليل الألعاب الاستراتيجية.",
    ]
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 0.9,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.025,
      fontWeight: .regular
    )
    let lines = texts.enumerated().map { index, text in
      let width: CGFloat = [0.38, 0.35, 0.36, 0.32][index]
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: mirrored ? 0.2 : 0.8 - width,
          y: 0.1 + Double(index) * 0.035,
          width: width,
          height: 0.025
        ),
        text: text,
        recognitionGroupID: index < 2 ? 1 : 2,
        appearance: appearance,
        alignment: mirrored
          ? .leading
          : .trailing
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == (completed ? 2 : 1))
    if !completed {
      #expect(result.lines.first?.text == texts.joined(separator: " "))
      #expect(result.lines.first?.rowCount == 4)
    }
  }

  @Test(arguments: ["النهاية؟", "النهاية.[5]", "文章終わり。", "끝입니다.\"", "समाप्त।", "Finished.[1][2]", "Finished.”[1]"])
  func sentenceEndIncludesUncasedScriptsAndCitations(_ text: String) {
    #expect(OCRTextSemantics.endsSentence(text))
  }

  @Test(arguments: [false, true])
  func citationsAndShortTitleTailsDoNotCreateParagraphContinuations(_ shortTitle: Bool) {
    let texts = shortTitle
      ? ["An independent multiline heading", "Overview", "正文是另外一个完整段落", "这里是第二行的内容。"]
      : [
        "This paragraph contains a complete sentence.",
        "Its final sentence ends here.[5]",
        "another paragraph begins separately",
        "and continues here.",
      ]
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 0.9,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.025,
      fontWeight: .regular
    )
    let lines = texts.enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: 0.2,
          y: 0.1 + Double(index) * 0.035,
          width: shortTitle && index == 1 ? 0.15 : 0.4,
          height: 0.025
        ),
        text: text,
        recognitionGroupID: index < 2 ? 1 : 2,
        appearance: appearance,
        alignment: .leading
      )
    }
    #expect(OCRResult(lines: lines).coalescingParagraphFragments().lines.count == 2)
  }

  @Test(arguments: [false, true], [false, true])
  func repeatedNativeListLabelsRemainIndependentButWrappedProseDoesNot(_ prose: Bool, _ mirrored: Bool) {
    let texts = ["Floating-Point Types", "Numeric Operations", "The Boolean Type", "The Character Type", "Compound Types"]
    let lines = texts.enumerated().map { index, text in
      let width = [0.1, 0.09, 0.105, 0.108, 0.102][index]
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: mirrored ? 1 - 0.085 - width : 0.085,
          y: 0.5 + Double(index) * 0.034,
          width: width,
          height: 0.024
        ),
        text: text,
        recognitionGroupID: prose ? 1 : [1, 2, 3, 3, 4][index],
        recognitionContainer: CGRect(x: mirrored ? 0.795 : 0.025, y: 0.4, width: 0.18, height: 0.3)
      )
    }
    let result = OCRVisualStructure.classifying(.init(lines: lines)).coalescingParagraphFragments()
    if prose {
      #expect(result.lines.count == 1)
      #expect(result.lines.first?.rowCount == 5)
    } else {
      #expect(result.lines.map(\.text) == texts)
      #expect(result.lines.allSatisfy { $0.preventsJoining })
    }
  }

  @Test
  func nativeCellBoundaryCannotBeBridgedByParagraphAppearance() {
    let cells = [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.06), CGRect(x: 0.1, y: 0.165, width: 0.3, height: 0.06)]
    let texts = ["First wrapped", "cell description", "Second cell"]
    let lines = texts.enumerated().map { index, text in
      let box = CGRect(x: 0.1, y: 0.1 + Double(index) * 0.035, width: 0.25, height: 0.025)
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        recognitionGroupID: 1,
        recognitionContainer: OCRParagraphLineGrouping.container(for: box, in: cells),
        alignment: .leading
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.map(\.text) == ["First wrapped cell description", "Second cell"])
    #expect(result.lines.map(\.recognitionContainer) == cells.map(Optional.some))
    #expect(result.coalescingParagraphFragments() == result)
  }

  @Test
  func nestedNativeContainersChooseTheSmallestOwnerWithoutClaimingOutsideText() {
    let outer = CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7)
    let inner = CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.1)
    let row = CGRect(x: 0.21, y: 0.21, width: 0.25, height: 0.03)
    #expect(OCRParagraphLineGrouping.container(for: row, in: [outer, inner]) == inner)
    #expect(OCRParagraphLineGrouping.container(for: row, in: [inner, outer]) == inner)
    #expect(OCRParagraphLineGrouping.container(for: CGRect(x: 0.7, y: 0.79, width: 0.2, height: 0.03), in: [outer]) == nil)
    #expect(OCRParagraphLineGrouping.container(for: .zero, in: [outer]) == nil)
  }

  @Test
  func tallInlineFormulaDoesNotSplitTheRemainingBodyIntoAControl() {
    let text = "Values from (2 - 1) inclusive, where n is the number of bits"
    let source = text as NSString
    let tokens = ["Values from", "(2 - 1)", "inclusive, where n is the number of bits"]
    var cursor = 0
    let runs = tokens.enumerated().map { index, token in
      let range = source.range(of: token, range: NSRange(location: cursor, length: source.length - cursor))
      cursor = NSMaxRange(range)
      let box = CGRect(x: 0.1 + Double(index) * 0.2, y: index == 1 ? 0.18 : 0.2, width: 0.195, height: index == 1 ? 0.05 : 0.025)
      return OverlaySourceStyleRun(range: range, box: box, inkBox: box)
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.18, width: 0.595, height: 0.05),
      text: text,
      styleRuns: runs
    )
    let result = OCRVisualStructure.separatingStyleAccessories(.init(lines: [line]))
    #expect(result.lines.count == 1)
    #expect(result.lines.first?.text == text)
  }

  @Test(arguments: ["1.1.", "3.4.", "12.2.7.", "١.٢."])
  func hierarchicalNavigationItemsKeepTheirOwnTranslationUnits(_ marker: String) {
    let texts = ["1. Getting Started", "\(marker) Installation", "2. Hello, World!"]
    let lines = texts.enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.025, y: 0.14 + Double(index) * 0.035, width: 0.16, height: 0.025),
        text: text,
        recognitionGroupID: 3,
        alignment: .center
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.map(\.text) == texts)
    #expect(result.lines.allSatisfy { $0.rowCount == 1 })
  }

  @Test
  func hierarchicalListContinuationStaysAttachedWithoutAbsorbingNextItem() {
    let texts = ["1.2. Installing the required", "development tools", "1.3. Open a project"]
    let lines = texts.enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: index == 1 ? 0.12 : 0.1, y: 0.1 + Double(index) * 0.035, width: 0.3, height: 0.025),
        text: text,
        recognitionGroupID: 1,
        alignment: .leading
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.map(\.text) == ["1.2. Installing the required development tools", "1.3. Open a project"])
    #expect(result.lines.first?.rowCount == 2)
  }

  @Test(arguments: [
    "Version 1.2. is available",
    "3.14 is approximately pi",
    "1..2. invalid marker",
    "v1.2. release",
    "README.md file"
  ])
  func proseAndIdentifiersAreNotHierarchicalListMarkers(_ text: String) {
    #expect(!OCRTextSemantics.beginsListItem(text))
  }

  @Test(arguments: ["ko", "ar"])
  func numberedNavigationAlignmentFollowsTargetDirection(_ target: String) throws {
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03),
      text: "3.1. Variables and Mutability",
      alignment: .center
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation(target == "ar" ? "3.1. المتغيرات" : "3.1. 변수와 가변성", language: .init(identifier: target))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1200, height: 820)).first)
    #expect(placement.alignment == (target == "ar" ? .trailing : .leading))
  }

  @Test(arguments: [false, true])
  func paragraphAlignmentUsesWholeRowsInsteadOfInlineStyleFragments(_ mirrored: Bool) {
    let edges: [CGFloat] = [0.3, 0.4, 0.25]
    let lines = edges.enumerated().flatMap { index, edge in
      [
        CGRect(x: edge, y: 0.1 + Double(index) * 0.05, width: (0.8 - edge) / 2, height: 0.03),
        CGRect(x: (edge + 0.8) / 2, y: 0.1 + Double(index) * 0.05, width: (0.8 - edge) / 2, height: 0.03),
      ].map { box in
        var box = box
        if mirrored { box.origin.x = 1 - box.maxX }
        return OCRResult.Line(boundingBoxNormalized: box, text: "نص الفقرة مع الروابط", recognitionGroupID: 1, alignment: .center)
      }
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 1)
    #expect(result.lines.first?.alignment == (mirrored ? .leading : .trailing))
  }

  @Test
  func mixedSizeHeadingDoesNotInheritAFictitiousOCRRotation() {
    let heading = CGRect(x: 0.22, y: 0.5228, width: 0.12, height: 0.0286)
    let control = CGRect(x: 0.35, y: 0.5328, width: 0.16, height: 0.0157)
    let line = OCRResult.Line(
      boundingBoxNormalized: heading.union(control),
      text: "Beschreibung [Edit]",
      rotationRadians: 0.038,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 12), box: heading, inkBox: heading),
        .init(range: NSRange(location: 13, length: 6), box: control, inkBox: control),
      ]
    )
    let result = OCRVisualStructure.separatingStyleAccessories(.init(lines: [line]))
    #expect(result.lines.map(\.text) == ["Beschreibung", "[Edit]"])
    #expect(result.lines.allSatisfy { $0.rotationRadians == 0 })
    var actuallyRotated = line
    actuallyRotated.styleRuns[1].inkBox?.origin.y += 0.035
    #expect(OCRVisualStructure.separatingStyleAccessories(.init(lines: [actuallyRotated])).lines.count == 1)
  }

  @Test
  func paragraphMarginSurvivesAnOCRDamagedTerminalCitation() {
    let positions: [CGFloat] = [0.366, 0.398, 0.43, 0.462, 0.494, 0.526, 0.55, 0.607, 0.641, 0.673]
    let lines = positions.enumerated().map { index, y in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.22, y: y, width: 0.27, height: index == 6 ? 0.038 : 0.025),
        text: index == 6 ? "这一个段落结束。（" : "同一个文本段落的内容",
        recognitionGroupID: index < 7 ? 26 : 27
      )
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 2)
    #expect(result.lines[0].rowCount == 7)
    #expect(result.lines[1].rowCount == 3)
  }

  @Test
  func pronunciationReferenceCannotRouteItsAccentMarksAsVietnameseProse() {
    #expect(OCRTextSemantics.isIdentifier("• (Tokyo) J U3\"5 [àízú\"chì] (Nakadaka - [31) [314]"))
    #expect(OCRTextSemantics.isIdentifier("Pronunciation: [ˈswɪft]"))
    #expect(OCRTextSemantics.isIdentifier("• IPA(key): [aizitsi]"))
    #expect(!OCRTextSemantics.isIdentifier("The tsuchi changes to zuchi as an instance of rendaku （連濁）."))
    #expect(!OCRTextSemantics.isIdentifier("[Bonjour tout le monde]"))
    #expect(!OCRTextSemantics.isIdentifier("[Xin chào]"))
  }

  @Test
  func recoveryCannotDiscardTheUnrecognizedHalfOfAnOverlap() {
    let top = CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.1)
    let bottom = CGRect(x: 0.1, y: 0.16, width: 0.04, height: 0.1)
    #expect(!OCRConflictRecovery.coversOwners([top, bottom], with: [top]))
    #expect(OCRConflictRecovery.coversOwners([top, bottom], with: [top.union(bottom)]))
  }

  @Test
  func paragraphOwnershipCannotJumpOverAnIndependentRow() {
    var first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.05),
      text: "First paragraph fragment",
      recognitionGroupID: 1,
      alignment: .leading
    )
    var middle = first
    middle.boundingBoxNormalized.origin.y = 0.16
    middle.boundingBoxNormalized.size.height = 0.02
    middle.text = "Independent middle row"
    middle.preventsJoining = true
    var last = first
    last.boundingBoxNormalized.origin.y = 0.20
    last.text = "Last paragraph fragment"
    first.appearance.confidence = 1
    let result = OCRResult(lines: [first, middle, last]).coalescingParagraphFragments()
    #expect(result.lines.count == 3)
    #expect(!result.lines.contains { $0.text.contains("First") && $0.text.contains("Last") })
  }

  @Test
  func tableControlsDoNotClaimRowsInTheNeighboringArticle() {
    let lines = (0..<3).flatMap { index in
      let y = 0.1 + Double(index) * 0.05
      return [
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.01, y: y, width: 0.25, height: 0.025),
          text: "An article continues on this row"
        ),
        OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.42, y: y, width: 0.06, height: 0.025), text: "Label \(index)"),
        OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.53, y: y, width: 0.05, height: 0.025), text: "[show]"),
      ]
    }
    let result = OCRVisualStructure.classifying(.init(lines: lines))
    #expect(result.lines.filter { $0.text.hasPrefix("An article") }.allSatisfy { !$0.preventsJoining })
    #expect(result.lines.filter { $0.text.hasPrefix("Label") }.allSatisfy { $0.preventsJoining })
  }

  @Test
  func maskedRecognitionCanCorrectTheSameColumnButCannotReplaceAnotherBalloon() {
    let old = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.04, height: 0.1),
      text: "献B",
      recognitionConfidence: 0.5,
      isVerticalBlock: true
    )
    var corrected = old
    corrected.text = "前日"
    corrected.recognitionConfidence = 0.95
    #expect(OCRBalloonRefiner.replacingVerticalHypotheses([old], with: [corrected])[0].text == "前日")
    corrected.boundingBoxNormalized.origin.x = 0.5
    #expect(OCRBalloonRefiner.replacingVerticalHypotheses([old], with: [corrected])[0].text == "献B")
  }

  @Test
  func shortUprightCJKColumnsDoNotNeedRotatedCornerVectors() {
    let size = CGSize(width: 1000, height: 1000)
    #expect(OCRGeometry.isVertical(
      text: "だから",
      topLeft: .zero,
      topRight: CGPoint(x: 0.03, y: 0),
      imageSize: size,
      declaredVertical: false,
      bounds: CGRect(x: 0, y: 0, width: 0.03, height: 0.09)
    ))
    #expect(!OCRGeometry.isVertical(
      text: "横に読む本文です",
      topLeft: .zero,
      topRight: CGPoint(x: 0.12, y: 0),
      imageSize: size,
      declaredVertical: false,
      bounds: CGRect(x: 0, y: 0, width: 0.12, height: 0.07)
    ))
    #expect(OCRGeometry.verticalCharacterScale(
      text: "うんで",
      bounds: CGRect(x: 0, y: 0, width: 0.08, height: 0.09),
      imageSize: size
    ) == 0.03)
  }

  @Test
  func verticalRubyIsErasedWithItsBaseAndNeverBecomesASeparateSentence() throws {
    let base = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.04, height: 0.16),
      text: "漢字",
      isVerticalBlock: true,
      verticalCharScale: 0.04
    )
    let ruby = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.246, y: 0.11, width: 0.012, height: 0.06),
      text: "かんじ",
      isVerticalBlock: true,
      verticalCharScale: 0.012
    )
    let result = OCRResult(lines: [base, ruby]).absorbingRubyAnnotations()
    #expect(result.lines.count == 1)
    let line = try #require(result.lines.first)
    #expect(line.text == "漢字")
    #expect(line.verticalCharScale == 0.04)
    #expect(line.replacementPatches.contains(where: { $0.box == ruby.boundingBoxNormalized }))
  }

  @Test
  func repeatedTableControlsKeepEveryLabelInItsOwnRow() {
    let lines = ["組織", "著作", "一覧"].enumerated().flatMap { index, text in
      [
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.1, y: 0.1 + Double(index) * 0.04, width: 0.06, height: 0.025),
          text: text,
          recognitionGroupID: 1
        ),
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.3, y: 0.1 + Double(index) * 0.04, width: 0.05, height: 0.025),
          text: "[表示]",
          recognitionGroupID: 2
        ),
      ]
    }
    let result = OCRVisualStructure.classifying(.init(lines: lines)).coalescingParagraphFragments()
    #expect(result.lines.count == 6)
    #expect(result.lines.map(\.text) == lines.map(\.text))
  }

  @Test
  func wrappedHeadlineUsesParagraphContextForItsShortLastRow() {
    let words = ["La nouvelle génération", "d'Apple Intelligence est", "disponible dès", "aujourd'hui"]
    let lines = words.enumerated().map { index, text in
      var line = OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: 0.2,
          y: 0.1 + Double(index) * 0.05,
          width: index == 3 ? 0.16 : 0.26,
          height: 0.04
        ),
        text: text,
        horizontalInkScale: 0.03,
        recognitionGroupID: index == 3 ? 2 : 1,
        alignment: .leading
      )
      line.appearance = .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        foregroundConfidence: 0.4,
        fontSizeScale: index == 3 ? 0.05 : 0.04
      )
      return line
    }
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 1)
    #expect(result.joinedText == words.joined(separator: " "))
  }

  @Test
  func oneOCRLookalikeCannotSelectAnUnrelatedTranslationModel() {
    let broken = "integers, floating-point numbers, Boc recognize these from other programı they work in Rust."
    let context = "This chapter introduces primitive types and explains how to use the standard library. Review the examples before continuing."
    let result = LanguageDetectionClient.liveValue.resolveSources(for: [context, broken, "JA 6 languages v"], configured: .auto)
    #expect(result.allSatisfy { $0.localeLanguage.languageCode?.identifier == "en" })
  }
}
