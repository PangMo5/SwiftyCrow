// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Horizontal capture compositor")
struct HorizontalTextRendererTests {
  @Test(arguments: [("en", "A B"), ("ar", "نص عربي")])
  func inlineBackgroundIsPaintedOnceByNativeCoreText(_ sample: (String, String)) throws {
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: .init(red: 0, green: 0, blue: 0, alpha: 0),
      confidence: 1,
      fontWeight: .regular
    )
    var highlight = base
    highlight.background = .init(red: 1, green: 1, blue: 0, alpha: 0.5)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Source",
      appearance: base,
      styleRuns: [.init(
        range: NSRange(location: 0, length: 6),
        box: CGRect(x: 0, y: 0, width: 1, height: 1),
        appearance: highlight
      )]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    var translated = AttributedString(sample.1)
    translated.link = URL(string: "swiftycrow-style://run/0")!
    line.showTranslation(sample.1, attributedText: translated, language: .init(identifier: sample.0))
    let frame = CGRect(x: 0, y: 0, width: 300, height: 100)
    let placement = OverlayPlacement(
      line: line,
      flow: .horizontal(sample.0 == "ar" ? .rightToLeft : .leftToRight),
      sourceFrame: frame,
      frame: frame,
      placementBounds: frame,
      fontSize: 32,
      lineHeightMultiple: 1,
      alignment: .leading
    )
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: 1))
    let context = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: frame)
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let alpha = stride(from: 3, to: image.width * image.height * 4, by: 4).map { bytes[$0] }
    #expect(alpha.count(where: { $0 > 0 }) > 100)
    let opacity = CGFloat(try #require(alpha.max())) / 255
    #expect(opacity >= 0.49 && opacity <= 0.51)
  }

  @Test(arguments: ["\u{00A0}", "\u{2007}", "\u{202F}"], [false, true])
  func dictionaryHyphenationDoesNotBreakANonbreakingSpace(_ separator: String, _ shaped: Bool) {
    let text = "a" + separator + "Implication"
    let plan = HorizontalTextRenderer.plan(
      text: text,
      language: .init(identifier: "en"),
      fontSize: 18,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular),
      styles: [],
      width: 50,
      lineHeightMultiple: 1,
      regions: shaped ? [CGRect(x: 0, y: 0, width: 50, height: 250)] : [],
      height: shaped ? 250 : nil
    )
    #expect(plan.fits(CGSize(width: 50, height: 250)))
    #expect(!plan.hyphens.isEmpty)
    for line in plan.lines {
      let range = CTLineGetStringRange(line)
      let end = range.location + range.length
      #expect(end != 1 && end != 2, "A no-break space must stay attached to both neighboring words")
    }
    #expect(plan.lines.reduce(0) { $0 + CTLineGetStringRange($1).length } == (text as NSString).length)
  }

  @Test(arguments: [("en", "Implication"), ("de", "Implikation"), ("de", "Einstimmen")])
  func dictionaryHyphenationKeepsNarrowLabelsReadable(_ sample: (String, String)) {
    let language = Locale.Language(identifier: sample.0)
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    let font = CoreTextTypesetter.horizontalWordFittedFontSize(
      text: sample.1,
      language: language,
      constrainedToWidth: 40,
      preferred: 18,
      minimum: 4,
      fontWeight: .regular
    )
    #expect(font >= 16)
    let plan = HorizontalTextRenderer.plan(
      text: sample.1,
      language: language,
      fontSize: font,
      appearance: appearance,
      styles: [],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(plan.fits(CGSize(width: 40, height: 150)))
    #expect(!plan.hyphens.isEmpty)
    #expect(plan.lines.map { CTLineGetStringRange($0).length }.reduce(0, +) == sample.1.utf16.count)
    let legal = Set(HorizontalHyphenation.boundaries(in: sample.1, language: language).map(\.offset))
    for (index, hyphen) in plan.hyphens {
      let range = CTLineGetStringRange(plan.lines[index])
      #expect(legal.contains(range.location + range.length))
      #expect(CTLineGetGlyphCount(hyphen) > 0)
      #expect(CTLineGetBoundsWithOptions(hyphen, [.useGlyphPathBounds]).width > 0)
      #expect(plan.ink(for: index).width <= 40.5)
    }
  }

  @Test
  func discretionaryHyphenNeverChangesLogicalTextOrCrossesNewlines() {
    let text = "Implication\nImplication"
    let plan = HorizontalTextRenderer.plan(
      text: text,
      language: .init(identifier: "en"),
      fontSize: 18,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular),
      styles: [],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    let ranges = plan.lines.map { CTLineGetStringRange($0) }
    #expect(ranges.map { (text as NSString).substring(with: NSRange(location: $0.location, length: $0.length)) }.joined() == text)
    for (index, _) in plan.hyphens {
      let range = ranges[index]
      #expect((text as NSString).character(at: range.location + range.length - 1) != 10)
    }
  }

  @Test(arguments: ["الاستعمال", "foo_bar", "https://example.com", "ABCDEF", "👩🏽‍💻"])
  func dictionaryBoundariesDoNotInventBreaksForLiteralsOrUnsupportedScript(_ word: String) {
    let language = Locale.Language(identifier: word == "الاستعمال" ? "ar" : "en")
    #expect(HorizontalHyphenation.boundaries(in: word, language: language).isEmpty)
    let plan = HorizontalTextRenderer.plan(
      text: word,
      language: language,
      fontSize: 18,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular, fontDesign: .monospaced),
      styles: [],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(plan.hyphens.isEmpty)
  }

  @Test
  func shapedPunctuatedWordsUseDictionaryBoundariesAndVisibleHyphens() {
    let text = "Yeah, I understand. I'll do that."
    let language = Locale.Language(identifier: "en")
    let plan = HorizontalTextRenderer.plan(
      text: text,
      language: language,
      fontSize: 22,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular),
      styles: [],
      width: 200,
      lineHeightMultiple: 1,
      regions: [CGRect(x: 0, y: 0, width: 90, height: 300)],
      height: 300
    )
    #expect(plan.complete)
    #expect(plan.fits(CGSize(width: 200, height: 300)))
    let words = HorizontalHyphenation.wordRanges(in: text, language: language)
    for (index, line) in plan.lines.enumerated() {
      let range = CTLineGetStringRange(line)
      let end = range.location + range.length
      if let word = words.first(where: { $0.location < end && NSMaxRange($0) > end }) {
        let token = (text as NSString).substring(with: word)
        let legal = HorizontalHyphenation.boundaries(in: token, language: language)
        #expect(legal.contains(where: { word.location + $0.offset == end }))
        #expect(plan.hyphens[index] != nil)
      }
    }
  }

  @Test
  func monospacedWordsNeverAcquireDiscretionaryHyphens() {
    let plan = HorizontalTextRenderer.plan(
      text: "Implication",
      language: .init(identifier: "en"),
      fontSize: 18,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular, fontDesign: .monospaced),
      styles: [],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(plan.hyphens.isEmpty)
  }

  @Test
  func discretionaryHyphenInheritsItsWordStyle() throws {
    let base = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    let highlight = OverlaySourceAppearance(
      background: .init(red: 0.1, green: 0.2, blue: 0.3, alpha: 1),
      foreground: .white,
      confidence: 1,
      fontWeight: .bold,
      isUnderlined: true
    )
    let plan = HorizontalTextRenderer.plan(
      text: "Implication",
      language: .init(identifier: "en"),
      fontSize: 18,
      appearance: base,
      styles: [.init(range: NSRange(location: 0, length: 11), appearance: highlight)],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(!plan.hyphens.isEmpty)
    for hyphen in plan.hyphens.values {
      let run = try #require((CTLineGetGlyphRuns(hyphen) as! [CTRun]).first)
      let attributes = CTRunGetAttributes(run) as NSDictionary
      #expect((attributes[NSAttributedString.Key.underlineStyle] as? Int) == NSUnderlineStyle.single.rawValue)
      let background = try #require(attributes[NSAttributedString.Key.backgroundColor] as? NSColor)
      #expect(abs(background.redComponent - highlight.background.red) < 0.001)
      let font = try #require(attributes[NSAttributedString.Key.font] as? NSFont)
      #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
    }
  }

  @Test
  func anUnbreakableSyllableIsRejectedInsteadOfSplittingAtAnArbitraryGlyph() {
    let plan = HorizontalTextRenderer.plan(
      text: "Implication",
      language: .init(identifier: "en"),
      fontSize: 30,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular),
      styles: [],
      width: 8,
      lineHeightMultiple: 1
    )
    #expect(!plan.fits(CGSize(width: 8, height: 1000)))
  }

  @Test(arguments: [40.0, 40.25, 41.0, 42.0])
  func fittedSizeStillFitsAfterQuarterPointQuantization(_ preferred: CGFloat) {
    let text = "In the ninth inning table, we formed a circle in front of the last attack. At the director's words, we hit each other again and again. It's like it's definitely going to be reversed\" \"Oh!\" All of them answered strongly."
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Source",
      appearance: appearance
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "ja")))
    line.showTranslation(text, language: .init(identifier: "en"))
    let size = CGSize(width: 312.87260068150556, height: 607.0725984574634)
    let font = HorizontalTextRenderer.fittedLayout(line: line, in: size, preferred: preferred, lineHeightMultiple: 1).fontSize
    let plan = HorizontalTextRenderer.plan(
      text: text,
      language: .init(identifier: "en"),
      fontSize: font,
      appearance: appearance,
      styles: [],
      width: size.width,
      lineHeightMultiple: 1
    )
    #expect(plan.fits(size), "The returned font must fit; rounding may change Core Text's line breaks")
    #expect(plan.lines.map { CTLineGetStringRange($0).length }.reduce(0, +) == text.utf16.count)
  }

  @Test(arguments: [("ko", "좋은 아이디어가 자랍니다"), ("ar", "الأفكار الجيدة تنمو")])
  func centeredInkDoesNotInheritAsymmetricOCRPadding(_ sample: (String, String)) throws {
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.08,
      fontWeight: .regular
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.35, y: 0.27, width: 0.2792, height: 0.104),
      text: "Good ideas grow",
      appearance: appearance,
      styleRuns: [.init(
        range: NSRange(location: 0, length: 15),
        box: CGRect(x: 0.35, y: 0.27, width: 0.2792, height: 0.104),
        appearance: appearance,
        inkBox: CGRect(
          x: 0.37375,
          y: 0.28125,
          width: 0.25125,
          height: 0.08
        )
      )],
      layoutBounds: CGRect(x: 0.01, y: 0.2, width: 0.98, height: 0.25),
      alignment: .center
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation(sample.1, language: .init(identifier: sample.0))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 320)).first)
    let expectedAxis: CGFloat = 399.5
    #expect(abs(placement.frame.midX - expectedAxis) < 0.01)
    #expect(abs(placement.sourceFrame.midX - 391.68) < 0.01)
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: 1))
    let context = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let columns = (0..<image.width)
      .filter { x in (0..<image.height).contains { y in pixels[(y * image.width + x) * 4 + 3] > 40 } }
    let first = try #require(columns.first)
    let last = try #require(columns.last)
    let actualAxis = placement.frame.minX + CGFloat(first + last + 1) / 2
    #expect(abs(actualAxis - expectedAxis) <= 1)
  }

  @Test(arguments: [
    (
      "en",
      "A complete paragraph should flow beside the figure before using the full width beneath it. Every word must remain visible."
    ),
    ("ko", "문단은 그림 옆에서 시작하고 아래쪽에서는 전체 너비를 사용해야 합니다. 모든 단어가 잘리지 않고 자연스럽게 표시되어야 합니다."),
    ("ar", "يجب أن تظهر الفقرة بجوار الصورة ثم تستخدم المساحة الكاملة تحتها. يجب أن تبقى جميع الكلمات واضحة ومقروءة."),
  ], [false, true])
  func shapedParagraphKeepsAllTextOutsideTheFigure(_ sample: (String, String), _ mirrored: Bool) throws {
    let regions = [CGRect(x: mirrored ? 0 : 0.35, y: 0, width: 0.65, height: 0.5), CGRect(x: 0, y: 0.5, width: 1, height: 0.5)]
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Original paragraph",
      rowCount: 6,
      textFlowRegions: regions,
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: 0.1,
        fontWeight: .regular
      ),
      alignment: sample.0 == "ar" ? .trailing : .leading
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
    line.showTranslation(sample.1, language: .init(identifier: sample.0))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 360, height: 180)).first)
    let plan = HorizontalTextRenderer.plan(for: placement)
    #expect(plan.complete)
    #expect(plan.usesContainerCoordinates)
    #expect(plan.fits(placement.frame.size))
    #expect(plan.lines.map { CTLineGetStringRange($0).length }.reduce(0, +) == sample.1.utf16.count)
    #expect(placement.fontSize >= 14)
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: 1))
    let context = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let exclusion = CGRect(x: mirrored ? 234 : 0, y: 0, width: 126, height: 90).offsetBy(
      dx: -placement.frame.minX,
      dy: -placement.frame.minY
    )
    for (ctLine, origin) in zip(plan.lines, plan.origins) {
      let ink = CTLineGetBoundsWithOptions(ctLine, [.useGlyphPathBounds]).offsetBy(dx: origin.x, dy: origin.y)
      let topLeft = CGRect(x: ink.minX, y: placement.frame.height - ink.maxY, width: ink.width, height: ink.height)
      let overlap = topLeft.intersection(exclusion)
      #expect(overlap.isNull || overlap.width * overlap.height <= 0.000_001)
      if sample.0 == "ko" {
        let range = CTLineGetStringRange(ctLine)
        let end = range.location + range.length
        if end < sample.1.utf16.count {
          let character = (sample.1 as NSString).character(at: end - 1)
          #expect(CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(character)!))
        }
      }
    }
    var painted = 0
    // Bitmap rows use the image's top-left storage coordinates.
    for y in 0..<image.height {
      for x in 0..<image.width where exclusion.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) {
        if pixels[(y * image.width + x) * 4 + 3] > 0 { painted += 1 }
      }
    }
    #expect(painted == 0)
  }

  @Test
  func ordinaryButtonPaddingKeepsGlyphsVerticallyCentered() throws {
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.1,
      fontWeight: .regular
    )
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.26, width: 0.15, height: 0.08),
      text: "Open",
      appearance: appearance,
      alignment: .center,
      surface: .init(box: CGRect(x: 0.125, y: 0.2, width: 0.3, height: 0.2), confidence: 1)
    )
    var line = OverlayLine(
      id: UUID(),
      source: .init(recognized: source, language: Locale.Language(identifier: "en")),
      initialContent: .pending
    )
    line.showTranslation("열기", language: Locale.Language(identifier: "ko"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 500, height: 200)).first)
    #expect(!placement.expandsVertically)
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: 1))
    let context = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    let occupied = (0..<image.height)
      .filter { y in (0..<image.width).contains { x in pixels[(y * image.width + x) * 4 + 3] > 40 } }
    let top = try #require(occupied.first)
    let bottom = try #require(occupied.last)
    #expect(abs(Double(top + bottom + 1) / 2 - Double(image.height) / 2) <= 2)
  }

  @Test(arguments: [
    ("ko", "설정과 개인정보를 확인하세요. 버전 v3.2.1의 변경 사항입니다."),
    ("ja", "設定とプライバシーを確認してください。バージョン v3.2.1 の変更内容です。"),
    ("zh-Hans", "请检查设置与隐私。这是版本 v3.2.1 的更改内容。"),
    ("zh-Hant", "請檢查設定與隱私。這是版本 v3.2.1 的變更內容。"),
    ("ar", "يرجى مراجعة الإعدادات والخصوصية. الإصدار v3.2.1 متاح الآن."),
    ("he", "נא לבדוק את ההגדרות ואת הפרטיות. גרסה v3.2.1 זמינה עכשיו."),
    ("de", "Überprüfen Sie Einstellungen und Datenschutz. Version v3.2.1 ist verfügbar."),
  ])
  func multilingualParagraphsKeepEveryCharacter(_ sample: (String, String)) {
    let plan = HorizontalTextRenderer.plan(
      text: sample.1,
      language: Locale.Language(identifier: sample.0),
      fontSize: 20,
      appearance: .fallback,
      styles: [],
      width: 230,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    #expect(plan.lines.count > 1)
    let ranges = plan.lines.map { CTLineGetStringRange($0) }
    #expect(ranges.map { $0.length }.reduce(0,+) == sample.1.utf16.count)
    if ["ar", "he"].contains(sample.0) {
      let runs = plan.lines.flatMap { CTLineGetGlyphRuns($0) as! [CTRun] }
      #expect(runs.contains { CTRunGetStatus($0).contains(.rightToLeft) })
      #expect(runs.contains { !CTRunGetStatus($0).contains(.rightToLeft) })
    }
  }

  @Test
  func KoreanWordsAreNotSplitWhenTheyFitAColumn() {
    let text = "우편 투표를 제한하는 노력을 확인하세요." as NSString
    let plan = HorizontalTextRenderer.plan(
      text: text as String,
      language: Locale.Language(identifier: "ko"),
      fontSize: 20,
      appearance: .fallback,
      styles: [],
      width: 120,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    #expect(plan.lines.count > 1)
    for line in plan.lines.dropLast() {
      let range = CTLineGetStringRange(line)
      let end = range.location + range.length
      #expect(CharacterSet.whitespacesAndNewlines.contains(Unicode.Scalar(text.character(at: end - 1))!))
    }
  }

  @Test
  func identicalTranslationRetainsOriginalPixelsAndStillCompletes() {
    let source = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1), text: "AP")
    var line = OverlayLine(
      id: UUID(),
      source: .init(recognized: source, language: Locale.Language(identifier: "en")),
      initialContent: .pending
    )
    line.showTranslation("AP", language: Locale.Language(identifier: "ko"))
    #expect(!line.isPending)
    #expect(!line.shouldReplaceSourcePixels)
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 300, height: 200)).isEmpty)
    #expect(!OverlayLayoutEngine.protectedSourceFrames(
      for: [line],
      placements: [],
      in: CGSize(width: 300, height: 200),
      displayScale: 1
    ).isEmpty)
  }

  @Test(arguments: ["명령줄", "設定", "设置", "Settings", "إعدادات"])
  func fitsVisibleGlyphsWithoutReservingInvisibleFontLeading(_ text: String) {
    let language = Locale.Language(identifier: "ko")
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    let plan = HorizontalTextRenderer.plan(
      text: text,
      language: language,
      fontSize: 32,
      appearance: appearance,
      styles: [],
      width: 400,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    #expect(plan.lines.count == 1)
    #expect(plan.fits(CGSize(width: 400, height: ceil(plan.inkBounds.height))))
    #expect(!plan.fits(CGSize(width: 400, height: plan.inkBounds.height - 2)))
  }

  @Test
  func fitAndRenderUseTheSameMixedStyleParagraph() throws {
    var appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    appearance.fontSizeScale = 0.07
    var emphasis = appearance
    emphasis.fontWeight = .bold
    emphasis.foreground = OverlayColor(red: 0.1, green: 0.4, blue: 0.9, alpha: 1)
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.3),
      text: "Read the documentation before continuing.",
      rowCount: 3,
      appearance: appearance,
      styleRuns: [.init(
        range: NSRange(location: 9, length: 13),
        box: CGRect(x: 0.2, y: 0.1, width: 0.2, height: 0.05),
        appearance: emphasis
      )]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: Locale.Language(identifier: "en")))
    let target = "계속하기 전에 설명서를 읽고 모든 단계를 확인하세요."
    var attributed = AttributedString(target)
    let styledRange = try #require(attributed.range(of: "설명서"))
    attributed[styledRange].link = URL(string: "swiftycrow-style://run/0")
    line.showTranslation(target, attributedText: attributed, language: Locale.Language(identifier: "ko"))
    #expect(line.displayedStyleRuns.count == 1)
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 600, height: 300)).first)
    let plan = HorizontalTextRenderer.plan(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      appearance: line.source.appearance,
      styles: line.displayedStyleRuns,
      width: placement.frame.width,
      lineHeightMultiple: placement.lineHeightMultiple
    )
    #expect(plan.fits(placement.frame.size))
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: 2))
    #expect(image.width == Int(ceil(placement.frame.width * 2)))
    #expect(image.height == Int(ceil(placement.frame.height * 2)))
  }

  @Test
  func longerLabelMustActuallyFitInsteadOfBeingTruncated() {
    let plan = HorizontalTextRenderer.plan(
      text: "A complete sentence must not disappear behind an ellipsis.",
      language: Locale.Language(identifier: "en"),
      fontSize: 24,
      appearance: .fallback,
      styles: [],
      width: 160,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    #expect(plan.lines.count > 1)
    #expect(!plan.fits(CGSize(width: 160, height: 25)))
  }
}
