// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Testing
@testable import SwiftyCrow

@Suite("Mixed-script paragraph direction")
struct MixedDirectionLayoutTests {

  // MARK: Internal

  struct Sample: Sendable {
    let language: String
    let text: String
    let direction: OverlayInlineDirection
  }

  static let samples = [
    Sample(language: "ar", text: "v2 كيفية الاستخدام", direction: .rightToLeft),
    Sample(language: "he", text: "API הוראות שימוש", direction: .rightToLeft),
    Sample(language: "ar", text: "Rust (2026): إعدادات الخصوصية", direction: .rightToLeft),
    Sample(language: "he", text: "v2.1 — הגדרות פרטיות", direction: .rightToLeft),
    Sample(language: "en", text: "مرحبا settings and privacy", direction: .leftToRight),
    Sample(language: "en", text: "שלום account preferences", direction: .leftToRight),
  ]

  static let wrapped = [
    Sample(
      language: "ar",
      text: "v2 كيفية الاستخدام وإعدادات الخصوصية API 2026 وطريقة العرض على الشاشة",
      direction: .rightToLeft
    ),
    Sample(language: "he", text: "API הוראות שימוש והגדרות פרטיות v2.1 עבור המשתמש והתצוגה במסך", direction: .rightToLeft),
    Sample(
      language: "en",
      text: "مرحبا Internationalization configuration and accessibility settings for everyone",
      direction: .leftToRight
    ),
    Sample(
      language: "en",
      text: "هذه إرشادات تفصيلية لطريقة الاستخدام وإعدادات الخصوصية Internationalization لجميع المستخدمين",
      direction: .rightToLeft
    ),
  ]

  @Test(arguments: wrapped, [false, true])
  func wrappedRunsRetainParagraphContextAndLogicalCoverage(_ sample: Sample, _ shaped: Bool) {
    let language = Locale.Language(identifier: sample.language)
    #expect(OverlayTextFlowResolver.horizontalFlow(text: sample.text, language: language) == .horizontal(sample.direction))
    let width: CGFloat = 160
    let plan = HorizontalTextRenderer.plan(
      text: sample.text,
      language: language,
      fontSize: 24,
      appearance: Self.appearance,
      styles: [],
      width: width,
      lineHeightMultiple: 1,
      regions: shaped ? [CGRect(x: 0, y: 0, width: width, height: 1_000)] : [],
      height: 1_000
    )
    #expect(plan.complete)
    #expect(plan.lines.count > 1)
    let typesetter = CTTypesetterCreateWithAttributedString(Self.referenceString(
      sample.text,
      language: language,
      direction: sample.direction
    ))
    var cursor = 0
    let legalBreaks = HorizontalHyphenation.wordBreaks(in: sample.text, language: language)
    for (index, line) in plan.lines.enumerated() {
      let range = CTLineGetStringRange(line)
      #expect(range.location == cursor)
      cursor += range.length
      let expected = CTTypesetterCreateLine(typesetter, range)
      #expect(CTLineGetGlyphCount(line) == CTLineGetGlyphCount(expected))
      for offset in range.location..<range.location + range.length {
        #expect(abs(CTLineGetOffsetForStringIndex(line, offset, nil) - CTLineGetOffsetForStringIndex(expected, offset, nil)) <
          0.001)
      }
      if let suffix = plan.hyphens[index] {
        #expect(legalBreaks.contains { word, points in points.contains { word.location + $0.offset == cursor } })
        #expect(CTLineGetGlyphCount(suffix) > 0)
        #expect(plan.ink(for: index).maxX > CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).maxX)
      }
    }
    #expect(cursor == sample.text.utf16.count)
    if sample.language == "en" { #expect(!plan.hyphens.isEmpty) }
  }

  @Test(arguments: samples, [false, true])
  func completeRunsUseTheResolvedParagraphDirection(_ sample: Sample, _ shaped: Bool) throws {
    let language = Locale.Language(identifier: sample.language)
    #expect(OverlayTextFlowResolver.horizontalFlow(text: sample.text, language: language) == .horizontal(sample.direction))
    let plan = HorizontalTextRenderer.plan(
      text: sample.text,
      language: language,
      fontSize: 24,
      appearance: Self.appearance,
      styles: [],
      width: 800,
      lineHeightMultiple: 1,
      regions: shaped ? [CGRect(x: 0, y: 0, width: 800, height: 120)] : [],
      height: 120
    )
    #expect(plan.complete)
    #expect(plan.lines.count == 1)
    let actual = try #require(plan.lines.first)
    Self.expectSameCursors(
      actual,
      Self.reference(sample.text, language: language, direction: sample.direction),
      text: sample.text
    )
  }

  @Test(arguments: [OverlayInlineDirection.leftToRight, .rightToLeft], [CGFloat.zero, .pi / 2])
  func placementDirectionIsAuthoritativeRegardlessOfTargetOrientation(
    _ direction: OverlayInlineDirection,
    _ angle: CGFloat
  ) throws {
    let sample = Self.samples[1]
    let line = Self.line(sample)
    var placement = OverlayPlacement(
      line: line,
      flow: .horizontal(direction),
      sourceFrame: .zero,
      frame: CGRect(x: 50, y: 30, width: 800, height: 120),
      placementBounds: .zero,
      fontSize: 24,
      lineHeightMultiple: 1,
      alignment: .center
    )
    placement.targetRotationRadians = angle
    let actual = try #require(HorizontalTextRenderer.plan(for: placement).lines.first)
    Self.expectSameCursors(
      actual,
      Self.reference(sample.text, language: line.displayedLanguage, direction: direction),
      text: sample.text
    )
    #expect(placement.line.displayedText == sample.text)
  }

  @Test(arguments: [OverlayTextAlignment.leading, .center, .trailing], [(0, false), (0, true), (4, false), (4, true)])
  func logicalDirectionDoesNotMoveThePhysicalReadingEdge(_ alignment: OverlayTextAlignment, _ variant: (Int, Bool)) throws {
    let sample = Self.samples[variant.0]
    let shaped = variant.1
    let frame = CGRect(x: 50, y: 30, width: 800, height: 120)
    let placement = OverlayPlacement(
      line: Self.line(sample),
      flow: .horizontal(sample.direction),
      sourceFrame: .zero,
      frame: frame,
      placementBounds: frame,
      fontSize: 24,
      lineHeightMultiple: 1,
      alignment: alignment,
      textFlowRegions: shaped
        ? [CGRect(origin: .zero, size: frame.size)]
        : []
    )
    let ink = try #require(HorizontalTextRenderer.paintedBounds(for: placement).first)
    switch alignment {
    case .leading: #expect(abs(ink.minX - frame.minX) < 1e-6)
    case .center: #expect(abs(ink.midX - frame.midX) < 1e-6)
    case .trailing: #expect(abs(ink.maxX - frame.maxX) < 1e-6)
    }
  }

  // MARK: Private

  private static let appearance = OverlaySourceAppearance(
    background: .white,
    foreground: .black,
    confidence: 1,
    fontWeight: .semibold
  )

  private static func line(_ sample: Sample) -> OverlayLine {
    var line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(
        boundingBoxNormalized: .zero,
        text: "Source",
        appearance: appearance
      ),
      language: .init(identifier: "en")
    ))
    line.showTranslation(sample.text, language: .init(identifier: sample.language))
    return line
  }

  private static func reference(_ text: String, language: Locale.Language, direction: OverlayInlineDirection) -> CTLine {
    CTLineCreateWithAttributedString(referenceString(text, language: language, direction: direction))
  }

  private static func referenceString(
    _ text: String,
    language: Locale.Language,
    direction: OverlayInlineDirection
  ) -> NSAttributedString {
    let paragraph = NSMutableParagraphStyle()
    paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
    paragraph.alignment = .left
    return NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
      .paragraphStyle: paragraph,
      NSAttributedString.Key(kCTLanguageAttributeName as String): language.maximalIdentifier,
    ])
  }

  private static func expectSameCursors(_ actual: CTLine, _ expected: CTLine, text: String) {
    #expect(CTLineGetGlyphCount(actual) == CTLineGetGlyphCount(expected))
    for index in 0..<text.utf16.count {
      let a = CTLineGetOffsetForStringIndex(actual, index, nil)
      let b = CTLineGetOffsetForStringIndex(expected, index, nil)
      #expect(abs(a - b) < 0.001, "Logical UTF-16 position \(index) was placed on the wrong visual side")
    }
  }
}
