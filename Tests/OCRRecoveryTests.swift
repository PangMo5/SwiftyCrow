// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreText
import Foundation
import Synchronization
import Testing
@testable import SwiftyCrow

struct OCRRecoveryTests {

  // MARK: Internal

  @Test(arguments: ["proposal.pdf", "photo.JPEG", "report.v2.pdf"])
  func registeredFileSyntaxDoesNotTriggerASpellingRetry(_ text: String) {
    let line = OCRResult.Line(
      boundingBoxNormalized: .init(x: 0.1, y: 0.1, width: 0.3, height: 0.02),
      text: text,
      recognitionConfidence: 0.4
    )
    #expect(!OCRLineRefiner.needsRefinement(line))
  }

  @Test(arguments: ["proposal.paf", "budget.xisx"])
  func weakReferenceSpellingIsRereadWithoutDictionaryCorrection(_ text: String) async throws {
    let line = OCRResult.Line(
      boundingBoxNormalized: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.04),
      text: text,
      recognitionConfidence: 0.3
    )
    #expect(OCRLineRefiner.needsRefinement(line))
    let result = try await OCRLineRefiner
      .refine([line], in: try #require(rowImage().makeImage()), language: .auto) { _, request in
        #expect(!request.usesLanguageCorrection)
        return ["reference.pdf"]
      }
    #expect(result[0].text == "reference.pdf")
    #expect(result[0].boundingBoxNormalized == line.boundingBoxNormalized)
  }

  @Test
  func paddedOCRBoxesDoNotHideTheEstablishedRowAdvance() throws {
    let lines = repeatedRows(trailing: false).map { source in
      var source = source
      source.boundingBoxNormalized.size.height = 0.09
      if source.boundingBoxNormalized.minY > 0.48 { source.boundingBoxNormalized.origin.y += 0.08 }
      return source
    }
    let gaps = OCRTextEdgeRecovery.rowGaps(in: lines, imageSize: CGSize(width: 500, height: 500))
    #expect(gaps.count == 1)
    let gap = try #require(gaps.first)
    #expect(gap.bounds.contains(CGRect(x: 80, y: 250, width: 80, height: 60)))
  }

  @Test(arguments: [0.0, 0.018])
  func alignedRowsExposeAMissingParagraphWithVariableParagraphSpacing(_ extraSpacing: CGFloat) throws {
    let lines = repeatedRows(trailing: false).map { source in
      var source = source
      if source.boundingBoxNormalized.minY > 0.48 {
        source.boundingBoxNormalized.origin.y += 0.08 + extraSpacing
      }
      return source
    }
    let gaps = OCRTextEdgeRecovery.rowGaps(in: lines, imageSize: CGSize(width: 500, height: 500))
    #expect(gaps.count == 1)
    let gap = try #require(gaps.first)
    #expect(gap.bounds.contains(CGRect(x: 80, y: 240, width: 80, height: 60)))
    var occupied = lines
    occupied.append(.init(
      boundingBoxNormalized: CGRect(x: 0.16, y: 0.55, width: 0.7, height: 0.04),
      text: "Existing content",
      preservesSource: true
    ))
    #expect(OCRTextEdgeRecovery.rowGaps(in: occupied, imageSize: CGSize(width: 500, height: 500)).isEmpty)
    let distant = lines.map { source in
      var source = source
      if source.boundingBoxNormalized.minY > 0.48 { source.boundingBoxNormalized.origin.y += 0.3 }
      return source
    }
    #expect(OCRTextEdgeRecovery.rowGaps(in: distant, imageSize: CGSize(width: 500, height: 500)).isEmpty)
  }

  @Test(arguments: [false, true])
  func repeatedRowsExposeOneMissingPositionInEitherReadingDirection(_ trailing: Bool) throws {
    let lines = repeatedRows(trailing: trailing)
    let gaps = OCRTextEdgeRecovery.rowGaps(in: lines, imageSize: CGSize(width: 500, height: 500))
    let gap = try #require(gaps.first)
    #expect(gaps.count == 1)
    #expect(gap.bounds.contains(CGRect(x: trailing ? 340 : 80, y: 240, width: 80, height: 20)))
    #expect(gaps.map(\.bounds) == OCRTextEdgeRecovery.rowGaps(in: lines.reversed(), imageSize: CGSize(width: 500, height: 500))
      .map(\.bounds))
    var occupied = lines
    occupied.append(.init(boundingBoxNormalized: CGRect(x: 0.16, y: 0.48, width: 0.7, height: 0.04), text: "Existing row"))
    #expect(OCRTextEdgeRecovery.rowGaps(in: occupied, imageSize: CGSize(width: 500, height: 500)).isEmpty)
    #expect(OCRTextEdgeRecovery.rowGaps(in: Array(lines.prefix(4)), imageSize: CGSize(width: 500, height: 500)).isEmpty)
    let paragraph = lines.map { line in var line = line
      line.recognitionGroupID = 0
      return line
    }
    #expect(OCRTextEdgeRecovery.rowGaps(in: paragraph, imageSize: CGSize(width: 500, height: 500)).isEmpty)
    let table = lines.enumerated().map { index, source in
      var source = source
      source.tableCell = .init(table: 0, row: index, column: 0, box: source.boundingBoxNormalized)
      return source
    }
    #expect(OCRTextEdgeRecovery.rowGaps(in: table, imageSize: CGSize(width: 500, height: 500)).isEmpty)
  }

  @Test
  func repeatedRowRecoveryHasOneSharedRequestBudgetAcrossColumns() async throws {
    let columns = 7
    let width = columns * 500
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: 500,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: 500)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: 500))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    var lines = [OCRResult.Line]()
    for column in 0..<columns {
      for x in stride(from: 350, through: 410, by: 10) { context.fill(CGRect(x: column * 500 + x, y: 240, width: 4, height: 20)) }
      lines += repeatedRows(trailing: true).map { line in
        var line = line
        line.boundingBoxNormalized.origin.x = (line.boundingBoxNormalized.minX + CGFloat(column)) / CGFloat(columns)
        line.boundingBoxNormalized.size.width /= CGFloat(columns)
        line.recognitionGroupID = line.recognitionGroupID.map { $0 + column * 10 }
        return line
      }
    }
    let image = try #require(context.makeImage())
    #expect(OCRTextEdgeRecovery.rowGaps(in: lines, imageSize: CGSize(width: width, height: 500)).count == columns)
    let count = Mutex(0)
    let result = try await OCRTextEdgeRecovery.recoverRows(lines, image: image, language: .auto) { _, _, _ in
      count.withLock { $0 += 1 }
      return []
    }
    #expect(count.withLock { $0 } == 4)
    #expect(result == lines)
  }

  @Test(arguments: [false, true])
  func blankRowsAndDividersDoNotTriggerRecognition(_ divider: Bool) async throws {
    let context = try rowImage()
    if divider {
      context.setFillColor(CGColor(gray: 0, alpha: 1))
      context.fill(CGRect(x: 50, y: 250, width: 400, height: 1))
    }
    let image = try #require(context.makeImage())
    let lines = repeatedRows(trailing: true)
    let result = try await OCRTextEdgeRecovery.recoverRows(lines, image: image, language: .auto) { _, _, _ in
      Issue.record("Whitespace/divider must not launch an OCR request")
      return []
    }
    #expect(result == lines)
  }

  @Test
  func missingRowRecoveryRequiresObservedTextInsideTheGap() async throws {
    let context = try rowImage()
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    for x in stride(from: 350, through: 410, by: 10) { context.fill(CGRect(x: x, y: 240, width: 4, height: 20)) }
    let image = try #require(context.makeImage())
    let lines = repeatedRows(trailing: true)
    let observed = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.68, y: 0.48, width: 0.16, height: 0.04),
      text: "Observed label",
      recognitionConfidence: 0.9
    )
    let result = try await OCRTextEdgeRecovery.recoverRows(lines, image: image, language: .init(code: "ar")) { crop, hint, _ in
      #expect(hint.code == "ar")
      #expect(crop.contains(CGRect(x: 340, y: 240, width: 80, height: 20)))
      var outside = observed
      outside.boundingBoxNormalized.origin.y = 0.6
      var uncertain = observed
      uncertain.recognitionConfidence = 0.1
      var punctuation = observed
      punctuation.text = "---"
      return [outside, uncertain, punctuation, observed]
    }
    #expect(result.count == lines.count + 1)
    #expect(result.contains { $0.text == observed.text && $0.boundingBoxNormalized == observed.boundingBoxNormalized })
    #expect(Set(result.compactMap(\.recognitionGroupID)).count == lines.count + 1)
  }

  @Test
  func recoveryCanExtendAClippedPrefixButCannotRewriteKnownWords() {
    let old = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.12, y: 0.2, width: 0.6, height: 0.05),
      text: "ep the original files",
      recognitionGroupID: 1
    )
    let complete = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.62, height: 0.05),
      text: "Keep the original files"
    )
    #expect(OCRTextEdgeRecovery.merging([complete], into: [old], groupID: 1).map(\.text) == ["Keep the original files"])
    var changed = complete
    changed.text = "Delete the original files"
    #expect(OCRTextEdgeRecovery.merging([changed], into: [old], groupID: 1).map(\.text) == [old.text])
  }

  @Test
  func recoveredTailJoinsItsOwnParagraphOnly() {
    let old = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05),
      text: "请勿断开设备连",
      recognitionGroupID: 1
    )
    var tail = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.26, width: 0.04, height: 0.04), text: "接。")
    let joined = OCRTextEdgeRecovery.merging([tail], into: [old], groupID: 1)
    #expect(joined.count == 2)
    #expect(joined[0].followingSeparator == "")
    #expect(joined[1].recognitionGroupID == 1)
    tail.boundingBoxNormalized.origin.x = 0.8
    #expect(OCRTextEdgeRecovery.merging([tail], into: [old], groupID: 1).count == 1)
  }

  @Test
  func visualWrapEvidenceMayChangeSpacingButNeverCharactersOrNumbers() {
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "업데이트 중에는", rows: ["업데", "이트 중에는"]) == ["", nil])
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "파일을 보관하세요", rows: ["파일을", "보관하세요"]) == [" ", nil])
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "50달러", rows: ["-50", "달러"]) == nil)
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "15달러입니다", rows: ["50달러", "입니다"]) == nil)
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "분리하세요", rows: ["분리하지", "마세요"]) == nil)
  }

  @Test
  func tightlySpacedParagraphWordsCannotBecomeAnIconColumn() {
    let texts = ["원본 파일을 보관하세요", "항을 확인하세요", "하지 마세요"]
    let lines = texts.enumerated().map { i, text in
      let first = NSRange(location: 0, length: 2)
      let y = 0.2 + Double(i) * 0.06
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.1, y: y, width: 0.5, height: 0.05),
        text: text,
        imageAspectRatio: 1.5,
        recognitionGroupID: 1,
        styleRuns: [
          .init(range: first, box: CGRect(x: 0.1, y: y, width: 0.035, height: 0.05)),
          .init(
            range: NSRange(location: 3, length: (text as NSString).length - 3),
            box: CGRect(x: 0.143, y: y, width: 0.4, height: 0.05)
          ),
        ]
      )
    }
    let classified = OCRVisualStructure.classifying(.init(lines: lines))
    #expect(classified.lines.map(\.text) == texts)
    #expect(classified.lines.allSatisfy { !$0.preservesSource && !$0.preventsJoining })
  }

  @Test
  func onlyUnreliableOrdinaryTextRequiresASecondRead() {
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
      text: "äole öybi",
      recognitionConfidence: 0.11
    )
    #expect(OCRLineRefiner.needsRefinement(line))
    var confident = line
    confident.recognitionConfidence = 0.9
    #expect(!OCRLineRefiner.needsRefinement(confident))
  }

  @Test(arguments: [0, 6, 20], [false, true])
  func skippedWeakFragmentsDoNotStarveLaterCodeRecognition(_ skippedCount: Int, _ automaticLanguage: Bool) async throws {
    let image = try #require(rowImage().makeImage())
    let weak = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.04, height: 0.04),
      text: "x",
      recognitionConfidence: 0.1
    )
    let code = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.04),
      text: "let count = 4Z;",
      recognitionGroupID: 7
    )
    let context = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.4, width: 0.8, height: 0.04),
      text: "These settings control how the application displays translated text."
    )
    let input = Array(repeating: weak, count: skippedCount) + [code, context]
    var requests = 0
    let result = try await OCRLineRefiner
      .refine(input, in: image, language: automaticLanguage ? .auto : .init(code: "en")) { _, request in
        requests += 1
        #expect(!request.usesLanguageCorrection)
        return ["let count = 42;"]
      }
    #expect(requests == 1)
    #expect(Array(result.prefix(skippedCount)) == Array(input.prefix(skippedCount)))
    var expected = code
    expected.text = "let count = 42;"
    #expect(result[skippedCount] == expected)
    #expect(result.last == context)
  }

  @Test(arguments: [0, 8])
  func nativeCodeRereadSurvivesUnrelatedWeakFragments(_ skippedCount: Int) async throws {
    let context = try rowImage()
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: 80, y: 132)
    let text = NSAttributedString(string: "let count = 42;", attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 28, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    let image = try #require(context.makeImage())
    let weak = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.02, y: 0.01, width: 0.02, height: 0.02),
      text: "x",
      recognitionConfidence: 0.1
    )
    let code = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.16, y: 0.2, width: 0.7, height: 0.08),
      text: "let count = 4Z;"
    )
    let result = try await OCRLineRefiner.refine(
      Array(repeating: weak, count: skippedCount) + [code],
      in: image,
      language: .init(code: "en")
    )
    #expect(result.last?.text == "let count = 42;")
    #expect(result.last?.boundingBoxNormalized == code.boundingBoxNormalized)
    #expect(result.prefix(skippedCount).allSatisfy { $0 == weak })
  }

  @Test(arguments: [false, true])
  func lineRecoveryBudgetCountsEmptyAndSuccessfulRequests(_ emptyResult: Bool) async throws {
    let image = try #require(rowImage().makeImage())
    let code = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.04),
      text: "let count = 4Z;"
    )
    let input = Array(repeating: code, count: 12)
    var requests = 0
    let result = try await OCRLineRefiner.refine(input, in: image, language: .init(code: "en")) { _, _ in
      requests += 1
      return emptyResult ? [] : ["let count = 42;"]
    }
    #expect(requests == 6)
    #expect(Array(result.suffix(6)) == Array(input.suffix(6)))
    #expect(result.prefix(6).allSatisfy { $0.text == (emptyResult ? code.text : "let count = 42;") })
  }

  @Test
  func recognitionFailurePropagatesWithoutTryingRemainingRows() async throws {
    enum Failure: Error { case recognition }
    let image = try #require(rowImage().makeImage())
    let code = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.04),
      text: "let count = 4Z;"
    )
    var requests = 0
    await #expect(throws: Failure.self) {
      _ = try await OCRLineRefiner.refine([code, code], in: image, language: .init(code: "en")) { _, _ in
        requests += 1
        throw Failure.recognition
      }
    }
    #expect(requests == 1)
  }

  @Test
  func extraTerminalPunctuationDoesNotBlockSpacingEvidenceOrGetCopied() {
    #expect(OCRSoftWrapRefiner.confirmedSeparators(candidate: "백업은 실행됩니다.", rows: ["백", "업은 실행됩니다"]) == ["", nil])
  }

  @Test
  func chineseVisualContinuationCanCrossUnreliableParagraphIDs() {
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 0.2,
      fontWeight: .regular
    )
    let a = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05),
      text: "请勿断开设备连",
      recognitionGroupID: 1,
      appearance: appearance
    )
    let b = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.247, width: 0.6, height: 0.05),
      text: "接。请保留原始文件。",
      recognitionGroupID: 2,
      appearance: appearance
    )
    #expect(OCRResult(lines: [a, b]).coalescingParagraphFragments().joinedText == "请勿断开设备连接。请保留原始文件。")
  }

  @Test
  func rightAlignedContinuationOverridesAConflictingAlignmentHint() {
    let appearance = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.033,
      fontWeight: .regular
    )
    let a = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.33, width: 0.6, height: 0.048),
      text: "لا تفصل الجهاز أثناء",
      recognitionGroupID: 1,
      appearance: appearance,
      alignment: .leading
    )
    let b = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.62, y: 0.38, width: 0.08, height: 0.035),
      text: "التحديث.",
      recognitionGroupID: 1,
      appearance: appearance,
      alignment: .leading
    )
    #expect(OCRResult(lines: [a, b]).coalescingParagraphFragments().joinedText == "لا تفصل الجهاز أثناء التحديث.")
  }

  @Test
  func presentWordsAreInsufficientIfTheirSentenceIsSplit() {
    #expect(!CaptureQualityMetrics.paragraphIssues(
      texts: ["Do not disconnect during", "the update."],
      expected: ["Do not disconnect during the update."]
    ).isEmpty)
    #expect(CaptureQualityMetrics.paragraphIssues(
      texts: ["Do not disconnect during the update."],
      expected: ["Do not disconnect during the update."]
    ).isEmpty)
    #expect(!CaptureQualityMetrics.paragraphIssues(
      texts: ["First paragraph. Second paragraph."],
      expected: ["First paragraph.", "Second paragraph."]
    ).isEmpty)
  }

  @Test
  func sentenceCanContinueWithANumberOrUppercaseNoun() {
    let style = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.03,
      fontWeight: .regular
    )
    for (first, last) in [("가격이 바뀌었습니다. 백업은", "15분마다 실행됩니다."), ("Der Preis sinkt. Die Sicherung läuft alle 15", "Minuten.")] {
      let a = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.04),
        text: first,
        recognitionGroupID: 1,
        appearance: style
      )
      let b = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.1, y: 0.245, width: 0.3, height: 0.04),
        text: last,
        recognitionGroupID: 2,
        appearance: style
      )
      #expect(OCRResult(lines: [a, b]).coalescingParagraphFragments().joinedText == first + " " + last)
    }
  }

  @Test
  func multilineObservationUsesPhysicalRowOrder() {
    let text = "minutes.\nLa sauvegarde démarre toutes les 15"
    let observation = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.1),
      text: text,
      recognitionGroupID: 1,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 8), box: CGRect(x: 0.1, y: 0.26, width: 0.1, height: 0.04)),
        .init(
          range: NSRange(location: 9, length: (text as NSString).length - 9),
          box: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.04)
        ),
      ]
    )
    let rows = OCRObservationRows.split(observation)
    #expect(rows.map(\.text) == ["La sauvegarde démarre toutes les 15", "minutes."])
    #expect(rows.allSatisfy { $0.rowCount == 1 && $0.recognitionGroupID == 1 })
    #expect(rows[0].styleRuns[0].range.location == 0)
  }

  @Test
  func foreignRowInkCannotTurnTwoRowsIntoOneVisualRow() {
    let upper = "La sauvegarde démarre toutes les 15"
    let a = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.11),
      text: upper,
      recognitionGroupID: 1,
      styleRuns: [.init(
        range: NSRange(location: 0, length: (upper as NSString).length),
        box: CGRect(x: 0.1, y: 0.21, width: 0.7, height: 0.035)
      )]
    )
    let b = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.25, width: 0.1, height: 0.04),
      text: "minutes.",
      recognitionGroupID: 1,
      styleRuns: [.init(range: NSRange(location: 0, length: 8), box: CGRect(x: 0.1, y: 0.25, width: 0.1, height: 0.04))]
    )
    let normalized = OCRObservationRows.split([a, b])
    #expect(normalized[0].boundingBoxNormalized.height == 0.035)
    #expect(OCRResult(lines: normalized).coalescingParagraphFragments().joinedText == upper + " minutes.")
  }

  @Test
  func smallAngleNoiseCannotReverseAParagraphTail() {
    let style = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      foregroundConfidence: 0.2,
      fontSizeScale: 0.032,
      fontWeight: .regular
    )
    let a = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5494, y: 0.3551, width: 0.3154, height: 0.0305),
      text: "La sauvegarde démarre toutes les 15",
      imageAspectRatio: 1.5,
      recognitionGroupID: 1,
      appearance: style,
      alignment: .leading
    )
    let b = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5491, y: 0.3894, width: 0.0766, height: 0.0287),
      text: "minutes.",
      rotationRadians: 0.02982,
      orientedBox: CGRect(x: 0.5493, y: 0.3911, width: 0.0761, height: 0.0253),
      imageAspectRatio: 1.5,
      recognitionGroupID: 1,
      appearance: style,
      alignment: .leading
    )
    let rows = OCRResult(lines: [a, b]).coalescingParagraphFragments().lines
    #expect(rows.count == 1)
    #expect(rows.first?.text == "La sauvegarde démarre toutes les 15 minutes.")
    #expect(rows.first?.rowCount == 2)
  }

  @Test
  func isolatedCardHeadingUsesItsPageContextWithoutMergingFrames() {
    let language = Locale.Language(identifier: "fr")
    let title = OverlayLine.Source(
      recognized: .init(
        boundingBoxNormalized: CGRect(x: 0.04, y: 0.04, width: 0.7, height: 0.06),
        text: "Paramètres et confidentialité",
        appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.045)
      ),
      language: language
    )
    let label = OverlayLine.Source(
      recognized: .init(
        boundingBoxNormalized: CGRect(x: 0.05, y: 0.19, width: 0.2, height: 0.035),
        text: "Présentation",
        appearance: .init(
          background: .white,
          foreground: .black,
          confidence: 1,
          fontSizeScale: 0.035
        )
      ),
      language: language
    )
    #expect(OverlayTranslationPolicy.trailingContext(at: 1, in: [title, label]) == title.text)
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: [title, label]) == nil)
  }

  // MARK: Private

  private func repeatedRows(trailing: Bool) -> [OCRResult.Line] {
    [0, 1, 2, 4, 5].enumerated().map { index, row in
      let width = CGFloat([160, 140, 110, 150, 100][index])
      return .init(
        boundingBoxNormalized: CGRect(
          x: (trailing ? 420 - width : 80) / 500,
          y: CGFloat(120 + row * 40) / 500,
          width: width / 500,
          height: 0.04
        ),
        text: "Navigation entry",
        recognitionGroupID: row
      )
    }
  }

  private func rowImage() throws -> CGContext {
    let context = try #require(CGContext(
      data: nil,
      width: 500,
      height: 500,
      bitsPerComponent: 8,
      bytesPerRow: 2000,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: 500)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 500, height: 500))
    return context
  }

}
