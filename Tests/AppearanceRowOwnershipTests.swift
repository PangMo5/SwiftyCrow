// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Testing
@testable import SwiftyCrow

struct AppearanceRowOwnershipTests {
  @Test(arguments: [false, true])
  func aLargeShortMarkerDoesNotResizeTheSurroundingLabel(_ reversed: Bool) async throws {
    let size = CGSize(width: 500, height: 140)
    let context = try #require(CGContext(
      data: nil,
      width: 500,
      height: 140,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    func draw(_ text: String, pointSize: CGFloat, x: CGFloat) -> CGRect {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: NSFont.systemFont(ofSize: pointSize),
        .foregroundColor: NSColor.black,
      ]))
      context.textPosition = CGPoint(x: x, y: 45)
      CTLineDraw(line, context)
      let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      return CGRect(
        x: (x + ink.minX - 2) / size.width,
        y: (size.height - 45 - ink.maxY - 2) / size.height,
        width: (ink.width + 4) / size.width,
        height: (ink.height + 4) / size.height
      )
    }
    let marker = draw("2", pointSize: 30, x: reversed ? 130 : 40)
    let label = draw("Settings", pointSize: 20, x: reversed ? 40 : 70)
    let text = reversed ? "Settings 2" : "2 Settings"
    let line = OCRResult.Line(
      boundingBoxNormalized: marker.union(label),
      text: text,
      imageAspectRatio: size.width / size.height,
      preventsJoining: true,
      styleRuns: [
        .init(range: (text as NSString).range(of: "2"), box: marker),
        .init(range: (text as NSString).range(of: "Settings"), box: label),
      ]
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: try #require(context.makeImage())
    )
    let recognized = try #require(result.lines.first)
    #expect(result.lines.count == 1)
    #expect((17...24).contains(recognized.appearance.fontSizeScale * size.height))
    let markerStyle = try #require(recognized.styleRuns.first { $0.range == (text as NSString).range(of: "2") })
    #expect(markerStyle.appearance.fontSizeScale > recognized.appearance.fontSizeScale * 1.35)
  }

  @Test
  func aSlantedObservationCannotSampleAdjacentHorizontalBaselines() {
    let upper = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5023, y: 0.4911, width: 0.1051, height: 0.0283),
      text: "Upper row",
      imageAspectRatio: 3.23
    )
    let middle = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5093, y: 0.5089, width: 0.0961, height: 0.0524),
      text: "Italic row with a footnote",
      rotationRadians: -0.0434,
      orientedBox: CGRect(x: 0.5095, y: 0.5156, width: 0.0957, height: 0.0390),
      imageAspectRatio: 3.23
    )
    let lower = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5100, y: 0.5492, width: 0.0960, height: 0.0230),
      text: "Following body row",
      imageAspectRatio: 3.23
    )
    let region = OCRSpatialOwnership.samplingRegion(for: middle, among: [upper, middle, lower])
    for x in [0.52, 0.55, 0.59] {
      #expect(region.verticalRange(at: x)?.contains(0.535) == true)
      #expect(region.verticalRange(at: x)?.contains(0.500) == false)
      #expect(region.verticalRange(at: x)?.contains(0.560) == false)
    }
  }

  @Test
  func punctuationAliasesCalibrateTheCompleteObservedWord() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 400,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 400, height: 100))
    let text = "ausführen.[1,2]"
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 20),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
    ]))
    context.textPosition = CGPoint(x: 20, y: 40)
    CTLineDraw(line, context)
    let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    let box = CGRect(
      x: 18.0 / 400,
      y: (60 - ink.maxY - 2) / 100,
      width: (ink.maxX + 4) / 400,
      height: (ink.height + 4) / 100
    )
    let source = OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      styleRuns: (0..<text.utf16.count).map {
        .init(range: NSRange(location: $0, length: 1), box: box)
      }
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [source]),
      from: try #require(context.makeImage())
    )
    let sizes = result.lines.flatMap(\.styleRuns).map { $0.appearance.fontSizeScale * 100 }
    #expect(!sizes.isEmpty)
    #expect(sizes.allSatisfy { (17...23).contains($0) })
    #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) < 0.1)
  }

  @Test
  func samplingBudgetUsesGlyphsRatherThanParagraphPaddingAndIgnoresOneTinyOutlier() {
    let padded = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.4),
      text: "Readable paragraph",
      rowCount: 10,
      horizontalGlyphScale: 0.016
    )
    #expect(OverlaySourceAppearanceAnalyzer.appearanceRasterLongestSide(
      for: .init(lines: [padded]),
      imageSize: CGSize(width: 3200, height: 1000)
    ) == 2048)
    var regular = padded
    regular.horizontalGlyphScale = 0.035
    var tiny = padded
    tiny.horizontalGlyphScale = 0.0001
    #expect(OverlaySourceAppearanceAnalyzer.appearanceRasterLongestSide(
      for: .init(lines: [regular, regular, regular, regular, tiny]),
      imageSize: CGSize(width: 1200, height: 820)
    ) == 1024)
  }

  @Test(arguments: [false, true])
  func wideCapturesKeepSmallTextContrastAndMeasuredSize(_ dark: Bool) async throws {
    let width = 3200
    let height = 1000
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: dark ? 0.08 : 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let text = "Read this small text clearly."
    let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 20),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 0.96 : 0.05, alpha: 1),
    ]))
    let ink = CTLineGetBoundsWithOptions(ctLine, [.useGlyphPathBounds])
    context.textPosition = CGPoint(x: 1400, y: 700)
    CTLineDraw(ctLine, context)
    let box = CGRect(
      x: 1396.0 / 3200,
      y: (300 - ink.maxY - 4) / 1000,
      width: (ink.maxX + 8) / 3200,
      height: (ink.height + 8) / 1000
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      imageAspectRatio: 3.2,
      horizontalGlyphScale: box.height,
      styleRuns: [.init(
        range: NSRange(location: 0, length: text.utf16.count),
        box: box
      )]
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: try #require(context.makeImage())
    )
    let appearance = try #require(result.lines.first?.appearance)
    #expect((17...23).contains(appearance.fontSizeScale * 1000))
    let contrast = abs(appearance.foreground.red - appearance.background.red)
    #expect(contrast > 0.75)
  }

  @Test
  func observedFixedPitchDoesNotFreezeProportionalLabels() throws {
    func projection(_ text: String, font: NSFont) throws -> [CGFloat] {
      let context = try #require(CGContext(
        data: nil,
        width: 600,
        height: 70,
        bitsPerComponent: 8,
        bytesPerRow: 2400,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      context.textPosition = CGPoint(x: 8, y: 20)
      CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        .font: font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
      ])), context)
      let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
      return (0..<600).map { x in (0..<70).map { y in CGFloat(pixels[(y * 600 + x) * 4 + 3]) / 255 }.max()! }
    }
    for size: CGFloat in [13, 20] {
      for word in ["isize", "usize", "files", "minimum"] {
        #expect(SourceTypography.isMonospaced(text: word, inkColumns: try projection(
          word,
          font: NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        )), "Fixed pitch: \(word) at \(size)")
      }
      for name in ["Helvetica", "Times New Roman", "Georgia", "Verdana"] {
        let font = try #require(NSFont(name: name, size: size))
        for word in [
          "isize",
          "usize",
          "refer",
          "safe",
          "while",
          "Hello",
          "width",
          "value",
          "files",
          "Read",
          "Edit",
          "open",
          "Show",
          "source",
          "Settings",
          "intelligence",
          "Microsoft",
          "small",
          "normal",
          "Date",
          "Title",
        ] {
          #expect(
            !SourceTypography.isMonospaced(text: word, inkColumns: try projection(word, font: font)),
            "Proportional: \(word) in \(name) at \(size)"
          )
        }
      }
    }
    // Five observed glyph components from the real Rust screenshot, at the
    // analyzer's sampling resolution. These are physical evidence, not words
    // added to an identifier dictionary.
    for (word, ranges) in [
      ("isize", [1...4, 8...13, 16...18, 22...27, 29...34]),
      ("usize", [1...6, 8...13, 16...19, 23...27, 30...35]),
    ] {
      var columns = [CGFloat](repeating: 0, count: 40)
      for range in ranges { for x in range { columns[x] = 1 } }
      #expect(SourceTypography.isMonospaced(text: word, inkColumns: columns))
    }
    // The real downsampled usize has a soft bridge between z and e. Keep
    // faint extents after separating glyphs by their stronger cores.
    let softEdges: [CGFloat] = [
      44,
      186,
      204,
      185,
      168,
      212,
      114,
      3,
      104,
      218,
      175,
      187,
      191,
      149,
      20,
      41,
      156,
      156,
      189,
      149,
      18,
      1,
      64,
      222,
      228,
      191,
      226,
      184,
      71,
      82,
      220,
      191,
      186,
      172,
      201,
      117,
      1,
    ]
    #expect(SourceTypography.isMonospaced(text: "usize", inkColumns: softEdges.map { $0 / 255 }))
    // Proportional web prose can have deceptively uniform glyph centers.
    // Its glyph widths must also match before it becomes a protected literal.
    let referColumns: [CGFloat] = [
      0,
      0,
      183,
      255,
      244,
      204,
      252,
      85,
      128,
      255,
      250,
      246,
      255,
      255,
      254,
      215,
      22,
      161,
      242,
      255,
      215,
      213,
      122,
      255,
      255,
      235,
      255,
      255,
      253,
      255,
      53,
      0,
      183,
      255,
      244,
      204,
      252,
    ]
    #expect(!SourceTypography.isMonospaced(text: "refer", inkColumns: referColumns.map { $0 / 255 }))
    let safeColumns: [CGFloat] = [
      0,
      142,
      255,
      255,
      255,
      228,
      255,
      154,
      1,
      248,
      249,
      255,
      254,
      238,
      254,
      255,
      7,
      68,
      188,
      255,
      250,
      215,
      170,
      128,
      255,
      250,
      246,
      255,
      255,
      254,
      215,
    ]
    #expect(!SourceTypography.isMonospaced(text: "safe", inkColumns: safeColumns.map { $0 / 255 }))
    // Bold title ink must not compensate for ambiguous fixed-pitch spacing.
    let titleColumns: [CGFloat] = [
      1,
      32,
      150,
      208,
      220,
      252,
      246,
      216,
      208,
      118,
      194,
      251,
      247,
      254,
      254,
      251,
      246,
      107,
      106,
      254,
      249,
      231,
      252,
      249,
      254,
      146,
      57,
      212,
      252,
      244,
      252,
      250,
      248,
      215,
      32,
      249,
      251,
      248,
      249,
      253,
      155,
      1,
    ]
    #expect(!SourceTypography.isMonospaced(text: "Types", inkColumns: titleColumns.map { $0 / 255 }))
    #expect(!SourceTypography.isMonospaced(text: "minimum", inkColumns: [CGFloat](repeating: 1, count: 40)))
  }

  @Test
  func bracketedControlDoesNotAcquireCodeSemanticsFromItsGraySurface() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 240,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 960,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 240, height: 100))
    context.setFillColor(CGColor(gray: 0.9, alpha: 1))
    context.fill(CGRect(x: 18, y: 35, width: 120, height: 36))
    let value = "[Show]"
    let text = CTLineCreateWithAttributedString(NSAttributedString(
      string: value,
      attributes: [
        .font: NSFont.systemFont(ofSize: 20),
        NSAttributedString
          .Key(
            kCTForegroundColorAttributeName as String
          ): CGColor(
            gray: 0.05,
            alpha: 1
          ),
      ]
    ))
    context.textPosition = CGPoint(x: 24, y: 44)
    CTLineDraw(text, context)
    let boxes = [
      CGRect(x: 0.1, y: 0.34, width: 0.03, height: 0.25),
      CGRect(x: 0.13, y: 0.34, width: 0.22, height: 0.25),
      CGRect(x: 0.35, y: 0.34, width: 0.04, height: 0.25),
    ]
    let ranges = [NSRange(location: 0, length: 1), NSRange(location: 1, length: 4), NSRange(location: 5, length: 1)]
    let line = OCRResult.Line(
      boundingBoxNormalized: boxes.reduce(CGRect.null) { $0.union($1) },
      text: value,
      imageAspectRatio: 2.4,
      styleRuns: boxes.indices.map { .init(range: ranges[$0], box: boxes[$0]) }
    )
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: try #require(context.makeImage())
    )
    let source = OverlayLine.Source(recognized: try #require(result.lines.first), language: .init(identifier: "en"))
    #expect(TranslationLiteralPlan(source.attributedTextForTranslation()) == nil)
    #expect(OCRTextSemantics.isIndexedIdentifier("items[0]"))
    #expect(!OCRTextSemantics.isIndexedIdentifier("[Show]"))
    #expect(!OCRTextSemantics.isCode("Description[1]"))
  }

  @Test(arguments: [false, true])
  @MainActor
  func dividerBelowHeadingCannotInflateAccessoryTextOrEnterItsErasureMask(_ dark: Bool) async throws {
    let width = 620
    let height = 180
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: dark ? 0.08 : 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let texts = ["Description", "[Edit", "source]"]
    let xs: [CGFloat] = [24, 190, 222]
    let sizes: [CGFloat] = [26, 13, 13]
    var cursor = 0
    var runs = [OverlaySourceStyleRun]()
    for i in texts.indices {
      let attributed = NSAttributedString(string: texts[i], attributes: [
        .font: NSFont.systemFont(ofSize: sizes[i]),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): i == 0
          ? CGColor(gray: dark ? 0.95 : 0.05, alpha: 1)
          : CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1),
      ])
      context.textPosition = CGPoint(x: xs[i], y: 100)
      let ctLine = CTLineCreateWithAttributedString(attributed)
      CTLineDraw(ctLine, context)
      let ink = CTLineGetBoundsWithOptions(ctLine, [.useGlyphPathBounds])
      let box = CGRect(
        x: xs[i] / 620,
        y: (80 - ink.maxY - 2) / 180,
        width: (ink.maxX + 3) / 620,
        height: (94 - (80 - ink.maxY - 2)) / 180
      )
      runs.append(.init(range: NSRange(location: cursor, length: texts[i].utf16.count), box: box))
      cursor += texts[i].utf16.count + 1
    }
    context.setFillColor(CGColor(gray: dark ? 0.6 : 0.65, alpha: 1))
    context.fill(CGRect(x: 24, y: 180 - 91 - 1, width: 555, height: 1))
    let bounds = runs.dropFirst().reduce(runs[0].box) { $0.union($1.box) }
    let line = OCRResult.Line(
      boundingBoxNormalized: bounds,
      text: texts.joined(separator: " "),
      rotationRadians: 0.035,
      imageAspectRatio: 620.0 / 180,
      styleRuns: runs
    )
    let image = try #require(context.makeImage())
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: [line]),
      from: image
    )
    #expect(result.lines.count == 2)
    let accessory = try #require(result.lines.first { $0.text.contains("Edit") })
    #expect(accessory.text == "[Edit source]")
    #expect(accessory.appearance.fontSizeScale * 180 < 18)
    #expect(result.lines.flatMap(\.replacementPatches).allSatisfy { $0.box.maxY * 180 <= 91 })
    #expect(result.lines.allSatisfy { $0.rotationRadians == 0 })
    let restored = await SourceRestorationBuilder.applying(to: result, image: image)
    let translated = restored.lines.map { recognized in
      var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
      line.showTranslation(recognized.text.contains("Edit") ? "[편집]" : "설명", language: .init(identifier: "ko"))
      return line
    }
    let rendered = try #require(CaptureResultImage.render(
      imageData: image.pngData,
      imageSize: CGSize(width: width, height: height),
      lines: translated
    ))
    #expect(CaptureQualityMetrics.protectedPixelChanges(
      original: image,
      rendered: rendered,
      rectangles: [CGRect(x: 24.0 / 620, y: 91.0 / 180, width: 555.0 / 620, height: 1.0 / 180)]
    ) == 0)
  }

  @Test
  func overlappingOCRBoxesCannotSampleInkFromTheNextRow() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 1200,
      height: 800,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.97, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    let strings = ["请保留原始文件。继续之前，请检查更改。更新", "过程中请勿断开设备连接。"]
    let boxes = [
      CGRect(x: 50.0 / 1200, y: 220.0 / 800, width: 520.0 / 1200, height: 40.0 / 800),
      CGRect(x: 50.0 / 1200, y: 252.0 / 800, width: 300.0 / 1200, height: 32.0 / 800),
    ]
    for i in strings.indices {
      context.textPosition = CGPoint(x: 50, y: 800 - 246 - i * 32)
      CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: strings[i], attributes: [
        .font: NSFont.systemFont(ofSize: 26),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.08, alpha: 1),
      ])), context)
    }
    let lines = strings.indices.map { i in OCRResult.Line(
      boundingBoxNormalized: boxes[i],
      text: strings[i],
      imageAspectRatio: 1.5,
      recognitionGroupID: 1,
      styleRuns: [.init(range: NSRange(location: 0, length: (strings[i] as NSString).length), box: boxes[i])]
    ) }
    let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: .init(lines: lines),
      from: try #require(context.makeImage())
    )
    let measured = result.lines.flatMap(\.styleRuns).map { $0.appearance.fontSizeScale * 800 }.filter { $0 > 0 }
    #expect(!measured.isEmpty)
    #expect(measured.allSatisfy { (23...30).contains($0) })
  }

  @Test(arguments: ["份", "한", "語", "W", "8"])
  func singleVisibleGlyphsCanCalibrateTheirOwnWeight(_ text: String) throws {
    // Short final rows must not fall back to generic ink-density weight and
    // become a bold heading solely because only one character wrapped.
    let measured = try #require(SourceTypography.measure(
      text: text,
      inkSize: CGSize(width: 22, height: 22),
      coverage: 0.28
    ))
    #expect(measured.pointSize > 0)
  }

  @Test
  func neighboringColumnsAndVerticalTextDoNotClipHorizontalSampling() {
    let row = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.05), text: "Example")
    let column = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.6, y: 0.22, width: 0.3, height: 0.05), text: "隣の列")
    let vertical = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.27, width: 0.1, height: 0.4),
      text: "縦書き",
      isVerticalBlock: true
    )
    #expect(OCRSpatialOwnership.samplingRegion(for: row, among: [row, column, vertical]).bounds == CGRect(
      x: 0,
      y: 0,
      width: 1,
      height: 1
    ))
  }
}
