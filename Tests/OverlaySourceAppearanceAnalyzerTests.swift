// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Overlay source appearance")
struct OverlaySourceAppearanceAnalyzerTests {

  // MARK: Internal

  @Test(arguments: ["相", "fE"])
  func aQuotedRubyTermTravelsAsOneInlineOwner(_ spelling: String) throws {
    let size = CGSize(width: 320, height: 100)
    let context = try #require(CGContext(
      data: nil,
      width: 320,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    func paint(_ text: String, font: CGFloat, x: CGFloat, y: CGFloat) -> CGRect {
      let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [.font: NSFont.systemFont(ofSize: font), .foregroundColor: NSColor.systemBlue]
      ))
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(line, context)
      let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      return CGRect(
        x: (x + ink.minX) / size.width,
        y: (size.height - y - ink.maxY) / size.height,
        width: ink.width / size.width,
        height: ink.height / size.height
      )
    }
    let word = paint("相", font: 18, x: 90, y: 45)
    let rail = paint("あい", font: 9, x: 90, y: 67)
    var appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    appearance.fontSizeScale = 0.18
    let text = "This is \(spelling) plus more."
    let range = (text as NSString).range(of: spelling)
    let base = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.03, y: word.minY, width: 0.9, height: word.height),
      text: text,
      horizontalGlyphScale: word.height,
      appearance: appearance,
      styleRuns: [.init(
        range: range,
        box: word,
        appearance: appearance,
        inkBox: word
      )]
    )
    let ruby = OCRResult.Line(boundingBoxNormalized: rail, text: "あい")
    let captured = OCRInlineSourceFragments.capturingRubyAnnotations(
      .init(lines: [ruby, base]),
      image: try #require(context.makeImage())
    ).absorbingRubyAnnotations()
    #expect(captured.lines.count == 1)
    let fragment = try #require(captured.lines[0].styleRuns.first?.sourceFragment)
    #expect(CGFloat(fragment.height) > word.height * size.height)
    var line = OverlayLine(id: UUID(), source: .init(recognized: captured.lines[0], language: .init(identifier: "en")))
    let source = try #require(line.source.attributedTextForTranslation())
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.requestText == "This is ZXQ000XQZ plus more.")
    let target = try #require(plan.restoring("설명은 ZXQ000XQZ에 관한 것이다."))
    line.showTranslation(String(target.characters), attributedText: target, language: .init(identifier: "ko"))
    let carried = try #require(line.displayedStyleRuns.first { $0.sourceFragment != nil })
    #expect((try #require(line.translatedText) as NSString).substring(with: carried.range) == spelling)
    #expect(carried.sourceFragment == fragment)
    #expect(line.source.box.contains(word.union(rail)))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
    #expect(placement.fontSize >= 18 * 0.8)
  }

  @Test(arguments: [false, true])
  func aSharedWordBoxSeparatesTheRaisedChromaticReference(_ clipsBracket: Bool) async throws {
    let size = CGSize(width: 240, height: 100)
    let context = try #require(CGContext(
      data: nil,
      width: 240,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    func paint(_ text: String, _ font: CGFloat, _ x: CGFloat, _ y: CGFloat, _ color: NSColor) -> CGRect {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: NSFont(name: "Arial", size: font)!,
        .foregroundColor: color,
      ]))
      context.textPosition = CGPoint(x: x, y: y)
      CTLineDraw(line, context)
      let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      return CGRect(x: x + ink.minX, y: size.height - y - ink.maxY, width: ink.width, height: ink.height)
    }
    let body = paint("Output.", 18, 20, 40, .black)
    let reference = paint("[1.1]", 13, body.maxX + 2, 46, .systemBlue)
    let pixels = body.union(reference).insetBy(dx: -1, dy: -1)
    let box = CGRect(
      x: pixels.minX / size.width,
      y: pixels.minY / size.height,
      width: pixels.width / size.width,
      height: pixels.height / size.height
    )
    func normalized(_ pixels: CGRect) -> CGRect {
      .init(
        x: pixels.minX / size.width,
        y: pixels.minY / size.height,
        width: pixels.width / size.width,
        height: pixels.height / size.height
      )
    }
    let runs: [OverlaySourceStyleRun] = clipsBracket
      ? [.init(range: NSRange(location: 0, length: 7), box: normalized(body.insetBy(dx: -1, dy: -1)))]
        + (8...11).map { .init(
          range: NSRange(location: $0, length: 1),
          box: normalized(CGRect(
            x: reference.minX + 3,
            y: reference.minY - 1,
            width: reference.width - 3,
            height: reference.height + 2
          ))
        ) }
      : [(0, 6), (6, 2), (8, 1), (9, 1), (10, 1), (11, 1)].map {
        .init(range: NSRange(location: $0.0, length: $0.1), box: box)
      }
    let observed = OCRResult.Line(
      boundingBoxNormalized: box,
      text: clipsBracket ? "Output. 1.1]" : "Output.(1.1]",
      imageAspectRatio: 2.4,
      styleRuns: runs
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [observed]),
      from: try #require(context.makeImage())
    )
    let paragraph = try #require(result.lines.first)
    let retained = try #require(paragraph.styleRuns.first { $0.sourceFragment != nil })
    #expect((paragraph.text as NSString).substring(with: retained.range) == (clipsBracket ? "1.1]" : "(1.1]"))
    #expect(abs((try #require(retained.inkBox)).minX * size.width - reference.minX) < 2)
    #expect(try #require(retained.sourceFragment).descent < 0)
    #expect(result.lines.count == 1)
    #expect(paragraph.text == observed.text)
    #expect(paragraph.layoutExclusions.isEmpty)
    var translated = OverlayLine(id: UUID(), source: .init(recognized: paragraph, language: .init(identifier: "en")))
    let request = try #require(translated.source.attributedTextForTranslation())
    let protection = try #require(TranslationLiteralPlan(request))
    let regex = try NSRegularExpression(pattern: "ZXQ[0-9]+XQZ")
    let match = try #require(regex.firstMatch(
      in: protection.requestText,
      range: NSRange(location: 0, length: protection.requestText.utf16.count)
    ))
    let token = (protection.requestText as NSString).substring(with: match.range)
    let target = try #require(protection.restoring("결과." + token))
    translated.showTranslation(String(target.characters), attributedText: target, language: .init(identifier: "ko"))
    let carried = try #require(translated.displayedStyleRuns.first { $0.sourceFragment != nil })
    #expect(carried.range.location == 3)
    #expect(carried.sourceFragment == retained.sourceFragment)
    let plan = HorizontalTextRenderer.plan(
      text: translated.displayedText,
      language: translated.displayedLanguage,
      fontSize: retained.sourceFragment!.referenceFontSize,
      appearance: translated.source.appearance,
      styles: translated.displayedStyleRuns,
      width: 180,
      lineHeightMultiple: 1
    )
    let line = try #require(plan.lines.first)
    #expect(InlineSourceFragmentRenderer.bounds(in: line).minY > 0)
  }

  @Test
  func darkerBracketsDoNotTurnTheDominantLinkInkBlack() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 240,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 100))
    let content = NSMutableAttributedString(string: "[Open]", attributes: [
      .font: NSFont(name: "Arial", size: 18)!,
      .foregroundColor: NSColor.black,
    ])
    content.addAttribute(
      .foregroundColor,
      value: NSColor(calibratedRed: 0.2, green: 0.4, blue: 0.8, alpha: 1),
      range: NSRange(location: 1, length: 4)
    )
    let line = CTLineCreateWithAttributedString(content)
    context.textPosition = CGPoint(x: 20, y: 40)
    CTLineDraw(line, context)
    let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let box = CGRect(
      x: (20 + ink.minX - 1) / 240,
      y: (60 - ink.maxY - 1) / 100,
      width: (ink.width + 2) / 240,
      height: (ink.height + 2) / 100
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: .init(lines: [
      .init(
        boundingBoxNormalized: box,
        text: "[Open]",
        imageAspectRatio: 2.4,
        styleRuns: [.init(range: NSRange(location: 0, length: 6), box: box)]
      )
    ]), from: try #require(context.makeImage()))
    let color = try #require(result.lines.first).appearance.foreground
    #expect(color.blue > color.red + 0.4)
  }

  @Test
  func neighboringLabelSearchLimitsCannotManufactureAClosedSurface() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 640,
      height: 220,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: 220)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 0.08, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 220))
    context.setFillColor(CGColor(gray: 0.30, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 65))
    context.setFillColor(CGColor(gray: 0.45, alpha: 1))
    context.fill(CGRect(x: 0, y: 160, width: 640, height: 2))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    let lines = [(40, 70, "Projects"), (134, 54, "Search"), (212, 93, "Preferences")].map { x, width, text in
      for position in stride(from: x, to: x + width - 4, by: 8) {
        context.fill(CGRect(x: position, y: 100, width: 4, height: 14))
      }
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: CGFloat(x) / 640,
          y: 98.0 / 220,
          width: CGFloat(width) / 640,
          height: 20.0 / 220
        ),
        text: text,
        imageAspectRatio: 640.0 / 220
      )
    }
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: lines),
      from: try #require(context.makeImage())
    )
    #expect(analyzed.lines.allSatisfy { $0.surface == nil })
  }

  @Test(arguments: [false, true], [false, true])
  func thinControlOutlineEstablishesCenterOnlyWhenClosed(_ dark: Bool, _ closed: Bool) async throws {
    let size = CGSize(width: 1200, height: 800)
    let context = try #require(CGContext(
      data: nil,
      width: 1200,
      height: 800,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: size.height)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: dark ? 0.12 : 0.94, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let control = CGRect(x: 860, y: 20, width: 64, height: 30)
    context.setStrokeColor(CGColor(gray: dark ? 0.42 : 0.64, alpha: 1))
    context.setLineWidth(1)
    if closed {
      context.addPath(CGPath(roundedRect: control, cornerWidth: 6, cornerHeight: 6, transform: nil))
      context.strokePath()
    } else {
      context.move(to: CGPoint(x: control.minX, y: control.minY))
      context.addLine(to: CGPoint(x: control.maxX, y: control.minY))
      context.strokePath()
    }
    context.setFillColor(CGColor(gray: dark ? 0.95 : 0.05, alpha: 1))
    for x in stride(from: 875, to: 909, by: 7) {
      context.fill(CGRect(x: x, y: 28, width: 4, height: 14))
    }
    let box = CGRect(x: 875 / size.width, y: 26 / size.height, width: 34 / size.width, height: 18 / size.height)
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: .init(lines: [
      .init(boundingBoxNormalized: box, text: "Share", imageAspectRatio: size.width / size.height)
    ]), from: try #require(context.makeImage()))
    let source = try #require(result.lines.first)
    if closed {
      let surface = try #require(source.surface)
      #expect(abs(surface.box.midX * size.width - control.midX) <= 2)
      var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
      line.showTranslation("공유하다", language: .init(identifier: "ko"))
      let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
      #expect(placement.alignment == .center)
      #expect(abs(placement.frame.midX - control.midX) <= 2)
    } else {
      #expect(source.surface == nil)
    }
  }

  @Test
  func denseWhiteGlyphsOnBlackAreNotAWhiteButtonSurface() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 140,
      height: 70,
      bitsPerComponent: 8,
      bytesPerRow: 560,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 140, height: 70))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for x in stride(from: 20, to: 120, by: 10) {
      context.fill(CGRect(x: x, y: 28, width: 7, height: 14))
    }
    let box = CGRect(x: 20.0 / 140, y: 28.0 / 70, width: 97.0 / 140, height: 14.0 / 70)
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: OCRResult(lines: [
      .init(boundingBoxNormalized: box, text: "Title", replacementPatches: [.init(box: box)])
    ]), from: try #require(context.makeImage()))
    #expect(analyzed.lines[0].appearance.background.red < 0.15)
    #expect(analyzed.lines[0].appearance.foreground.red > 0.85)
  }

  @Test
  func findsLightBackgroundAndDarkForegroundAroundGlyphs() async throws {
    let image = try makeImage(
      background: CGColor(gray: 0.94, alpha: 1),
      glyph: CGColor(gray: 0.04, alpha: 1)
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func findsDarkBackgroundAndLightForegroundAroundGlyphs() async throws {
    let image = try makeImage(
      background: CGColor(gray: 0.06, alpha: 1),
      glyph: CGColor(gray: 0.96, alpha: 1)
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(patch.appearance.background.red < 0.15)
    #expect(patch.appearance.foreground.red > 0.9)
    #expect(patch.appearance.confidence > 0.5)
  }

  @Test
  func preservesColoredSourceGlyphs() async throws {
    let image = try makeImage(
      background: CGColor(gray: 0, alpha: 1),
      glyph: CGColor(red: 0.05, green: 0.52, blue: 1, alpha: 1)
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: image
    )
    let foreground = try #require(analyzed.lines.first?.appearance.foreground)

    #expect(foreground.blue > 0.9)
    #expect(foreground.green > foreground.red * 4)
  }

  @Test
  func shortColoredBulletDoesNotBecomeTheLineForeground() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let result = try #require(analyzed.lines.first)

    #expect(result.appearance.foreground.red > result.appearance.foreground.blue * 0.8)
    #expect(result.appearance.foreground.red < 0.8)
    #expect(!result.styleRuns[0].appearance.isUnderlined)
  }

  @Test
  func thickerGlyphCoverageProducesHeavierWeight() async throws {
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
    let thinAppearance = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: thin
    ).lines[0].appearance
    let thickAppearance = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: sourceResult(),
      from: thick
    ).lines[0].appearance

    #expect(thinAppearance.fontWeight.rawValue < thickAppearance.fontWeight.rawValue)
    #expect(thinAppearance.inkCoverage < thickAppearance.inkCoverage)
  }

  @Test
  func consolidatesWordPatchesOnOneFlatBackground() async throws {
    let image = try makeImage(background: CGColor(gray: 0.1, alpha: 1), glyph: nil)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.3, width: 0.6, height: 0.4),
      text: "Two words",
      replacementPatches: [
        OverlaySourcePatch(box: CGRect(x: 0.22, y: 0.35, width: 0.2, height: 0.3)),
        OverlaySourcePatch(box: CGRect(x: 0.58, y: 0.35, width: 0.2, height: 0.3)),
      ]
    )

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines[0].replacementPatches.count == 1)
    #expect(analyzed.lines[0].replacementPatches[0].box == line.boundingBoxNormalized)
  }

  @Test
  func keepsWordPatchesWhenAControlCrossesDifferentBackgrounds() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines[0].replacementPatches.count == 2)
  }

  @Test
  func samplesInlineCodeSurfaceInsideLongWordBox() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func highContrastCompactFillIsBackgroundRatherThanUnderlineInk() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let style = try #require(analyzed.lines.first?.styleRuns.first?.appearance)

    #expect(style.background.red > 0.8)
    #expect(style.foreground.red < 0.4)
    #expect(!style.isUnderlined)
  }

  @Test
  func embeddedInlineCodeErasesItsOldSurfaceToTheParentBackground() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func separatelyRecognizedInlineCodeIsReclassifiedAfterRowCoalescing() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func hyphenatedStandaloneBadgeKeepsItsOwnSurface() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let analyzedLine = try #require(analyzed.lines.first)

    #expect(analyzedLine.replacementPatches.allSatisfy { !$0.erasesDistinctSurface })
    #expect(analyzedLine.replacementPatches.allSatisfy { $0.appearance.background.blue > 0.25 })
  }

  @Test
  func compactSurfaceIgnoresParentColorLeakingIntoOCRBox() async throws {
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

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func clampsSamplingAtImageEdges() async throws {
    let image = try makeImage(
      background: CGColor(red: 0.18, green: 0.65, blue: 0.42, alpha: 1),
      glyph: nil
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.96, y: 0.96, width: 0.08, height: 0.08),
      text: "edge",
      replacementPatches: [OverlaySourcePatch(box: CGRect(x: 0.96, y: 0.96, width: 0.08, height: 0.08))]
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )
    let patch = try #require(analyzed.lines.first?.replacementPatches.first)

    #expect(patch.appearance.confidence > 0.9)
    #expect(patch.appearance.background.green > 0.55)
  }

  @Test
  func findsClosedFlatSurfaceAroundSourceText() async throws {
    let image = try makeBubbleImage()
    let source = CGRect(x: 0.4, y: 0.25, width: 0.2, height: 0.5)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "Text",
      replacementPatches: [OverlaySourcePatch(box: source)]
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func framedDocumentIsNotTreatedAsOneTextSurface() async throws {
    let image = try makeFramedDocumentImage()
    let source = CGRect(x: 0.3, y: 0.04, width: 0.4, height: 0.08)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "Document title",
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [line]),
      from: image
    )

    #expect(analyzed.lines.first?.surface == nil)
  }

  @Test
  func extendsVerticalRestorationOnlyToNearbyMissedInk() async throws {
    let image = try makeVerticalMissedGlyphImage()
    let source = CGRect(x: 0.44, y: 0.35, width: 0.12, height: 0.25)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "ています",
      isVerticalBlock: true,
      verticalCharScale: 0.12,
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
  func restoresChromaticRubyWithoutCrossingTheBorderAboveIt() async throws {
    let image = try makeChromaticRubyImage()
    let source = CGRect(x: 0.25, y: 0.55, width: 0.5, height: 0.22)
    let line = OCRResult.Line(
      boundingBoxNormalized: source,
      text: "ナイフ型石器",
      horizontalGlyphScale: source.height,
      replacementPatches: [OverlaySourcePatch(box: source)]
    )

    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
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
