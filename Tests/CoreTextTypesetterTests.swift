// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Core Text typesetting")
struct CoreTextTypesetterTests {

  // MARK: Internal

  struct VerticalCase: Sendable, CustomTestStringConvertible {
    let language: String
    let text: String
    var fontSize: CGFloat = 24
    var height: CGFloat = 190
    var fontWeight = OverlayFontWeight.semibold

    var testDescription: String {
      "\(language) \(fontSize)pt \(height)h"
    }
  }

  struct WordColumnCase: Sendable {
    let text: String
    let words: [String]
    let preferred: CGFloat
    let height: CGFloat
  }

  @Test(
    arguments: [OverlayColumnProgression.rightToLeft, .leftToRight],
    [(CGFloat(0), CGFloat(0.5)), (0.5, 0.5), (1, 0.5), (0, 1), (0.5, 1), (1, 1)]
  )
  func verticalInlineBackgroundHasItsOwnOpacity(
    _ progression: OverlayColumnProgression,
    _ alpha: (CGFloat, CGFloat)
  ) throws {
    let text = "한글\n😀"
    let foreground = OverlayColor(red: 0, green: 0, blue: 0, alpha: alpha.0)
    let style = OverlaySourceAppearance(
      background: .init(red: 1, green: 1, blue: 0, alpha: alpha.1),
      foreground: foreground,
      confidence: 1,
      fontWeight: .regular,
      isUnderlined: true
    )
    let image = try #require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 32,
      fontWeight: .regular,
      size: CGSize(width: 160, height: 150),
      scale: 2,
      progression: progression,
      foreground: foreground,
      styles: [.init(range: NSRange(location: 0, length: text.utf16.count), appearance: style)]
    ))
    let pixels = try verticalPixels(image)
    let background = yellowBackgroundAlpha(in: pixels)
    #expect(background.count > 100)
    let maximum = try #require(background.max())
    #expect(abs(CGFloat(maximum) / 255 - alpha.1) < 0.01)
    if alpha.0 == 0 {
      let visible = stride(from: 3, to: pixels.count, by: 4).count(where: { pixels[$0] > 0 })
      #expect(visible == background.count, "Transparent text must also hide color emoji and underlines")
    }
  }

  @Test(arguments: [OverlayColumnProgression.rightToLeft, .leftToRight])
  func mixedOpacityVerticalHighlightsAreNotRepaintedForEveryGlyphRun(_ progression: OverlayColumnProgression) throws {
    let text = "한글\n😀"
    let highlight = OverlaySourceAppearance(
      background: .init(red: 1, green: 1, blue: 0, alpha: 0.5),
      foreground: .black,
      confidence: 1,
      fontWeight: .regular
    )
    var faded = highlight
    faded.foreground.alpha = 0.5
    let image = try #require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 32,
      fontWeight: .regular,
      size: CGSize(width: 160, height: 150),
      scale: 2,
      progression: progression,
      foreground: .black,
      styles: [
        .init(range: NSRange(location: 0, length: text.utf16.count), appearance: highlight),
        .init(range: (text as NSString).range(of: "😀"), appearance: faded),
      ]
    ))
    let pixels = try verticalPixels(image)
    let background = yellowBackgroundAlpha(in: pixels)
    #expect(background.count > 100)
    #expect((background.max() ?? 0) <= 129)
    var hidden = highlight
    hidden.foreground.alpha = 0
    let backgroundOnly = try verticalPixels(#require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 32,
      fontWeight: .regular,
      size: CGSize(width: 160, height: 150),
      scale: 2,
      progression: progression,
      foreground: hidden.foreground,
      styles: [.init(range: NSRange(location: 0, length: text.utf16.count), appearance: hidden)]
    )))
    var plain = highlight
    plain.background = .white
    var plainFaded = faded
    plainFaded.background = .white
    let foregroundOnly = try verticalPixels(#require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 32,
      fontWeight: .regular,
      size: CGSize(width: 160, height: 150),
      scale: 2,
      progression: progression,
      foreground: .black,
      styles: [
        .init(range: NSRange(location: 0, length: text.utf16.count), appearance: plain),
        .init(range: (text as NSString).range(of: "😀"), appearance: plainFaded),
      ]
    )))
    var maximumError = 0
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let remaining = 1 - Double(foregroundOnly[offset + 3]) / 255
      for channel in 0..<4 {
        let expected = Double(foregroundOnly[offset + channel]) + Double(backgroundOnly[offset + channel]) * remaining
        maximumError = max(maximumError, abs(Int(pixels[offset + channel]) - Int(expected.rounded())))
      }
    }
    #expect(maximumError <= 2, "Highlights and glyph opacity must compose independently")
  }

  @Test(arguments: [
    ("한글", OverlayFontDesign.standard, CGFloat(4), CGFloat(1)),
    ("한글", OverlayFontDesign.standard, CGFloat(4), CGFloat(2)),
    ("한글", OverlayFontDesign.standard, CGFloat(8), CGFloat(1)),
    ("한글", OverlayFontDesign.standard, CGFloat(8), CGFloat(2)),
    ("한글", OverlayFontDesign.standard, CGFloat(24), CGFloat(1)),
    ("한글", OverlayFontDesign.standard, CGFloat(24), CGFloat(2)),
    ("한글", OverlayFontDesign.standard, CGFloat(48), CGFloat(1)),
    ("한글", OverlayFontDesign.standard, CGFloat(48), CGFloat(2)),
    ("😀", OverlayFontDesign.standard, CGFloat(4), CGFloat(1)),
    ("😀", OverlayFontDesign.standard, CGFloat(4), CGFloat(2)),
    ("😀", OverlayFontDesign.standard, CGFloat(8), CGFloat(1)),
    ("😀", OverlayFontDesign.standard, CGFloat(8), CGFloat(2)),
    ("😀", OverlayFontDesign.standard, CGFloat(24), CGFloat(1)),
    ("😀", OverlayFontDesign.standard, CGFloat(24), CGFloat(2)),
    ("😀", OverlayFontDesign.standard, CGFloat(48), CGFloat(1)),
    ("😀", OverlayFontDesign.standard, CGFloat(48), CGFloat(2)),
    ("AB", OverlayFontDesign.standard, CGFloat(4), CGFloat(1)),
    ("AB", OverlayFontDesign.standard, CGFloat(4), CGFloat(2)),
    ("AB", OverlayFontDesign.standard, CGFloat(8), CGFloat(1)),
    ("AB", OverlayFontDesign.standard, CGFloat(8), CGFloat(2)),
    ("AB", OverlayFontDesign.standard, CGFloat(24), CGFloat(1)),
    ("AB", OverlayFontDesign.standard, CGFloat(24), CGFloat(2)),
    ("AB", OverlayFontDesign.standard, CGFloat(48), CGFloat(1)),
    ("AB", OverlayFontDesign.standard, CGFloat(48), CGFloat(2)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(4), CGFloat(1)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(4), CGFloat(2)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(8), CGFloat(1)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(8), CGFloat(2)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(24), CGFloat(1)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(24), CGFloat(2)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(48), CGFloat(1)),
    ("한글...", OverlayFontDesign.monospaced, CGFloat(48), CGFloat(2)),
  ], [OverlayColumnProgression.rightToLeft, .leftToRight])
  func highlightedVerticalTextRetainsAllPaintAtTheMeasuredWidth(
    _ sample: (String, OverlayFontDesign, CGFloat, CGFloat),
    _ progression: OverlayColumnProgression
  ) throws {
    let style = OverlaySourceAppearance(
      background: .init(red: 1, green: 1, blue: 0, alpha: 0.5),
      foreground: .black,
      confidence: 1,
      fontWeight: .regular,
      fontDesign: sample.1,
      isUnderlined: true
    )
    let styles = [OverlayTextStyleRun(range: NSRange(location: 0, length: sample.0.utf16.count), appearance: style)]
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: sample.0,
      language: .init(identifier: "ko"),
      fontSize: sample.2,
      fontWeight: .regular,
      fontDesign: sample.1,
      constrainedToHeight: sample.2 * 12,
      styles: styles,
      isUnderlined: true
    )
    func mass(extraWidth: CGFloat) throws -> UInt64 {
      let image = try #require(CoreTextTypesetter.verticalGlyphImage(
        text: sample.0,
        language: .init(identifier: "ko"),
        fontSize: sample.2,
        fontWeight: .regular,
        fontDesign: sample.1,
        size: CGSize(width: plan.requiredWidth + extraWidth, height: sample.2 * 12),
        scale: sample.3,
        progression: progression,
        foreground: .black,
        styles: styles,
        isUnderlined: true
      ))
      let pixels = try verticalPixels(image)
      return stride(from: 3, to: pixels.count, by: 4).reduce(UInt64(0)) { $0 + UInt64(pixels[$1]) }
    }
    let tight = try mass(extraWidth: 0)
    let loose = try mass(extraWidth: 200)
    #expect(tight > 1000)
    #expect(tight == loose, "Measured width must include highlight and underline paint")
  }

  @Test(arguments: ["AB", "مرحبا", "12"], [OverlayColumnProgression.rightToLeft, .leftToRight])
  func mixedDirectionHighlightFollowsItsOwnGlyphs(_ word: String, _ progression: OverlayColumnProgression) throws {
    let text = "한 AB مرحبا 12 글"
    let range = (text as NSString).range(of: word)
    let clear = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0)
    func render(background: OverlayColor, foreground: OverlayColor) throws -> [UInt8] {
      try verticalPixels(#require(CoreTextTypesetter.verticalGlyphImage(
        text: text,
        language: .init(identifier: "ko"),
        fontSize: 24,
        fontWeight: .regular,
        size: CGSize(width: 160, height: 500),
        scale: 1,
        progression: progression,
        foreground: clear,
        styles: [.init(range: range, appearance: .init(
          background: background,
          foreground: foreground,
          confidence: 1,
          fontWeight: .regular
        ))]
      )))
    }
    let glyphs = try render(background: .white, foreground: .black)
    let background = try render(background: .init(red: 1, green: 1, blue: 0, alpha: 1), foreground: clear)
    var ink = 0
    var uncovered = 0
    for y in 0..<500 {
      for x in 0..<160 where glyphs[(y * 160 + x) * 4 + 3] > 30 {
        ink += 1
        var covered = false
        for row in max(0, y - 1)...min(499, y + 1) {
          for column in max(0, x - 1)...min(159, x + 1) {
            if background[(row * 160 + column) * 4 + 3] > 0 { covered = true }
          }
        }
        if !covered { uncovered += 1 }
      }
    }
    #expect(ink > 20)
    #expect(uncovered == 0, "A partial highlight must follow the native visual position of its own script run")
  }

  @Test
  func matchingVerticalBackgroundDoesNotPaintAnotherSurface() throws {
    let color = OverlayColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
    let transparent = OverlayColor(red: 0, green: 0, blue: 0, alpha: 0)
    let style = OverlaySourceAppearance(background: color, foreground: transparent, confidence: 1)
    let image = try #require(CoreTextTypesetter.verticalGlyphImage(
      text: "한글",
      language: .init(identifier: "ko"),
      fontSize: 24,
      size: CGSize(width: 100, height: 120),
      scale: 2,
      progression: .rightToLeft,
      foreground: transparent,
      baseBackground: color,
      styles: [.init(range: NSRange(location: 0, length: 2), appearance: style)]
    ))
    let pixels = try verticalPixels(image)
    #expect(stride(from: 3, to: pixels.count, by: 4).allSatisfy { pixels[$0] == 0 })
  }

  @Test(arguments: [
    WordColumnCase(text: "그래서 시험 전날 정도는...", words: ["그래서", "시험", "전날", "정도는..."], preferred: 33.5, height: 152),
    WordColumnCase(text: "TV만 보지 말고 조금이라도 공부해.", words: ["TV만", "보지", "말고", "조금이라도", "공부해."], preferred: 38.25, height: 165.5),
    WordColumnCase(text: "즐거운", words: ["즐거운"], preferred: 32.18, height: 89.9),
    WordColumnCase(text: "그냥 '응응'이라고 말하는 거 아니야!", words: ["'응응'이라고", "말하는", "아니야!"], preferred: 28.5, height: 217),
    WordColumnCase(text: "함께 읽어요.\n다음 문단입니다.", words: ["읽어요.", "문단입니다."], preferred: 25, height: 100),
    WordColumnCase(text: "각자 즐겁게 👩🏽‍💻 작업해요!", words: ["각자", "즐겁게", "👩🏽‍💻", "작업해요!"], preferred: 28, height: 110),
  ], [OverlayColumnProgression.rightToLeft, .leftToRight])
  func verticalFittingRetainsWholeWordsAndTheirPunctuation(
    _ sample: WordColumnCase,
    _ progression: OverlayColumnProgression
  ) throws {
    let size = CGSize(width: 300, height: sample.height)
    let fitted = CoreTextTypesetter.fittedLayout(
      text: sample.text,
      language: .init(identifier: "ko"),
      flow: .vertical(progression),
      fontWeight: .regular,
      constrainedTo: size,
      preferred: sample.preferred,
      minimum: 8
    )
    let font = fitted.fontSize
    #expect(fitted.verticalWrapping == .words && fitted.isComplete)
    if font + 0.25 <= sample.preferred {
      #expect(!CoreTextTypesetter.fits(
        text: sample.text,
        language: .init(identifier: "ko"),
        flow: .vertical(progression),
        fontSize: font + 0.25,
        fontWeight: .regular,
        in: size
      ))
    }
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: sample.text,
      language: .init(identifier: "ko"),
      fontSize: font,
      fontWeight: .regular,
      constrainedToHeight: sample.height
    )
    let pieces = try substrings(plan.columns, in: sample.text)
    #expect(pieces.joined() == sample.text)
    for word in sample
      .words { #expect(pieces.contains { $0.contains(word) }, "Split protected word: \(word); columns: \(pieces)") }
    #expect(font >= sample.preferred * 0.5)
    #expect(CoreTextTypesetter.verticalColumnsPreserveWords(
      text: sample.text,
      language: .init(identifier: "ko"),
      fontSize: font,
      fontWeight: .regular,
      constrainedToHeight: sample.height
    ))
    #expect(CoreTextTypesetter.verticalGlyphImage(
      text: sample.text,
      language: .init(identifier: "ko"),
      fontSize: font,
      fontWeight: .regular,
      size: size,
      scale: 2,
      progression: progression
    ) != nil)
  }

  @Test(arguments: ["즐거운", "정도는...", "조금이라도"])
  func aWordTallerThanItsColumnIsNotReportedAsFitting(_ text: String) {
    let size = CGSize(width: 500, height: 75)
    #expect(!CoreTextTypesetter.fits(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      fontSize: 35,
      in: size
    ))
    #expect(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 35,
      size: size,
      scale: 1,
      progression: .rightToLeft
    ) == nil)
  }

  @Test(arguments: ["\u{00A0}", "\u{2007}", "\u{202F}"])
  func nonbreakingSpacesRemainPartOfTheWrappingUnit(_ separator: String) {
    let word = "10" + separator + "개"
    let text = word + " 다음"
    #expect(CoreTextTypesetter.wrappingWordRanges(in: text).map { (text as NSString).substring(with: $0) } == [word, "다음"])
    #expect(!CoreTextTypesetter.fits(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      fontSize: 30,
      in: CGSize(width: 500, height: 40)
    ))
  }

  @Test
  func explicitZeroWidthAndParagraphBreaksRemainAvailable() {
    let text = "즐겁게\u{200B}읽어요.\r\n다음 문단"
    let words = CoreTextTypesetter.wrappingWordRanges(in: text).map { (text as NSString).substring(with: $0) }
    #expect(words == ["즐겁게", "읽어요.", "다음", "문단"])
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 20,
      constrainedToHeight: 100
    )
    let columns = plan.columns.map { (text as NSString).substring(with: $0) }
    #expect(columns.joined() == text)
    #expect(columns.contains { $0.hasSuffix("\r\n") })
    #expect(!columns.contains { $0.contains("\n다음") })
  }

  @Test
  func emergencyVerticalWrappingIsAnExplicitReadableLayout() {
    let text = "가나다라마바사아자차카타파하가나다라마바사아자차카타파하"
    let size = CGSize(width: 160, height: 90)
    let fitted = CoreTextTypesetter.fittedLayout(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      constrainedTo: size,
      preferred: 28,
      minimum: 14
    )
    #expect(fitted.isComplete && fitted.verticalWrapping == .characters)
    #expect(fitted.fontSize >= 14)
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: fitted.fontSize,
      constrainedToHeight: size.height,
      wrapping: fitted.verticalWrapping
    )
    #expect(plan.fitsHeight)
    #expect(plan.columns.map { (text as NSString).substring(with: $0) }.joined() == text)
    #expect(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: fitted.fontSize,
      size: size,
      scale: 2,
      progression: .rightToLeft,
      wrapping: fitted.verticalWrapping
    ) != nil)
  }

  @Test(arguments: [CGFloat(1), 2, 3])
  func verticalEllipsisStaysCompactWithoutChangingTextOrClippingDots(_ scale: CGFloat) throws {
    let text = "그래서 시험 전날 정도는..."
    let fitted = CoreTextTypesetter.fittedLayout(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      fontWeight: .regular,
      constrainedTo: CGSize(width: 208, height: 152),
      preferred: 33.5,
      minimum: 6
    )
    #expect(fitted.fontSize >= 30)
    #expect(fitted.verticalWrapping == .words && fitted.isComplete)
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: fitted.fontSize,
      fontWeight: .regular,
      constrainedToHeight: 152
    )
    #expect(plan.columns.map { (text as NSString).substring(with: $0) }.joined() == text)
    func alpha(height: CGFloat) throws -> UInt64 {
      let image = try #require(CoreTextTypesetter.verticalGlyphImage(
        text: "정도는...",
        language: .init(identifier: "ko"),
        fontSize: fitted.fontSize,
        fontWeight: .regular,
        size: CGSize(width: 100, height: height),
        scale: scale,
        progression: .rightToLeft
      ))
      let raster = try #require(CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let pixels = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
      return (0..<(image.width * image.height)).reduce(UInt64.zero) { $0 + UInt64(pixels[$1 * 4 + 3]) }
    }
    let tight = try alpha(height: 152)
    let loose = try alpha(height: 216)
    #expect(loose > 0 && Double(tight) >= Double(loose) * 0.995)
  }

  @Test(arguments: [CGFloat.nan, .infinity, -.infinity, CGFloat(Int.max), CGFloat(Int.max / 4)])
  func invalidFontBoundsCannotReachTheQuarterPointSearch(_ preferred: CGFloat) {
    let fitted = CoreTextTypesetter.fittedLayout(
      text: "읽을 수 있는 글자",
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      constrainedTo: CGSize(width: 200, height: 200),
      preferred: preferred,
      minimum: 6
    )
    #expect(!fitted.isComplete && fitted.fontSize.isFinite)
  }

  @MainActor
  @Test(arguments: [OverlayColor.black, .white, .init(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)])
  func verticalCompositorPreservesEmojiColorAndRequestedTextColor(_ foreground: OverlayColor) throws {
    let size = CGSize(width: 200, height: 300)
    let raster = try #require(CGContext(
      data: nil,
      width: 200,
      height: 300,
      bitsPerComponent: 8,
      bytesPerRow: 800,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let background = OverlayColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    raster.setFillColor(CGColor(gray: 0.5, alpha: 1))
    raster.fill(CGRect(origin: .zero, size: size))
    let data = try #require(raster.makeImage()?.pngData)
    let lines = [("今日は", "오늘", 0.05), ("笑顔", "😀", 0.55)].map { original, target, y in
      let recognized = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.15, y: y, width: 0.7, height: 0.38),
        text: original,
        rowCount: 1,
        isVerticalBlock: true,
        verticalCharScale: 0.15,
        appearance: .init(
          background: background,
          foreground: foreground,
          confidence: 1,
          fontSizeScale: 0.15,
          fontWeight: .regular
        )
      )
      var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "ja")))
      line.source.replacementPatches = []
      line.showTranslation(target, language: .init(identifier: "ko"))
      return line
    }
    let image = try #require(CaptureResultImage.render(
      imageData: data,
      imageSize: size,
      lines: lines,
      prefersHorizontalTextLayout: false
    ))
    let top = try #require(image.cropping(to: CGRect(x: 0, y: 0, width: 200, height: 150)))
    let bottom = try #require(image.cropping(to: CGRect(x: 0, y: 150, width: 200, height: 150)))
    func count(_ image: CGImage, matching test: (UInt8, UInt8, UInt8) -> Bool) throws -> Int {
      let context = try #require(CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      return (0..<(image.width * image.height)).count { test(bytes[$0 * 4], bytes[$0 * 4 + 1], bytes[$0 * 4 + 2]) }
    }
    #expect(try count(bottom) { r, g, b in r > 170 && g > 100 && b < 100 } > 100)
    #expect(try count(top) { r, g, b in
      abs(CGFloat(r) - foreground.red * 255) < 3 && abs(CGFloat(g) - foreground.green * 255) < 3
        && abs(CGFloat(b) - foreground.blue * 255) < 3
    } > 30)
  }

  @Test(arguments: ["😀", "한글"], [OverlayColumnProgression.rightToLeft, .leftToRight])
  func verticalOpacityIncludesColorGlyphs(_ text: String, _ progression: OverlayColumnProgression) throws {
    func alpha(_ opacity: CGFloat) throws -> UInt64 {
      let image = try #require(CoreTextTypesetter.verticalGlyphImage(
        text: text,
        language: .init(identifier: "ko"),
        fontSize: 40,
        size: CGSize(width: 120, height: 150),
        scale: 2,
        progression: progression,
        foreground: .init(red: 0.1, green: 0.3, blue: 0.8, alpha: opacity)
      ))
      let context = try #require(CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
      return (0..<(image.width * image.height)).reduce(UInt64.zero) { $0 + UInt64(bytes[$1 * 4 + 3]) }
    }
    let full = try alpha(1)
    let half = try alpha(0.5)
    #expect(full > 1000)
    #expect(Double(half) / Double(full) > 0.49 && Double(half) / Double(full) < 0.51)
    #expect(try alpha(0) == 0)
  }

  @Test(arguments: [OverlayFontDesign.standard, .monospaced], [CGFloat(0), 0.5, 1])
  func aFullVerticalStyleMatchesTheSameBaseAppearance(_ design: OverlayFontDesign, _ alpha: CGFloat) throws {
    let text = "한글..."
    let color = OverlayColor(red: 0.1, green: 0.3, blue: 0.8, alpha: alpha)
    let style = OverlaySourceAppearance(
      background: .white,
      foreground: color,
      confidence: 1,
      fontWeight: .bold,
      fontDesign: design,
      isUnderlined: true
    )
    let range = NSRange(location: 0, length: (text as NSString).length)
    let styled = try #require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 24,
      fontWeight: .regular,
      size: CGSize(width: 130, height: 240),
      scale: 2,
      progression: .rightToLeft,
      foreground: color,
      styles: [.init(range: range, appearance: style)]
    ))
    let reference = try #require(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "ko"),
      fontSize: 24,
      fontWeight: .bold,
      fontDesign: design,
      size: CGSize(width: 130, height: 240),
      scale: 2,
      progression: .rightToLeft,
      foreground: color,
      isUnderlined: true
    ))
    #expect(try verticalPixels(styled) == verticalPixels(reference))
    let fitted = CoreTextTypesetter.fittedLayout(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      fontWeight: .regular,
      constrainedTo: CGSize(width: 100, height: 100),
      preferred: 40,
      minimum: 6,
      styles: [.init(range: range, appearance: style)]
    )
    let expected = CoreTextTypesetter.fittedLayout(
      text: text,
      language: .init(identifier: "ko"),
      flow: .vertical(.rightToLeft),
      fontWeight: .bold,
      fontDesign: design,
      constrainedTo: CGSize(width: 100, height: 100),
      preferred: 40,
      minimum: 6,
      isUnderlined: true
    )
    #expect(fitted.fontSize == expected.fontSize && fitted.verticalWrapping == expected.verticalWrapping)
  }

  @Test
  func verticalRunOpacityIsAbsoluteAndPreservesColorEmoji() throws {
    let text = "한글\n😀"
    let range = (text as NSString).range(of: "😀")
    func image(styled: Bool) throws -> CGImage {
      try #require(CoreTextTypesetter.verticalGlyphImage(
        text: text,
        language: .init(identifier: "ko"),
        fontSize: 40,
        size: CGSize(width: 180, height: 170),
        scale: 1,
        progression: .rightToLeft,
        foreground: .black,
        styles: styled
          ? [.init(range: range, appearance: .init(
            background: .white,
            foreground: .init(red: 0.1, green: 0.3, blue: 0.8, alpha: 0.5),
            confidence: 1
          ))]
          : []
      ))
    }
    let full = try verticalPixels(image(styled: false))
    let half = try verticalPixels(image(styled: true))
    var originalEmoji: UInt64 = 0
    var fadedEmoji: UInt64 = 0
    var originalText: UInt64 = 0
    var unchangedText: UInt64 = 0
    for y in 0..<170 { for x in 0..<180 {
      let index = (y * 180 + x) * 4 + 3
      if x < 90 { originalEmoji += UInt64(full[index])
        fadedEmoji += UInt64(half[index])
      } else { originalText += UInt64(full[index])
        unchangedText += UInt64(half[index])
      }
    } }
    #expect(originalEmoji > 1000 && originalText > 1000)
    #expect(Double(fadedEmoji) / Double(originalEmoji) > 0.49 && Double(fadedEmoji) / Double(originalEmoji) < 0.51)
    #expect(originalText == unchangedText)
  }

  @MainActor
  @Test
  func translatedVerticalStyleReferencesReachTheActualCompositor() throws {
    let size = CGSize(width: 240, height: 360)
    let background = try #require(CGContext(
      data: nil,
      width: 240,
      height: 360,
      bitsPerComponent: 8,
      bytesPerRow: 960,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    background.setFillColor(CGColor(gray: 1, alpha: 1))
    background.fill(CGRect(origin: .zero, size: size))
    let data = try #require(background.makeImage()?.pngData)
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.1,
      fontWeight: .regular
    )
    var emphasis = base
    emphasis.foreground = .init(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
    emphasis.fontWeight = .bold
    emphasis.isUnderlined = true
    let original = "今日は晴れています"
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.15, y: 0.08, width: 0.7, height: 0.84),
      text: original,
      rowCount: 2,
      isVerticalBlock: true,
      verticalCharScale: 0.1,
      appearance: base,
      styleRuns: [.init(
        range: (original as NSString).range(of: "晴れ"),
        box: CGRect(x: 0.6, y: 0.35, width: 0.15, height: 0.2),
        appearance: emphasis
      )]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "ja")))
    line.source.replacementPatches = []
    let target = "오늘 맑은 날이에요"
    var attributed = AttributedString(target)
    attributed[try #require(attributed.range(of: "맑은"))].link = URL(string: "swiftycrow-style://run/0")
    line.showTranslation(target, attributedText: attributed, language: .init(identifier: "ko"))
    #expect(line.displayedStyleRuns.count == 1)
    let image = try #require(CaptureResultImage.render(
      imageData: data,
      imageSize: size,
      lines: [line],
      prefersHorizontalTextLayout: false
    ))
    let pixels = try verticalPixels(image)
    let blue = (0..<(image.width * image.height)).count {
      pixels[$0 * 4 + 2] > 120 && Int(pixels[$0 * 4 + 2]) - Int(pixels[$0 * 4]) > 60
    }
    #expect(blue > 100)
    #expect(line.displayedText == target)
  }

  @Test
  func verticalProseDoesNotLeaveASingleLetterAndPunctuationInItsLastColumn() {
    let text = "第九局表，在最后的攻击前组成了圆阵。 对于导演的话，我们一次又一次地互相对峙。“ 绝对会逆转的“哦！” 所有人都有力地回答了。"
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: .init(identifier: "zh-Hans"),
      fontSize: 40.93910784489563,
      fontWeight: .regular,
      constrainedToHeight: 607.0725984574634
    )
    #expect(plan.columns.count > 1)
    #expect(plan.columns.map { (text as NSString).substring(with: $0) }.joined() == text)
    let last = plan.columns.last.map { (text as NSString).substring(with: $0) } ?? ""
    #expect(last.unicodeScalars.count(where: CharacterSet.alphanumerics.contains) >= 3)
    #expect(CoreTextTypesetter.verticalGlyphImage(
      text: text,
      language: .init(identifier: "zh-Hans"),
      fontSize: 40.93910784489563,
      fontWeight: .regular,
      size: CGSize(width: plan.requiredWidth + 8, height: 607.0725984574634),
      scale: 1,
      progression: .rightToLeft
    ) != nil)
  }

  @Test(arguments: [
    VerticalCase(language: "ko", text: "마지막 공격을 앞두고 원진을 구성했습니다. 감독님의 말씀에 우리는 여러 번 맞장구를 칩니다."),
    VerticalCase(
      language: "ko",
      text: "마지막 공격을 앞두고 원진을 구성했습니다. 감독님의 말씀에 우리는 여러 번 여러 번 맞장구를 칩니다.",
      fontSize: 23.25,
      height: 384.5009460449219,
      fontWeight: .regular
    ),
    VerticalCase(language: "ja", text: "今日ここから始めよう。細かい文字も欠けないように表示する。"),
    VerticalCase(language: "zh-Hans", text: "今天我们从这里开始。请完整显示每个字符和标点。"),
  ], [OverlayColumnProgression.rightToLeft, .leftToRight])
  func verticalDrawingRetainsTheSameInkWhenOnlyOuterMarginsChange(
    _ sample: VerticalCase,
    _ progression: OverlayColumnProgression
  ) throws {
    let language = Locale.Language(identifier: sample.language)
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: sample.text,
      language: language,
      fontSize: sample.fontSize,
      fontWeight: sample.fontWeight,
      constrainedToHeight: sample.height
    )
    let width = ceil(plan.requiredWidth) + 4
    func ink(_ text: String, extraWidth: CGFloat) throws -> UInt64 {
      let image = try #require(CoreTextTypesetter.verticalGlyphImage(
        text: text,
        language: language,
        fontSize: sample.fontSize,
        fontWeight: sample.fontWeight,
        size: CGSize(width: width + extraWidth, height: sample.height),
        scale: 2,
        progression: progression
      ))
      let raster = try #require(CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      let pixels = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
      return (0..<(image.width * image.height)).reduce(UInt64.zero) { $0 + UInt64(pixels[$1 * 4 + 3]) }
    }
    let tight = try ink(sample.text, extraWidth: 0)
    let loose = try ink(sample.text, extraWidth: 200)
    #expect(loose > 0)
    #expect(Double(tight) >= Double(loose) * 0.995)
    let pieces = try substrings(plan.columns, in: sample.text)
    let separate = try pieces.reduce(UInt64.zero) { try $0 + ink($1, extraWidth: 200) }
    #expect(Double(loose) >= Double(separate) * 0.995)
  }

  @Test
  func koreanVerticalColumnsKeepWordsTogetherAndStayCompact() throws {
    let text = "괜찮다면 지금 시작해요."
    let fontSize: CGFloat = 22.75
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: fontSize,
      constrainedToHeight: 154
    )
    let columns = try substrings(plan.columns, in: text)

    #expect(columns == ["괜찮다면 지금 ", "시작해요."])
    #expect(plan.columnGap <= fontSize * 0.15)
    #expect(plan.requiredWidth < fontSize * 3)
  }

  @Test
  func koreanEmergencyBreakMovesWholeWordToNextColumn() throws {
    let text = "갑자기 찾아와서 미안해요."
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: 29.44,
      constrainedToHeight: 342.8
    )
    let columns = try substrings(plan.columns, in: text)

    #expect(columns == ["갑자기 찾아와서 ", "미안해요."])
    #expect(CoreTextTypesetter.verticalColumnsPreserveWords(
      text: text,
      language: Locale.Language(identifier: "ko"),
      fontSize: 29.44,
      constrainedToHeight: 342.8
    ))
  }

  @Test(arguments: [
    VerticalCase(language: "ja", text: "2026年8月27日です。OKなら今すぐ始めよう。"),
    VerticalCase(language: "ko", text: "오늘 중요한 이야기가 있어요. 괜찮다면 지금 시작해요."),
    VerticalCase(language: "zh-Hans", text: "今天有重要的事情告诉你。如果可以的话，我们现在开始吧。"),
  ])
  func verticalPlansConsumeEveryComposedCharacter(_ testCase: VerticalCase) throws {
    let plan = CoreTextTypesetter.verticalLayoutPlan(
      text: testCase.text,
      language: Locale.Language(identifier: testCase.language),
      fontSize: 24,
      constrainedToHeight: 180
    )
    let columns = try substrings(plan.columns, in: testCase.text)

    #expect(!columns.isEmpty)
    #expect(columns.joined() == testCase.text)
    #expect(plan.columns.reduce(0) { $0 + $1.length } == (testCase.text as NSString).length)
  }

  @Test
  func englishFontFitsLegalSyllablesBeforeWrapping() {
    let language = Locale.Language(identifier: "en-US")
    let availableWidth: CGFloat = 62
    let fontSize = CoreTextTypesetter.horizontalWordFittedFontSize(
      text: "I have something important to tell you.",
      language: language,
      constrainedToWidth: availableWidth,
      preferred: 28,
      minimum: 6
    )
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Source",
      appearance: appearance
    )
    var overlay = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: language))
    overlay.showTranslation("I have something important to tell you.", language: language)
    let fitted = HorizontalTextRenderer.fittedLayout(
      line: overlay,
      in: CGSize(width: availableWidth, height: 500),
      preferred: fontSize,
      lineHeightMultiple: 1
    ).fontSize
    let plan = HorizontalTextRenderer.plan(
      text: "I have something important to tell you.",
      language: language,
      fontSize: fitted,
      appearance: .init(background: .white, foreground: .black, confidence: 1),
      styles: [],
      width: availableWidth,
      lineHeightMultiple: 1
    )
    #expect(fontSize >= 18)
    #expect(fitted >= 18)
    #expect(plan.fits(CGSize(width: availableWidth, height: 500)))
    #expect(!plan.hyphens.isEmpty)
    #expect(CoreTextTypesetter.horizontalWordsFit(
      text: "I have something important to tell you.",
      language: language,
      fontSize: fontSize,
      constrainedToWidth: availableWidth
    ))
  }

  @Test
  func horizontalLineHeightMultipleParticipatesInFitting() {
    let text = "첫 번째 줄과 두 번째 줄의 간격을 원본과 동일하게 유지합니다."
    let language = Locale.Language(identifier: "ko-KR")
    let size = CGSize(width: 180, height: 72)
    let defaultSize = CoreTextTypesetter.fittedLayout(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      constrainedTo: size,
      preferred: 24,
      minimum: 6
    ).fontSize
    let spacedSize = CoreTextTypesetter.fittedLayout(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      constrainedTo: size,
      preferred: 24,
      minimum: 6,
      lineHeightMultiple: 1.35
    ).fontSize

    #expect(spacedSize <= defaultSize)
    #expect(CoreTextTypesetter.fits(
      text: text,
      language: language,
      flow: .horizontal(.leftToRight),
      fontSize: spacedSize,
      in: size,
      lineHeightMultiple: 1.35
    ))
  }

  // MARK: Private

  private func yellowBackgroundAlpha(in pixels: [UInt8]) -> [UInt8] {
    var result = [UInt8]()
    for offset in stride(from: 0, to: pixels.count, by: 4) {
      let alpha = Int(pixels[offset + 3])
      let red = Int(pixels[offset])
      let green = Int(pixels[offset + 1])
      guard alpha > 0, pixels[offset + 2] <= 1, abs(red - alpha) <= 1, abs(green - alpha) <= 1 else { continue }
      result.append(pixels[offset + 3])
    }
    return result
  }

  private func verticalPixels(_ image: CGImage) throws -> [UInt8] {
    let context = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
    return Array(UnsafeBufferPointer(start: bytes, count: image.width * image.height * 4))
  }

  private func substrings(_ ranges: [NSRange], in text: String) throws -> [String] {
    try ranges.map { range in
      String(text[try #require(Range(range, in: text))])
    }
  }
}
