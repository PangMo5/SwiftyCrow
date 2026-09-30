// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Testing
@testable import SwiftyCrow

@Suite("Capture structure regressions")
struct OCRVisualStructureTests {

  // MARK: Internal

  @Test(arguments: [false, true], [false, true])
  func aMeasuredLeadingMarkerKeepsItsSourcePixels(large: Bool, sharedBox: Bool) {
    let text = "• Backchannel"
    let body = CGRect(x: 0.14, y: 0.2, width: 0.3, height: 0.02)
    let icon = sharedBox ? body : CGRect(x: 0.1, y: 0.2, width: large ? 0.02 : 0.006, height: large ? 0.02 : 0.006)
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: icon.union(body),
      text: text,
      imageAspectRatio: 1,
      appearance: appearance,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 1), box: icon, appearance: appearance, inkBox: icon),
        .init(range: NSRange(location: 2, length: 11), box: body, appearance: appearance, inkBox: body),
      ]
    )
    let result = OCRVisualStructure.separatingStyleAccessories(.init(lines: [line])).lines
    if !sharedBox {
      #expect(result.map(\.text) == ["•", "Backchannel"])
      #expect(result[0].preservesSource && result[0].preventsJoining)
      #expect(!result[1].preservesSource)
      #expect(result[1].preventsJoining == large)
      #expect(result[0].replacementPatches.map(\.box) == [icon])
      #expect(result[1].styleRuns.first?.range == NSRange(location: 0, length: 11))
    } else {
      #expect(result.count == 1)
      #expect(result[0].text == text)
    }
  }

  @Test(arguments: ["①", "ⓘ", "1"])
  func anIsolatedEnclosedMarkerKeepsItsOwnRow(_ symbol: String) {
    let body = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.02),
      text: "A complete paragraph."
    )
    let marker = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.2, y: 0.23, width: 0.015, height: 0.015), text: symbol)
    let result = OCRVisualStructure.classifying(.init(lines: [body, marker]))
    let preserved = result.lines.first(where: { $0.text == symbol })
    #expect(preserved?.preservesSource == (symbol != "1"))
    #expect(preserved?.preventsJoining == (symbol != "1"))
  }

  @Test
  func retainingASmallBulletDoesNotBreakItsWrappedSentence() {
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let marker = CGRect(x: 0.1, y: 0.205, width: 0.006, height: 0.006)
    let body = CGRect(x: 0.14, y: 0.2, width: 0.3, height: 0.02)
    let line = OCRResult.Line(
      boundingBoxNormalized: marker.union(body),
      text: "• A sentence",
      appearance: appearance,
      styleRuns: [
        .init(
          range: NSRange(location: 0, length: 1),
          box: marker,
          appearance: appearance,
          inkBox: marker
        ),
        .init(range: NSRange(location: 2, length: 10), box: body, appearance: appearance, inkBox: body),
      ]
    )
    var result = OCRVisualStructure.separatingStyleAccessories(.init(lines: [line])).lines
    #expect(result.count == 2)
    #expect(result[0].preservesSource)
    #expect(!result[1].preventsJoining)
    result[1].recognitionGroupID = 7
    var continuation = OCRResult.Line(
      boundingBoxNormalized: body.offsetBy(dx: 0, dy: 0.025),
      text: "continues here.",
      appearance: appearance
    )
    continuation.recognitionGroupID = 7
    let joined = OCRResult(lines: [result[1], continuation]).coalescingParagraphFragments()
    #expect(joined.lines.map(\.text) == ["A sentence continues here."])
  }

  @Test
  func referenceRereadRequiresIndependentSymbolEvidence() {
    func column(_ values: [String], index: Int) -> [OCRResult.Line] {
      values.enumerated().map { row, text in
        let box = CGRect(x: Double(index) * 0.2, y: Double(row) * 0.05, width: 0.1, height: 0.03)
        return .init(
          boundingBoxNormalized: box,
          text: text,
          tableCell: .init(table: 0, row: row + 1, column: index, box: box)
        )
      }
    }
    let numbers = column(["116", "132", "value"], index: 0)
    #expect(!OCRTableRecovery.requiresReferenceEvidence(numbers))
    #expect(OCRTableRecovery.requiresReferenceEvidence(numbers + column(["x16", "x32", "other"], index: 1)))
    #expect(!OCRTableRecovery.requiresReferenceEvidence(column(["x16", "x32", "other"], index: 1)))
  }

  @Test
  func nativeCellOwnsCenteredGlyphsDespiteAnUnderestimatedBottomEdge() {
    let cell = OCRTableCell(
      table: 0,
      row: 6,
      column: 1,
      box: CGRect(x: 0.54772075, y: 0.62016321, width: 0.02820167, height: 0.02108293)
    )
    let word = CGRect(x: 0.55549065, y: 0.63207547, width: 0.01401869, height: 0.01320755)
    #expect(OCRTableCell.containing(word, in: [cell]) == cell)
    #expect(OCRTableCell.containing(word.offsetBy(dx: 0, dy: 0.025), in: [cell]) == nil)
    let acrossColumns = CGRect(x: 0.54, y: word.minY, width: 0.065, height: word.height)
    #expect(OCRTableCell.containing(acrossColumns, in: [cell]) == nil)
  }

  @Test
  func tableSymbolsPropagateOnlyIntoObservedCodeSurfaces() {
    var symbol = OCRResult.Line(boundingBoxNormalized: .init(x: 0.2, y: 0.2, width: 0.05, height: 0.03), text: "alpha")
    symbol.preservesSource = true
    symbol.tableCell = .init(table: 0, row: 3, column: 1, box: symbol.boundingBoxNormalized)
    let text = "alpha alpha types"
    let plain = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let chip = OverlaySourceAppearance(
      background: .init(red: 0.9, green: 0.9, blue: 0.9, alpha: 1),
      foreground: .black,
      confidence: 1
    )
    let prose = OCRResult.Line(
      boundingBoxNormalized: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.04),
      text: text,
      appearance: plain,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 5), box: .zero, appearance: chip),
        .init(range: NSRange(location: 6, length: 5), box: .zero, appearance: plain),
        .init(range: NSRange(location: 12, length: 5), box: .zero, appearance: chip),
      ]
    )
    let result = OCRTableStructure.protectingInlineSymbols(.init(lines: [symbol, prose]))
    #expect(result.lines[1].styleRuns.map(\.appearance.fontDesign) == [.monospaced, .standard, .standard])
  }

  @Test
  func nativeSymbolColumnProtectsAlphabeticValuesButNotHeadersOrProse() {
    func cell(_ text: String, row: Int, column: Int = 1, table: Int = 0) -> OCRResult.Line {
      let box = CGRect(x: 0.2 * Double(column), y: 0.1 + Double(row) * 0.04, width: 0.08, height: 0.025)
      return .init(
        boundingBoxNormalized: box,
        text: text,
        tableCell: .init(table: table, row: row, column: column, box: box)
      )
    }
    let values = [cell("Signed", row: 0), cell("i8", row: 1), cell("116", row: 2), cell("132", row: 3), cell("isize", row: 4)]
    #expect(OCRTableStructure.isSymbolColumnValue(values[4], among: values))
    #expect(OCRTableStructure.isSymbolColumnValue(values[1], among: values))
    #expect(OCRTableStructure.isSymbolColumnValue(values[2], among: values))
    #expect(!OCRTableStructure.isSymbolColumnValue(values[0], among: values))
    #expect(OCRVisualStructure.classifying(.init(lines: values)).lines.first { $0.text == "isize" }?.preservesSource == true)
    #expect(!OCRTableStructure.isSymbolColumnValue(cell("types", row: 4, column: 0), among: values))
    #expect(!OCRTableStructure.isSymbolColumnValue(cell("isize", row: 4, table: 1), among: values))
    var prose = cell("types", row: 4)
    prose.tableCell = nil
    #expect(!OCRTableStructure.isSymbolColumnValue(prose, among: values))
    let numbers = [cell("10", row: 1), cell("20", row: 2), cell("Total", row: 3)]
    #expect(!OCRTableStructure.isSymbolColumnValue(numbers[2], among: numbers))
  }

  @Test(arguments: [false, true], [false, true])
  func tableSymbolsShareObservedChipStyleAcrossSamplingNoise(dark: Bool, measuredCodeFont: Bool) {
    func color(_ value: CGFloat) -> OverlayColor {
      .init(red: value, green: value, blue: value, alpha: 1)
    }
    let background: CGFloat = dark ? 0.1 : 1
    let direction: CGFloat = dark ? 1 : -1
    func appearance(_ delta: CGFloat, font: CGFloat = 0.02) -> OverlaySourceAppearance {
      .init(
        background: color(background + direction * delta),
        foreground: dark ? .white : .black,
        confidence: 1,
        fontSizeScale: font
      )
    }
    let symbols = ["alpha", "beta"].enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: .init(x: 0.2, y: 0.1 + Double(index) * 0.05, width: 0.05, height: 0.03),
        text: text,
        preservesSource: true,
        tableCell: .init(table: 0, row: index + 1, column: 1, box: .zero)
      )
    }
    let text = "alpha beta beta beta beta prose"
    var anchor = appearance(measuredCodeFont ? 0.0249 : 0.026)
    if measuredCodeFont { anchor.fontDesign = .monospaced }
    var prose = OCRResult.Line(
      boundingBoxNormalized: .init(x: 0.1, y: 0.5, width: 0.8, height: 0.04),
      text: text,
      appearance: appearance(0),
      styleRuns: [
        .init(range: NSRange(location: 0, length: 5), box: .zero, appearance: anchor),
        .init(range: NSRange(location: 6, length: 4), box: .zero, appearance: appearance(0.024)),
        .init(range: NSRange(location: 11, length: 4), box: .zero, appearance: appearance(0)),
        .init(range: NSRange(location: 16, length: 4), box: .zero, appearance: appearance(0.01)),
        .init(
          range: NSRange(location: 21, length: 4),
          box: .zero,
          appearance: appearance(0.024, font: 0.04)
        ),
        .init(range: NSRange(location: 26, length: 5), box: .zero, appearance: appearance(0.024)),
      ]
    )
    let classified = OCRTableStructure.protectingInlineSymbols(.init(lines: symbols + [prose])).lines.last!
    #expect(classified.styleRuns.map(\.appearance.fontDesign) == [
      .monospaced,
      .monospaced,
      .standard,
      .standard,
      .standard,
      .standard,
    ])
    prose.styleRuns.removeFirst()
    let isolated = OCRTableStructure.protectingInlineSymbols(.init(lines: symbols + [prose])).lines.last!
    #expect(isolated.styleRuns.allSatisfy { $0.appearance.fontDesign == .standard })
  }

  @Test
  func measuredWholeLabelInkRecoversNativeCellBeforeParagraphJoining() {
    let cell = OCRTableCell(table: 0, row: 3, column: 1, box: .init(x: 0.4, y: 0.4, width: 0.2, height: 0.02))
    let observation = CGRect(x: 0.45, y: 0.41, width: 0.08, height: 0.03)
    let ink = CGRect(x: 0.45, y: 0.412, width: 0.08, height: 0.014)
    let label = OCRResult.Line(boundingBoxNormalized: observation, text: "value", styleRuns: [
      .init(range: NSRange(location: 0, length: 5), box: observation, inkBox: ink)
    ])
    let symbols = ["x16", "x32"].enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: .init(x: 0.45, y: 0.3 + Double(index) * 0.04, width: 0.08, height: 0.02),
        text: text,
        tableCell: .init(table: 0, row: index + 1, column: 1, box: .zero)
      )
    }
    #expect(OCRTableCell.containing(observation, in: [cell]) == nil)
    let result = OCRTableStructure.classifyingObservedCells(.init(lines: symbols + [label]), cells: [cell])
    #expect(result.lines.last?.tableCell == cell)
    #expect(result.lines.last?.recognitionContainer == cell.box)
    #expect(result.lines.last?.preservesSource == true)
    #expect(result.lines.last?.preventsJoining == true)
    #expect(result.lines.last?.boundingBoxNormalized == observation)

    var partial = label
    partial.text = "value prose"
    #expect(OCRTableStructure.classifyingObservedCells(.init(lines: symbols + [partial]), cells: [cell]).lines.last?
      .tableCell == nil)
    var missing = label
    missing.styleRuns[0].inkBox = nil
    #expect(OCRTableStructure.classifyingObservedCells(.init(lines: symbols + [missing]), cells: [cell]).lines.last?
      .tableCell == nil)
    var occupied = symbols[0]
    occupied.tableCell = cell
    #expect(OCRTableStructure.classifyingObservedCells(.init(lines: [occupied, label]), cells: [cell]).lines.last?
      .tableCell == nil)
    let competing = OCRTableStructure.classifyingObservedCells(.init(lines: [label, label]), cells: [cell])
    #expect(competing.lines.allSatisfy { $0.tableCell == nil })
    let crossing = OCRResult.Line(boundingBoxNormalized: .init(x: 0.55, y: 0.4, width: 0.4, height: 0.03), text: "other prose")
    #expect(OCRTableCell.containing(crossing.boundingBoxNormalized, in: [cell]) == nil)
    let crossed = OCRTableStructure.classifyingObservedCells(.init(lines: symbols + [label, crossing]), cells: [cell])
    #expect(crossed.lines[symbols.count].tableCell == nil)
    var outside = label
    outside.styleRuns[0].inkBox = ink.offsetBy(dx: 0, dy: 0.04)
    #expect(OCRTableStructure.classifyingObservedCells(.init(lines: [outside]), cells: [cell]).lines.last?.tableCell == nil)
    let prose = OCRTableStructure.classifyingObservedCells(.init(lines: [label]), cells: [cell]).lines[0]
    #expect(prose.tableCell == cell)
    #expect(!prose.preservesSource)
  }

  @Test
  func punctuationCannotCalibrateFontSizeFromAnAliasedWholeWordBox() {
    #expect(SourceTypography.measure(text: "...", inkSize: CGSize(width: 90, height: 22), coverage: 0.4) == nil)
  }

  @Test
  func languagePickerSplitAcrossObservationsKeepsItsOriginalLabels() {
    let lines: [OCRResult.Line] = [
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.8, width: 0.25, height: 0.04), text: "English $701"),
      .init(boundingBoxNormalized: CGRect(x: 0.4, y: 0.8, width: 0.4, height: 0.04), text: "日本語 简体中文 繁體中文"),
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.5, width: 0.3, height: 0.04), text: "English lessons"),
    ]
    let result = OCRVisualStructure.classifying(.init(lines: lines))
    #expect(result.lines.prefix(2).allSatisfy { $0.preservesSource })
    #expect(!result.lines[2].preservesSource)
  }

  @Test
  func copyActionAfterCommandIsNotProtectedAsLiteralMetadata() {
    let command = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.04),
      text: "brew install --cask example"
    )
    let action = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.7, y: 0.2, width: 0.08, height: 0.04), text: "Copy")
    let sources = [command, action].map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "en")) }
    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
  }

  @Test
  func isolatedToolbarSymbolsRemainArtworkEvenWithConfidentOCR() {
    let icons: [OCRResult.Line] = [
      .init(
        boundingBoxNormalized: CGRect(x: 0.73622, y: 0.0625, width: 0.035433, height: 0.016667),
        text: "G",
        imageAspectRatio: 0.528464,
        recognitionConfidence: 0.8
      ),
      .init(
        boundingBoxNormalized: CGRect(x: 0.811024, y: 0.05625, width: 0.03937, height: 0.025),
        text: "白",
        imageAspectRatio: 0.528464,
        recognitionConfidence: 0.92
      ),
    ]
    let result = OCRVisualStructure.classifying(.init(lines: icons))
    #expect(result.lines.allSatisfy { $0.preservesSource })
    let prose = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.86, y: 0.05625, width: 0.12, height: 0.025), text: "色の背景")
    let withProse = OCRVisualStructure.classifying(.init(lines: icons + [prose]))
    #expect(!withProse.lines.first(where: { $0.text == "白" })!.preservesSource)
  }

  @Test(arguments: ["iPhone 16 Pro", "iOS 18.5", "SDK 26.4", "MacBook Air 13"])
  func deviceAndSDKNamesKeepTheirOriginalPixels(_ text: String) {
    #expect(OCRTextSemantics.isIdentifier(text))
  }

  @Test(arguments: ["September 18", "3 days ago", "Chapter 16", "Postal Service chief says"])
  func ordinaryDatesAndProseAreNotProductIdentifiers(_ text: String) {
    #expect(!OCRTextSemantics.isIdentifier(text))
  }

  @Test
  func aShortLowercaseWordCannotBecomeALeadingIcon() {
    let lines = ["to limit mail voting", "in the source text", "on the next screen"].enumerated().map { index, text in
      let first = String(text.split(separator: " ")[0])
      let y = 0.1 + CGFloat(index) * 0.06
      let prefix = CGRect(x: 0.1, y: y, width: 0.035, height: 0.04)
      let rest = CGRect(x: 0.14, y: y, width: 0.4, height: 0.04)
      return OCRResult.Line(boundingBoxNormalized: prefix.union(rest), text: text, styleRuns: [
        .init(range: NSRange(location: 0, length: first.utf16.count), box: prefix),
        .init(range: NSRange(location: 3, length: text.utf16.count - 3), box: rest),
      ])
    }
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines))
    #expect(result.lines.count == 3)
    #expect(result.lines.allSatisfy { !$0.preservesSource && !$0.preventsJoining })
  }

  @Test
  func cachedGlyphTemplatesStillDistinguishDifferentSourceWeights() throws {
    let thin = try #require(SourceTypography.measure(text: "Workspace", inkSize: CGSize(width: 150, height: 24), coverage: 0.1))
    let thick = try #require(SourceTypography.measure(text: "Workspace", inkSize: CGSize(width: 150, height: 24), coverage: 0.9))
    #expect(thin.weight.rawValue < thick.weight.rawValue)
  }

  @Test
  func navigationUsesNearbyTechnicalContextWithoutMergingItsFrames() {
    let sources = ["GitHub", "Releases", "CLI", "Configuration", "License"].enumerated().map { index, text in
      OverlayLine.Source(
        recognized: .init(boundingBoxNormalized: CGRect(x: CGFloat(index) * 0.18, y: 0.1, width: 0.15, height: 0.04), text: text),
        language: Locale.Language(identifier: "en")
      )
    }
    #expect(OverlayTranslationPolicy.trailingContext(at: 3, in: sources) == "CLI")
    #expect(OverlayTranslationPolicy.trailingContext(at: 4, in: sources) == "CLI")
    #expect(!OverlayTranslationPolicy.preservesSource(at: 3, in: sources))
  }

  @Test
  func tabLabelsReceiveTheirNeighborsAsContext() {
    let sources = ["Today", "News+", "Sports", "Following"].enumerated().map { index, text in
      OverlayLine.Source(
        recognized: .init(
          boundingBoxNormalized: CGRect(x: 0.05 + CGFloat(index) * 0.24, y: 0.9, width: 0.12, height: 0.02),
          text: text
        ),
        language: Locale.Language(identifier: "en")
      )
    }
    #expect(OverlayTranslationPolicy.trailingContext(at: 2, in: sources) == "Today / News+ / Following")
    #expect(OverlayTranslationPolicy.trailingContext(at: 3, in: sources) == "Today / News+ / Sports")
  }

  @Test
  func lowConfidenceGlyphsAboveATabRowRemainIcons() {
    let labels = ["Today", "News+", "Sports", "Following"].enumerated().map { index, text in
      OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1 + CGFloat(index) * 0.2, y: 0.9, width: 0.08, height: 0.02), text: text)
    }
    let icons = [
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.12, y: 0.84, width: 0.04, height: 0.05),
        text: "N",
        recognitionConfidence: 0.35
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.52, y: 0.84, width: 0.04, height: 0.05),
        text: "DoC",
        recognitionConfidence: 0.39
      ),
    ]
    let result = OCRVisualStructure.classifying(OCRResult(lines: icons + labels))
    #expect(result.lines.prefix(2).allSatisfy { $0.preservesSource })
    #expect(result.lines.suffix(4).allSatisfy { !$0.preservesSource })
  }

  @Test
  func naturalLanguageMetadataNextToAFileStillTranslates() {
    var file = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04), text: "Sources/Core")
    file.preservesSource = true
    let sources = [file, .init(boundingBoxNormalized: CGRect(x: 0.7, y: 0.1, width: 0.2, height: 0.04), text: "3 days ago")]
      .map { OverlayLine.Source(recognized: $0, language: Locale.Language(identifier: "en")) }
    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
  }

  @Test
  func terminalFootnoteDoesNotBecomeASeparateWord() {
    #expect(TranslationTextStructure
      .matchingSourceBreaks("앱에서 도움을 받으세요. *", source: "Get help in your app.*") == "앱에서 도움을 받으세요.*")
    #expect(TranslationTextStructure.matchingSourceBreaks("A * B", source: "A * B") == "A * B")
  }

  @Test
  func nativeLanguageSelectorKeepsItsOriginalPixels() {
    let result = OCRVisualStructure.classifying(OCRResult(lines: [
      .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.7, width: 0.5, height: 0.04), text: "한국어 日本語 简体中文 繁體中文")
    ]))
    #expect(result.lines[0].preservesSource)
  }

  @Test(arguments: ["O forks", "g O forks"])
  func uncertainCounterRetainsPixelsInsteadOfDroppingItsValue(_ ambiguous: String) {
    let lines = ["0 watching", ambiguous, "4 months old"].enumerated().map { index, text in
      OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.15, y: 0.1 + CGFloat(index) * 0.06, width: 0.2, height: 0.03), text: text)
    }
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines))
    #expect(result.lines[1].preservesSource)
    #expect(result.lines[1].needsReview)
    #expect(!result.lines[0].preservesSource)
  }

  @Test
  func isolatedCheckGlyphDoesNotBecomeAJapaneseTranslation() {
    let lines = [
      OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.025, height: 0.03), text: "く", recognitionGroupID: 0),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.35, y: 0.1, width: 0.3, height: 0.03),
        text: "382 Commits",
        recognitionGroupID: 1
      ),
    ]
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines))
    #expect(result.lines[0].preservesSource)
    #expect(!result.lines[1].preservesSource)
  }

  @Test
  func liveTranslationCannotSurviveAChangeToALiteralRole() {
    var recognized = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.03), text: "workspace")
    let previous = OverlayLine.Source(recognized: recognized, language: Locale.Language(identifier: "en"))
    recognized.preservesSource = true
    let current = OverlayLine.Source(recognized: recognized, language: previous.language)
    #expect(!current.canReuseTranslation(relativeTo: previous, imageSize: CGSize(width: 1200, height: 800)))
  }

  @Test
  func repeatedAccessoryColumnKeepsIconsOutOfLabelTranslations() {
    let lines = [("M", "Readme"), ("s&", "License"), ("*", "25 stars")].enumerated().map { index, item in
      let y = 0.1 + CGFloat(index) * 0.08
      let prefix = CGRect(x: 0.05, y: y, width: 0.035, height: 0.04)
      let label = CGRect(x: 0.11, y: y, width: 0.2, height: 0.04)
      return OCRResult.Line(
        boundingBoxNormalized: prefix.union(label),
        text: "\(item.0) \(item.1)",
        rotationRadians: index == 0
          ? 0.04
          : 0,
        orientedBox: prefix.union(label),
        styleRuns: [
          .init(range: NSRange(location: 0, length: item.0.utf16.count), box: prefix),
          .init(range: NSRange(location: item.0.utf16.count + 1, length: item.1.utf16.count), box: label),
        ]
      )
    }
    let separateIcon = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.34, width: 0.035, height: 0.04),
      text: "日",
      recognitionGroupID: 4
    )
    let date = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.11, y: 0.34, width: 0.2, height: 0.04),
      text: "4 months old",
      recognitionGroupID: 4
    )
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines + [separateIcon, date]))
    #expect(result.lines.count == 8)
    #expect(result.lines.filter(\.preservesSource).map(\.text) == ["M", "s&", "*", "日"])
    #expect(result.lines.allSatisfy { $0.orientedBox == nil })
  }

  @Test
  func hangingListContinuationRemainsOneTranslationUnitOnWideCaptures() {
    let lines = [
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.05, y: 0.2, width: 0.8, height: 0.04),
        text: "• Reopen assigned apps when their window was",
        imageAspectRatio: 2,
        recognitionGroupID: 1,
        alignment: .leading
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.073, y: 0.26, width: 0.08, height: 0.04),
        text: "closed.",
        imageAspectRatio: 2,
        recognitionGroupID: 1,
        alignment: .leading
      ),
    ]
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 1)
    #expect(result.joinedText == "• Reopen assigned apps when their window was closed.")
  }

  @Test(arguments: [CGSize(width: 1500, height: 350), CGSize(width: 1500, height: 1500)])
  func navigationSpacingUsesPixelsRegardlessOfCaptureAspect(_ size: CGSize) {
    let lines = ["Releases", "Configuration", "License"].enumerated().map { index, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: CGFloat(50 + index * 200) / size.width,
          y: 50 / size.height,
          width: 150 / size.width,
          height: 24 / size.height
        ),
        text: text,
        imageAspectRatio: size.width / size.height,
        recognitionGroupID: index
      )
    }
    #expect(OCRResult(lines: lines).coalescingParagraphFragments().lines.count == 3)
  }

  @Test
  func inlineSentenceStillJoinsAcrossColorFragments() {
    let size = CGSize(width: 1500, height: 350)
    let a = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.2, height: 24 / size.height),
      text: "Read the",
      imageAspectRatio: size.width / size.height,
      recognitionGroupID: 1
    )
    let b = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.305, y: 0.2, width: 0.2, height: 24 / size.height),
      text: "documentation.",
      imageAspectRatio: size.width / size.height,
      recognitionGroupID: 1
    )
    #expect(OCRResult(lines: [a, b]).coalescingParagraphFragments().joinedText == "Read the documentation.")
  }

  @Test
  func unknownCommandRowsStayExecutable() {
    let lines = ["quartz workspace list", "quartz workspace activate", "quartz window focus"].enumerated().map { index, text in
      monospacedLine(text, y: 0.1 + CGFloat(index) * 0.06)
    }
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines)).coalescingParagraphFragments()
    #expect(result.lines.count == 3)
    #expect(result.lines.allSatisfy { $0.preservesSource })
    #expect(result.lines.map(\.text) == lines.map(\.text))
  }

  @Test
  func fileColumnDoesNotTranslateDirectoryNamesOrNeighboringProse() {
    let paths = ["Engine/Sources", "EngineCLI/Sources", "Tests/Sources", "Localization"]
    let files = paths.enumerated().map { index, text in
      OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.05, y: 0.1 + CGFloat(index) * 0.1, width: 0.2, height: 0.03), text: text)
    }
    let message = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.45, y: 0.1, width: 0.4, height: 0.03),
      text: "Improve language support"
    )
    let result = OCRVisualStructure.classifying(OCRResult(lines: files + [message]))
    #expect(result.lines.prefix(4).allSatisfy { $0.preservesSource })
    #expect(result.lines.last?.preservesSource == false)
  }

  @Test
  func adjacentControlSurfacesCannotShareTheirTextArea() {
    let a = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.03), text: "Previous")
    let b = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.3, y: 0.2, width: 0.15, height: 0.03), text: "Continue")
    let left = OCRVisualStructure.surfaceSearchBounds(for: a, among: [a, b])
    let right = OCRVisualStructure.surfaceSearchBounds(for: b, among: [a, b])
    #expect(left.maxX <= right.minX)
    #expect(left.contains(a.boundingBoxNormalized))
    #expect(right.contains(b.boundingBoxNormalized))
  }

  @Test
  func longerEnglishControlDoesNotStartAnUnrelatedLanguageSession() {
    let client = LanguageDetectionClient(detect: { text, _ in
      text == "Configuration" ? Language(code: "ca") : Language(code: "en")
    })
    let result = client.resolveSources(for: ["Manage the software settings here.", "Configuration"], configured: .auto)
    #expect(result == [Language(code: "en"), Language(code: "en")])
  }

  @Test(arguments: ["Release notes", "workspace", "minimum", "Settings"])
  func regularTextDoesNotBecomeBoldBecauseOfItsLetters(_ text: String) async throws {
    let analyzed = try await analyze(text, weight: .regular)
    #expect(analyzed.appearance.fontWeight.rawValue <= OverlayFontWeight.medium.rawValue)
    #expect(abs(analyzed.appearance.fontSizeScale * 160 - 32) < 5)
  }

  @Test
  func actualBoldTextRetainsEmphasis() async throws {
    let analyzed = try await analyze("Workspace settings", weight: .bold)
    #expect(analyzed.appearance.fontWeight.rawValue >= OverlayFontWeight.semibold.rawValue)
  }

  // MARK: Private

  private func analyze(_ text: String, weight: NSFont.Weight) async throws -> OCRResult.Line {
    let context = try #require(CGContext(
      data: nil,
      width: 600,
      height: 160,
      bitsPerComponent: 8,
      bytesPerRow: 2400,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.05, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 160))
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 32, weight: weight),
      .foregroundColor: NSColor.white,
    ]))
    let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
    context.textPosition = CGPoint(x: 30, y: 70)
    CTLineDraw(line, context)
    let box = CGRect(
      x: (30 + bounds.minX) / 600,
      y: (160 - 70 - bounds.maxY) / 160,
      width: bounds.width / 600,
      height: bounds.height / 160
    )
    let source = OCRResult.Line(
      boundingBoxNormalized: box,
      text: text,
      imageAspectRatio: 600 / 160,
      styleRuns: [.init(range: NSRange(location: 0, length: text.utf16.count), box: box)]
    )
    let analyzed = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: OCRResult(lines: [source]),
      from: try #require(context.makeImage())
    )
    return try #require(analyzed.lines.first)
  }

  private func monospacedLine(_ text: String, y: CGFloat) -> OCRResult.Line {
    let words = text.split(separator: " ")
    var offset = 0
    let runs = words.map { word in
      defer { offset += word.utf16.count + 1 }
      return OverlaySourceStyleRun(
        range: NSRange(location: offset, length: word.utf16.count),
        box: CGRect(
          x: 0.1 + CGFloat(offset) * 0.009,
          y: y,
          width: CGFloat(word.utf16.count) * 0.009,
          height: 0.035
        )
      )
    }
    return OCRResult.Line(boundingBoxNormalized: runs.reduce(runs[0].box) { $0.union($1.box) }, text: text, styleRuns: runs)
  }
}
