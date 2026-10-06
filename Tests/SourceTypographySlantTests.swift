// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Testing
@testable import SwiftyCrow

struct SourceTypographySlantTests {

  // MARK: Internal

  @Test(arguments: ["Arial", "TimesNewRomanPSMT", "Georgia", "Verdana", "Menlo-Regular"], [12.0, 18.0, 24.0])
  func uprightGlyphShapesDoNotBecomeItalic(_ family: String, _ size: Double) async throws {
    let font = try #require(NSFont(name: family, size: size))
    for text in [
      "integer",
      "signed",
      "unsigned",
      "Settings",
      "Architecture",
      "Jetzt",
      "erstellen",
      "value",
      "minimum",
      "maximum",
      "NNNN",
      "vvvv",
      "oooo",
    ] {
      let result = try await analyze(text, font: font)
      #expect(!result.appearance.isItalic, "Upright source: \(family), \(size), \(text)")
      #expect(result.styleRuns.allSatisfy { !$0.appearance.isItalic })
    }
  }

  @Test(
    arguments: ["Arial-ItalicMT", "TimesNewRomanPS-ItalicMT", "Georgia-Italic", "Verdana-Italic", "Menlo-Italic"],
    [18.0, 24.0]
  )
  func italicStemsAreMeasuredAcrossIndependentFontFamilies(_ family: String, _ size: Double) async throws {
    let font = try #require(NSFont(name: family, size: size))
    for text in ["integer", "signed", "artificial"] {
      let result = try await analyze(text, font: font)
      #expect(result.appearance.isItalic, "Italic source: \(family), \(size), \(text)")
      #expect(result.styleRuns.contains { $0.appearance.isItalic })
    }
  }

  @Test(arguments: [("integer", "en"), ("정수", "ko"), ("整数", "zh"), ("العربية", "ar")])
  func fallbackGlyphsReceiveTheMeasuredSlant(_ sample: (String, String)) throws {
    var appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    let normal = HorizontalTextRenderer.plan(
      text: sample.0,
      language: .init(identifier: sample.1),
      fontSize: 32,
      appearance: appearance,
      styles: [],
      width: 200,
      lineHeightMultiple: 1
    )
    appearance.isItalic = true
    let italic = HorizontalTextRenderer.plan(
      text: sample.0,
      language: .init(identifier: sample.1),
      fontSize: 32,
      appearance: appearance,
      styles: [],
      width: 200,
      lineHeightMultiple: 1
    )
    #expect(normal.complete && italic.complete)
    #expect(italic.inkBounds.width > normal.inkBounds.width + 1)
    let runs = CTLineGetGlyphRuns(try #require(italic.lines.first)) as! [CTRun]
    #expect(!runs.isEmpty)
    for run in runs {
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      #expect(abs(CTFontGetMatrix(font).c - 0.2) < 0.001)
    }
  }

  @Test
  func uprightSpansRemainUprightInsideAnItalicBase() throws {
    let text = "integer Signed"
    let italic = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontWeight: .regular,
      isItalic: true
    )
    var upright = italic
    upright.isItalic = false
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: text,
      appearance: italic,
      styleRuns: [
        .init(range: (text as NSString).range(of: "integer"), box: CGRect(x: 0, y: 0, width: 0.4, height: 1), appearance: italic),
        .init(
          range: (text as NSString).range(of: "Signed"),
          box: CGRect(x: 0.5, y: 0, width: 0.4, height: 1),
          appearance: upright
        ),
      ]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    let request = try #require(line.source.attributedTextForTranslation())
    let neutralRun = try #require(request.runs.first { String(request.characters[$0.range]).contains("Signed") })
    var translated = AttributedString("정수 부호 있음")
    translated[translated.range(of: "부호 있음")!].link = neutralRun.link
    line.showTranslation("정수 부호 있음", attributedText: translated, language: .init(identifier: "ko"))
    let retained = try #require(line.displayedStyleRuns.first { NSLocationInRange(3, $0.range) })
    #expect(!retained.appearance.isItalic)
    let plan = HorizontalTextRenderer.plan(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: 24,
      appearance: line.source.appearance,
      styles: line.displayedStyleRuns,
      width: 300,
      lineHeightMultiple: 1
    )
    let runs = CTLineGetGlyphRuns(try #require(plan.lines.first)) as! [CTRun]
    #expect(runs.contains { run in
      let range = CTRunGetStringRange(run)
      let font = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
      return range.location <= 3 && range.location + range.length > 3 && CTFontGetMatrix(font).c == 0
    })
  }

  @Test(arguments: [CGFloat(0.75), 0.88, 1, 1.25], [CGFloat(0), 0.5])
  func resampledUprightTextRetainsItsStyle(_ scale: CGFloat, _ phase: CGFloat) async throws {
    for text in ["Architecture", "Settings", "Reference", "minimum", "Jetzt", "erstellen"] {
      let result = try await analyze(text, font: #require(NSFont(name: "Arial", size: 17)), scale: scale, phase: phase)
      #expect(!result.appearance.isItalic, "Resampled upright source: \(text), \(scale), \(phase)")
      #expect(result.styleRuns.allSatisfy { !$0.appearance.isItalic })
    }
  }

  @Test
  func capturedUprightSmallLinksRetainTheirRasterStyle() throws {
    let samples: [(String, Int, Int, String)] = [
      (
        "Jetzt",
        29,
        10,
        "AAAAAM3IAAAAAAAAAAAAX30AAAAAAAAAAABffQAAAAAAzcgAAAAAAAAAAACi1wAAAAAAAAAAAKLXAAAAAADNyAAAOr7mwlYAfe76xxbIyMjIyKB97vrHAAAAAM3IAC765Ye+/1ZL1Ot+DpeXl9D/s0vU634AAAAAzcgAq/oUAAXbwACi1wAAAAAa5uYZAKLXAAAAAADNyADd8Zubm+LmAKLXAAAABsj6OAAAotcAkSwAANDIAO7rpaWlpZoAotcAAACb/2UAAACi1wD/ZQAA4qwAzOYBAABweACi1wAAaP+YAAAAAKLXAPzNS6D/fQBz/5c4hP6IAJvxODb6+mBaWlUAm/E4cu7//8gSAAWg////tAoAT/r/bf//////6wBP+v8="
      ),
      (
        "erstellen",
        52,
        10,
        "AAAAAAAAAAAAAAAAAAAAAAAAAABffQAAAAAAAAAAAC7/SC7/SAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAotcAAAAAAAAAAAAu/0gu/0gAAAAAAAAAAAAAAAAAAAAAE6Dc1ooGAGWzadtCLJrm3IoFfe76xwEActDirCQALv9ILv9IAABy0OKsJAApyFzD6r4kBNH5n5b+qgCD///NMMrYdqz/aUvU634Bfv/Dg+TrFC7/SC7/SAB+/8OD5OsUN///qKv/vFb/ZAAAiv4Zg/9sABj/oQAAg2YAotcADPW5AAA0/2wu/0gu/0gM9bkAADT/bDf/kQAApeqH/6mbm8D/PIP6DAAAqv/akEEAAKLXADL/0Jubm/+RLv9ILv9IMv/Qm5ub/5E3/0sAAIH8mP+qpaWlpSyD9AAAAA9zvvr/bgCi1wBE/82lpaWlYy7/SC7/SET/zaWlpaVjN/9AAACA/Hf/PQAAPZcUg/QAACiXGgAQzNwAotcAIv+SAAAMlkYu/0gu/0gi/5IAAAyWRjf/QAAAgPwk+shIX+HcAYP0AAAM9awzMeKpAJvxOAHI7mxBuP80Lv9ILv9IAcjubEG4/zQ3/0AAAID8AFv0///eMwCC8AAAAHb0///KMQBP+v8CJ9P///VzAC3/Ri3/RgAn0///9XMANv8+AAB9+g=="
      ),
    ]
    for (text, width, height, data) in samples {
      let bytes = try #require(Data(base64Encoded: data))
      #expect(!SourceTypographySlant.isItalic(text: text, ink: bytes.map { CGFloat($0) / 255 }, width: width, height: height))
    }
  }

  // MARK: Private

  private func analyze(_ text: String, font: NSFont, scale: CGFloat = 1, phase: CGFloat = 0) async throws -> OCRResult.Line {
    let size = CGSize(width: 500, height: 100)
    let context = try #require(CGContext(
      data: nil,
      width: 500,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
      .font: font,
      .foregroundColor: NSColor.black,
    ]))
    context.textPosition = CGPoint(x: 20 + phase, y: 40 + phase)
    CTLineDraw(line, context)
    let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let box = CGRect(
      x: (20 + phase + ink.minX - 2) / 500,
      y: (60 - phase - ink.maxY - 2) / 100,
      width: (ink.width + 4) / 500,
      height: (ink.height + 4) / 100
    )
    let original = try #require(context.makeImage())
    let resampled = try #require(CGContext(
      data: nil,
      width: Int(500 * scale),
      height: Int(100 * scale),
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    resampled.interpolationQuality = .high
    resampled.draw(original, in: CGRect(x: 0, y: 0, width: 500 * scale, height: 100 * scale))
    let observed = OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      preventsJoining: true,
      styleRuns: [.init(range: NSRange(location: 0, length: text.utf16.count), box: box)]
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [observed]),
      from: try #require(resampled.makeImage())
    )
    #expect(result.lines.count == 1)
    return try #require(result.lines.first)
  }
}
