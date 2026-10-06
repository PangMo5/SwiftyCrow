// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Synchronization
import Testing
@testable import SwiftyCrow

@Suite("Captured inline literal fidelity")
struct InlineSourceFragmentTests {

  // MARK: Internal

  @Test
  func rewordedContextKeepsTheLinkWithItsTranslatedPhrase() throws {
    let link = URL(string: "swiftycrow-style://run/1")!
    var phrase = AttributedString("من سلسلة مقالات")
    phrase.link = link
    let source = AttributedString("جزء ") + phrase + AttributedString(" حول")
    let target = try #require(TranslationStyleMapper.contextualTranslation(
      source: source,
      response: "관련 <s0>기사 시리즈</s0>의 일부"
    ))
    #expect(String(target.characters) == "관련 기사 시리즈의 일부")
    let marked = try #require(TranslationStyleMapper.contextualTranslation(
      source: source,
      response: "관련 ZXQSTYLE0OPEN 기사 시리즈 ZXQSTYLE0CLOSE 의 일부"
    ))
    #expect(marked.runs.filter { $0.link == link }.map { String(marked.characters[$0.range]) } == [" 기사 시리즈 "])
    #expect(target.runs.filter { $0.link == link }.map { String(target.characters[$0.range]) } == ["기사 시리즈"])
    let rtl = try #require(TranslationStyleMapper.contextualTranslation(
      source: source,
      response: "ZXQSTYLE0CLOSE시리즈 기사ZXQSTYLE0OPEN의 일부"
    ))
    #expect(rtl.runs.filter { $0.link == link }.map { String(rtl.characters[$0.range]) } == ["시리즈 기사"])
    #expect(TranslationStyleMapper.contextualTranslation(source: source, response: "관련 기사의 일부") == nil)
    #expect(TranslationStyleMapper.contextualTranslation(
      source: source,
      response: "<s0>기사</s0> <s0>시리즈</s0>"
    ) == nil)
  }

  @Test
  func sourcePixelGateRequiresTheWholeRegionAndTranslatedPublication() throws {
    let input = try fixture()
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [input.line]), image: input.image)
    var line = OverlayLine(id: UUID(), source: .init(recognized: result.lines[0], language: .init(identifier: "en")))
    let run = try #require(line.source.styleRuns.first { $0.sourceFragment != nil })
    let box = try #require(run.inkBox)
    let expectation = CaptureSourceFragmentExpectation(
      sourcePrefix: "Values range",
      region: [box.minX, box.minY, box.width, box.height]
    )
    #expect(!CaptureQualityMetrics.sourceFragmentIssues(lines: [line], expected: [expectation]).isEmpty)
    let source = try #require(line.source.attributedTextForTranslation())
    let target = "값은 28 - 1까지 저장된다."
    let aligned = TranslationStyleMapper.align(source: source, target: target)
    line.showTranslation(target, attributedText: aligned.target, language: .init(identifier: "ko"))
    #expect(CaptureQualityMetrics.sourceFragmentIssues(lines: [line], expected: [expectation]).isEmpty)
    var outside = expectation
    outside.region[2] += 0.05
    #expect(!CaptureQualityMetrics.sourceFragmentIssues(lines: [line], expected: [outside]).isEmpty)
    #expect(!CaptureQualityMetrics.sourceFragmentIssues(lines: [line, line], expected: [expectation]).isEmpty)
  }

  @Test(arguments: [false, true])
  func nativeFragmentLookupUsesThePrimaryCodeProtectionContract(_ missingMarker: Bool) async throws {
    let id = UUID()
    var code = AttributedString("i8")
    code.inlinePresentationIntent = .code
    code.link = URL(string: "swiftycrow-style://run/0")!
    let link = URL(string: "swiftycrow-style://run/1?source=pixels")!
    var formula = AttributedString("2⁷ − 1")
    formula.link = link
    let source = code + AttributedString(" stores ") + formula
    let target = "i8에는 127까지 저장됩니다."
    let anchors = try await TranslationClient.aligningNativeStyles(
      [id: target],
      linesByID: [id: .init(id: id, text: String(source.characters), attributedText: source)],
      preserving: [:]
    ) { request in
      #expect(String(request.characters) == "ZXQ000XQZ stores 2⁷ − 1")
      #expect(request.runs.filter { $0.link == link }.map { String(request.characters[$0.range]) } == ["2⁷ − 1"])
      var value = AttributedString("127")
      value.link = link
      return AttributedString(missingMarker ? "i8에는 " : "ZXQ000XQZ에는 ") + value + AttributedString("까지 저장됩니다.")
    }
    let aligned = TranslationStyleMapper.align(source: source, target: target, preserving: anchors[id])
    #expect(aligned.hasUnmappedSourceFragments == missingMarker)
    #expect(String(aligned.target.characters) == target)
  }

  @Test
  func restorationDiagnosticRetainsFragmentOwnershipAndDimensions() throws {
    let input = try fixture()
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [input.line]), image: input.image)
    var line = OverlayLine(id: UUID(), source: .init(recognized: result.lines[0], language: .init(identifier: "en")))
    let source = try #require(line.source.attributedTextForTranslation())
    let target = "값은 28 - 1까지 저장된다."
    let aligned = TranslationStyleMapper.align(source: source, target: target)
    line.showTranslation(target, attributedText: aligned.target, language: .init(identifier: "ko"))
    #expect(line.shouldReplaceSourcePixels)
    let hidden = CaptureQualityMetrics.hidingTargetInk(line)
    #expect(hidden.content == line.content)
    #expect(hidden.shouldReplaceSourcePixels)
    let original = try #require(line.source.styleRuns.compactMap(\.sourceFragment).first)
    let transparent = try #require(hidden.source.styleRuns.compactMap(\.sourceFragment).first)
    #expect(transparent.width == original.width && transparent.height == original.height)
    #expect(transparent.descent == original.descent && transparent.referenceFontSize == original.referenceFontSize)
    #expect(transparent.pixels.allSatisfy { $0 == 0 })
    #expect(hidden.source.replacementPatches == line.source.replacementPatches)
    #expect(hidden.displayedStyleRuns.map(\.range) == line.displayedStyleRuns.map(\.range))
  }

  @Test
  func failedNativeLookupRetainsOtherAnchorsAndAllowsLexicalAlignment() async throws {
    enum LookupError: Error { case unavailable }
    let failedID = UUID()
    let successfulID = UUID()
    let link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    var failedSource = AttributedString("2⁸ − 1")
    failedSource.link = link
    var successfulSource = AttributedString("2⁷ − 1")
    successfulSource.link = link
    var successfulNative = AttributedString("127")
    successfulNative.link = link
    let anchors = try await TranslationClient.aligningNativeStyles(
      [failedID: "255", successfulID: "127"],
      linesByID: [
        failedID: .init(id: failedID, text: "2⁸ − 1", attributedText: failedSource),
        successfulID: .init(id: successfulID, text: "2⁷ − 1", attributedText: successfulSource),
      ],
      preserving: [:]
    ) { source in
      if source == failedSource { throw LookupError.unavailable }
      return successfulNative
    }
    #expect(anchors[successfulID] == successfulNative)
    let unresolved = TranslationStyleMapper.align(source: failedSource, target: "255", preserving: anchors[failedID])
    #expect(unresolved.hasUnmappedSourceFragments)
    let lexical = TranslationStyleMapper.align(
      source: failedSource,
      target: "255",
      alternatives: [link: "255"],
      preserving: anchors[failedID]
    )
    #expect(!lexical.hasUnmappedSourceFragments)
    #expect(String(lexical.target.characters) == "255")
  }

  @Test
  func optionalNativeLookupStillPropagatesCancellation() async throws {
    let id = UUID()
    var source = AttributedString("2⁸ − 1")
    source.link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    await #expect(throws: CancellationError.self) {
      _ = try await TranslationClient.aligningNativeStyles(
        [id: "255"],
        linesByID: [id: .init(id: id, text: "2⁸ − 1", attributedText: source)],
        preserving: [:]
      ) { _ in throw CancellationError() }
    }
  }

  @Test(arguments: [
    ("2⁸ − 1", "부호가 없는 변형은 28 - 1까지 저장한다.", "28 - 1"),
    ("3-1", "표 3‐1은 정수 형식이다.", "3‐1"),
    ("2⁸ − 1", "القيم من ٠ إلى ٢٨ − ١.", "٢٨ − ١"),
    ("3-1", "Table 3-1 is shown.", "3-1"),
    ("2⁸ − 1", "Values 28 - 1 inclusive.", "28 - 1"),
  ])
  func imageAlignmentDoesNotRewritePrimaryProse(_ sample: (String, String, String)) {
    var source = AttributedString(sample.0)
    source.link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    let aligned = TranslationStyleMapper.align(source: source, target: sample.1)
    #expect(!aligned.hasUnmappedSourceFragments)
    #expect(String(aligned.target.characters) == sample.1)
    let linked = aligned.target.runs.filter { $0.link != nil }.map { String(aligned.target.characters[$0.range]) }
    #expect(linked == [sample.2])
    #expect(TranslationLiteralPlan(source) == nil)
  }

  @Test(arguments: ["13-10", "3-1과 3-1"])
  func aPixelFragmentCannotGuessItsOccurrence(_ target: String) {
    var source = AttributedString("3-1")
    source.link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    let aligned = TranslationStyleMapper.align(source: source, target: target)
    #expect(aligned.hasUnmappedSourceFragments)
    #expect(aligned.target.runs.allSatisfy { $0.link == nil })
  }

  @Test
  func compatibilityMatchingCannotTakePartOfAnExpandedGrapheme() {
    var source = AttributedString("2")
    source.link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    #expect(TranslationStyleMapper.align(source: source, target: "⑫").hasUnmappedSourceFragments)
  }

  @Test(arguments: [false, true])
  func aDigitJoinedToPunctuationCannotBeAssignedToThePunctuation(_ joined: Bool) throws {
    let fixture = try fixture(finalNumber: "11", connectedComma: joined)
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image)
    let fragments = result.lines[0].styleRuns.filter { $0.sourceFragment != nil }
    if joined { #expect(fragments.isEmpty) }
    else {
      let fragment = try #require(fragments.first)
      #expect((fixture.line.text as NSString).substring(with: fragment.range) == "28 - 11")
    }
  }

  @Test
  func contextualImageMetadataCannotReplaceTheBaselineWording() {
    var source = AttributedString("Unsigned variants store 2° - 1.")
    source[source.range(of: "2° - 1")!].link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    let target = "부호가 없는 변형은 2° - 1까지 저장한다."
    let aligned = TranslationStyleMapper.alignContextual(
      source: source,
      target: target,
      response: "서명되지 않은 변형은 <s0>2° - 1</s0>까지 저장한다."
    )
    #expect(!aligned.hasUnmappedSourceFragments)
    #expect(String(aligned.target.characters) == target)
    #expect(!String(aligned.target.characters).contains("서명"))
  }

  @Test
  func contextualBoundariesDistinguishRepeatedNumericSubstrings() {
    var source = AttributedString("2' - 1")
    source.link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    let target = "-(2')부터 2'까지 저장한다."
    let aligned = TranslationStyleMapper.alignContextual(source: source, target: target, response: "-(2')부터 <s0>2'</s0>까지 저장한다.")
    #expect(!aligned.hasUnmappedSourceFragments)
    #expect(String(aligned.target.characters) == target)
    #expect(aligned.target.runs.filter { $0.link != nil }.map { String(aligned.target.characters[$0.range]) } == ["2'"])
  }

  @Test
  func nativeLiteralLinksIgnoreDetachedPunctuationButNeverReplaceProse() {
    let link = URL(string: "swiftycrow-style://run/0?source=pixels")!
    var source = AttributedString("2' - 1")
    source.link = link
    let target = "부호가 없는 값은 2'까지 저장하며, 끝난다."
    var native = AttributedString(target)
    native[native.range(of: "2'")!].link = link
    native[native.range(of: ",")!].link = link
    let aligned = TranslationStyleMapper.alignNativeStyles(
      source: source,
      target: target,
      native: native,
      preserving: nil
    )
    #expect(!aligned.hasUnmappedSourceFragments)
    #expect(String(aligned.target.characters) == target)
    #expect(aligned.target.runs.filter { $0.link == link }.map { String(aligned.target.characters[$0.range]) } == ["2'"])
    var different = AttributedString("서명되지 않은 값은 2'까지 저장한다.")
    different.link = link
    let rejected = TranslationStyleMapper.alignNativeStyles(
      source: source,
      target: target,
      native: different,
      preserving: nil
    )
    #expect(rejected.hasUnmappedSourceFragments)
    #expect(String(rejected.target.characters) == target)
  }

  @Test(arguments: ["2⁸ − 1", "2° - 1,", "28 - 1,", "-(2n - 1)", "x + 2", "-(27)", "- (2')", "2⁸"])
  func arithmeticCandidatesRetainTheirWholeRange(_ expression: String) {
    let text = "Values are \(expression) in this range."
    let ranges = OCRInlineSourceFragments.candidateRanges(in: text)
    #expect(ranges
      .map { (text as NSString).substring(with: $0) } == [String(expression.dropLast(expression.hasSuffix(",") ? 1 : 0))])
  }

  @Test(arguments: ["8-bit integer", "2026 release notes", "- 1 item", "src/file.swift", "Version 2foo - 1", "C++ language"])
  func proseAndIsolatedListMarkersAreNotArithmetic(_ text: String) {
    #expect(OCRInlineSourceFragments.candidateRanges(in: text).isEmpty)
  }

  @Test
  func automaticOwnershipKeepsSuperscriptPixelsInsteadOfFlattenedOCR() throws {
    let fixture = try fixture()
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image)
    let literal = try #require(result.lines[0].styleRuns.first { $0.sourceFragment != nil })
    let fragment = try #require(literal.sourceFragment)
    #expect((fixture.line.text as NSString).substring(with: literal.range) == "28 - 1")
    #expect(fragment.height >= 14, "The raised exponent must be part of the captured literal")
    #expect(fragment.width > 20)
    #expect(fragment.descent >= 0 && fragment.descent <= 5)
    let ink = try #require(literal.inkBox)
    let crop = try #require(fixture.image.cropping(to: CGRect(
      x: (ink.minX * 600).rounded(),
      y: (ink.minY * 100).rounded(),
      width: CGFloat(fragment.width),
      height: CGFloat(fragment.height)
    )))
    #expect(try pixels(crop) == fragment.pixels)
    let source = OverlayLine.Source(recognized: result.lines[0], language: .init(identifier: "en"))
    let attributed = try #require(source.attributedTextForTranslation())
    #expect(TranslationLiteralPlan(attributed) == nil)
    #expect(String(attributed.characters) == fixture.line.text)
    let punctuation = try #require(result.lines[0].styleRuns
      .first { (fixture.line.text as NSString).substring(with: $0.range) == "," })
    #expect(!ink.intersects(try #require(punctuation.inkBox)))
  }

  @Test
  func tightObservedGlyphBoundsStillCaptureTheCompleteFormula() throws {
    var input = try fixture()
    let range = try #require(OCRInlineSourceFragments.candidateRanges(in: input.line.text).first)
    let ink = input.line.styleRuns.filter { NSIntersectionRange($0.range, range).length > 0 }
      .compactMap(\.inkBox).reduce(CGRect.null) { $0.union($1) }
    let top = floor(ink.minY * 100) / 100
    let bottom = ceil(ink.maxY * 100) / 100
    input.line.styleRuns = input.line.styleRuns.map { source in
      var run = source
      if NSIntersectionRange(run.range, range).length > 0 {
        run.box.origin.y = top
        run.box.size.height = bottom - top
        run.inkBox = nil
      }
      return run
    }
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [input.line]), image: input.image)
    let literal = try #require(result.lines[0].styleRuns.first { $0.sourceFragment != nil })
    let fragment = try #require(literal.sourceFragment)
    let capturedInk = try #require(literal.inkBox)
    let crop = try #require(input.image.cropping(to: CGRect(
      x: (capturedInk.minX * 600).rounded(),
      y: (capturedInk.minY * 100).rounded(),
      width: CGFloat(fragment.width),
      height: CGFloat(fragment.height)
    )))
    #expect(fragment.height >= 14)
    #expect(try pixels(crop) == fragment.pixels)
  }

  @Test(arguments: ["partial", "crossing", "vertical", "textured"])
  func uncertainOwnershipCannotMoveSourcePixels(_ reason: String) throws {
    let fixture = try fixture(textured: reason == "textured")
    var line = fixture.line
    let range = (line.text as NSString).range(of: "28")
    let index = try #require(line.styleRuns.firstIndex { NSIntersectionRange($0.range, range).length > 0 })
    switch reason {
    case "partial": line.styleRuns[index].range.length = 1
    case "crossing": line.styleRuns[0].inkBox = line.styleRuns[index].inkBox
    case "vertical": line.isVerticalBlock = true
    default: break
    }
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [line]), image: fixture.image)
    #expect(result.lines[0].styleRuns.allSatisfy { $0.sourceFragment == nil })
  }

  @Test
  func anotherRecognizedOwnerCannotBeCarriedInsideTheLiteral() throws {
    let fixture = try fixture()
    let run = try #require(fixture.line.styleRuns.first { (fixture.line.text as NSString).substring(with: $0.range) == "28" })
    let other = OCRResult.Line(boundingBoxNormalized: try #require(run.inkBox), text: "note", preservesSource: true)
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line, other]), image: fixture.image)
    #expect(result.lines[0].styleRuns.allSatisfy { $0.sourceFragment == nil })
  }

  @Test(arguments: ["same-line", "other-line", "missing-range"])
  func partiallyMeasuredNeighborsStillOwnTheirPixels(_ variant: String) throws {
    let fixture = try fixture()
    var line = fixture.line
    let owned = try #require(line.styleRuns.first { (line.text as NSString).substring(with: $0.range) == "28" })
    var lines = [line]
    if variant == "other-line" {
      let other = OCRResult.Line(boundingBoxNormalized: owned.box, text: "note x", styleRuns: [
        .init(range: NSRange(location: 0, length: 4), box: .zero, inkBox: .zero),
        .init(range: NSRange(location: 5, length: 1), box: owned.box),
      ])
      lines.append(other)
    } else if variant == "same-line" {
      line.styleRuns[0].box = owned.box
      line.styleRuns[0].inkBox = nil
      lines[0] = line
    } else {
      lines[0].styleRuns.removeFirst()
    }
    let result = OCRInlineSourceFragments.applying(to: .init(lines: lines), image: fixture.image)
    #expect(result.lines[0].styleRuns.allSatisfy { $0.sourceFragment == nil })
  }

  @Test
  func restoredArtworkOwnershipIsAppliedBeforeCreatingALiteral() async throws {
    let fixture = try fixture()
    let original = OCRResult(lines: [fixture.line])
    let box = try #require(fixture.line.styleRuns.first { (fixture.line.text as NSString).substring(with: $0.range) == "28" }).box
    let result = try await OCRInlineSourceFragments.resolving(original, image: fixture.image) { input, _ in
      var restored = input
      restored.lines[0].layoutExclusions = [box]
      return restored
    }
    #expect(result.lines[0].layoutExclusions == [box])
    #expect(result.lines[0].styleRuns.allSatisfy { $0.sourceFragment == nil })
    await #expect(throws: CocoaError.self) {
      _ = try await OCRInlineSourceFragments.resolving(original, image: fixture.image) { _, _ in nil }
    }
  }

  @Test(arguments: [(true, false), (false, false), (false, true)])
  func cancellationCannotAuthorizeUnresolvedSourcePixels(_ scenario: (Bool, Bool)) async throws {
    let beforeResolution = scenario.0
    let fixture = try fixture()
    let calls = Mutex(0)
    let task = Task {
      if beforeResolution { withUnsafeCurrentTask { $0?.cancel() } }
      return try await OCRInlineSourceFragments.resolving(.init(lines: [fixture.line]), image: fixture.image) { input, _ in
        calls.withLock { $0 += 1 }
        withUnsafeCurrentTask { $0?.cancel() }
        return scenario.1 ? nil : input
      }
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(calls.withLock { $0 } == (beforeResolution ? 0 : 1))
  }

  @Test
  func measuredRaisedInkCanExtendBeyondTheNativeRangeBox() throws {
    let fixture = try fixture()
    var line = fixture.line
    let range = (line.text as NSString).range(of: "28 - 1,")
    for index in line.styleRuns.indices where NSIntersectionRange(line.styleRuns[index].range, range).length > 0 {
      line.styleRuns[index].box.origin.y = 0.25
      line.styleRuns[index].box.size.height = 0.17
    }
    let result = OCRInlineSourceFragments.applying(to: .init(lines: [line]), image: fixture.image)
    let literal = try #require(result.lines[0].styleRuns.first { $0.sourceFragment != nil })
    #expect(try #require(literal.inkBox).minY < 0.25)
    #expect(try #require(literal.sourceFragment).height >= 14)
  }

  @Test(arguments: [(1, 1.0), (2, 1.0), (2, 0.5)])
  func translatedLiteralPaintRetainsTheActualSourceSamples(_ sample: (Int, Double)) throws {
    let scale = sample.0
    let pixelRatio = Int(Double(scale) * sample.1)
    let fixture = try fixture()
    let recognized = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image).lines[0]
    let index = try #require(recognized.styleRuns.firstIndex { $0.sourceFragment != nil })
    let fragment = try #require(recognized.styleRuns[index].sourceFragment)
    let text = (recognized.text as NSString).substring(with: recognized.styleRuns[index].range)
    var target = AttributedString(text)
    target.link = URL(string: "swiftycrow-style://run/\(index)")!
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation(text, attributedText: target, language: .init(identifier: "ko"))
    let frame = CGRect(x: 0, y: 0, width: 100, height: 60)
    let placement = OverlayPlacement(
      line: line,
      flow: .horizontal(.leftToRight),
      sourceFrame: frame,
      frame: frame,
      placementBounds: frame,
      fontSize: fragment.referenceFontSize * sample.1,
      lineHeightMultiple: 1,
      alignment: .leading
    )
    let rendered = try #require(HorizontalTextRenderer.image(for: placement, scale: CGFloat(scale)))
    let rgba = try pixels(rendered)
    let occupied = stride(from: 3, to: rgba.count, by: 4).filter { rgba[$0] > 0 }.map { $0 / 4 }
    let x0 = try #require(occupied.map { $0 % rendered.width }.min())
    let y0 = try #require(occupied.map { $0 / rendered.width }.min())
    #expect(occupied.count == fragment.width * fragment.height * pixelRatio * pixelRatio)
    var expected = Data()
    for y in 0..<(fragment.height * pixelRatio) { for x in 0..<(fragment.width * pixelRatio) {
      let offset = ((y / pixelRatio) * fragment.width + x / pixelRatio) * 4
      expected.append(fragment.pixels[offset..<offset + 4])
    } }
    let actual = try #require(rendered.cropping(to: CGRect(
      x: x0,
      y: y0,
      width: fragment.width * pixelRatio,
      height: fragment.height * pixelRatio
    )))
    #expect(try pixels(actual) == expected)
  }

  @Test
  func changedRunIndexesInvalidateAnInflightTranslation() throws {
    let fixture = try fixture()
    var recognized = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image).lines[0]
    let old = OverlayLine.Source(recognized: recognized, language: .init(identifier: "en"))
    recognized.styleRuns.insert(
      .init(range: NSRange(location: 0, length: 0), box: .zero, appearance: recognized.appearance),
      at: 0
    )
    let current = OverlayLine.Source(recognized: recognized, language: .init(identifier: "en"))
    #expect(TranslationLiteralPlan(old.attributedTextForTranslation())?
      .requestText == TranslationLiteralPlan(current.attributedTextForTranslation())?.requestText)
    #expect(!current.canReuseTranslation(relativeTo: old, imageSize: CGSize(width: 600, height: 100)))
  }

  @Test
  func literalPixelWidthDeterminesTheFontInsteadOfTheFlattenedToken() throws {
    let fragment = try #require(OverlayInlineSourceFragment(
      pixels: Data(repeating: 255, count: 30 * 14 * 4),
      width: 30,
      height: 14,
      descent: 2,
      referenceFontSize: 13
    ))
    var source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.3), text: "x", styleRuns: [.init(
        range: NSRange(location: 0, length: 1),
        box: .zero,
        sourceFragment: fragment
      )]),
      language: .init(identifier: "en")
    )
    source.appearance.fontSizeScale = 0.13
    var line = OverlayLine(id: UUID(), source: source)
    let text = "123456789098765432123456789098765432"
    var target = AttributedString(text)
    target.link = URL(string: "swiftycrow-style://run/0")!
    line.showTranslation(text, attributedText: target, language: .init(identifier: "en"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 100, height: 100)).first)
    #expect(abs(placement.fontSize - 13) < 0.001)
  }

  @MainActor @Test
  func unplaceablePlaceholderKeepsTheOriginalCapture() throws {
    let fragment = try #require(OverlayInlineSourceFragment(
      pixels: Data(repeating: 255, count: 1000 * 24 * 4),
      width: 1000,
      height: 24,
      descent: 4,
      referenceFontSize: 13
    ))
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
      text: "original",
      styleRuns: [.init(range: NSRange(location: 0, length: 8), box: .zero, sourceFragment: fragment)]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
    var target = AttributedString("different")
    target.link = URL(string: "swiftycrow-style://run/0")!
    line.showTranslation("different", attributedText: target, language: .init(identifier: "en"))
    let size = CGSize(width: 100, height: 100)
    let placements = OverlayLayoutEngine.placements(for: [line], in: size)
    #expect(placements.isEmpty)
    #expect(!OverlayLayoutEngine.protectedSourceFrames(for: [line], placements: placements, in: size, displayScale: 1).isEmpty)
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.6, green: 0.2, blue: 0.4, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let data = try #require(context.makeImage()?.pngData)
    let original = try #require(CaptureResultImage.render(imageData: data, imageSize: size, lines: []))
    let rendered = try #require(CaptureResultImage.render(imageData: data, imageSize: size, lines: [line]))
    #expect(try pixels(original) == pixels(rendered))
  }

  @Test(arguments: ["en", "ko", "ar"], [1.0, 2.0])
  func rendererUsesOneObjectAndIncludesItsEntirePaint(_ language: String, _ scale: Double) throws {
    let fragment = try #require(OverlayInlineSourceFragment(
      pixels: Data(repeating: 255, count: 48 * 24 * 4),
      width: 48,
      height: 24,
      descent: 4,
      referenceFontSize: 13
    ))
    let style = OverlayTextStyleRun(range: NSRange(location: 0, length: 6), appearance: .fallback, sourceFragment: fragment)
    let plan = HorizontalTextRenderer.plan(
      text: "28 - 1",
      language: .init(identifier: language),
      fontSize: 13,
      appearance: .fallback,
      styles: [style],
      width: 100,
      lineHeightMultiple: 1
    )
    #expect(plan.complete)
    #expect(plan.lines.count == 1)
    #expect(CTLineGetStringRange(try #require(plan.lines.first)).length == 1)
    #expect(abs(plan.inkBounds.width - 48) < 0.01)
    #expect(abs(plan.inkBounds.height - 24) < 0.01)
    #expect(!plan.fits(CGSize(width: 100, height: 20)))
    let narrow = HorizontalTextRenderer.plan(
      text: "28 - 1",
      language: .init(identifier: language),
      fontSize: 13,
      appearance: .fallback,
      styles: [style],
      width: 40,
      lineHeightMultiple: 1
    )
    #expect(!narrow.fits(CGSize(width: 40, height: 100)))
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "28 - 1",
      styleRuns: [.init(range: style.range, box: CGRect(x: 0, y: 0, width: 1, height: 1), sourceFragment: fragment)]
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    let attributed = try #require(line.source.attributedTextForTranslation())
    line.showTranslation("28 - 1", attributedText: attributed, language: .init(identifier: language))
    let frame = CGRect(x: 0, y: 0, width: 100, height: 50)
    let placement = OverlayPlacement(
      line: line,
      flow: .horizontal(language == "ar" ? .rightToLeft : .leftToRight),
      sourceFrame: frame,
      frame: frame,
      placementBounds: frame,
      fontSize: 13,
      lineHeightMultiple: 1,
      alignment: .leading
    )
    let image = try #require(HorizontalTextRenderer.image(for: placement, scale: scale))
    let raster = try pixels(image)
    let opaque = stride(from: 3, to: raster.count, by: 4).count { raster[$0] == 255 }
    #expect(opaque == 48 * 24 * Int(scale * scale))
  }

  @Test
  func invalidRangesCannotProduceAPartialSuccessfulPlan() throws {
    let fragment = try #require(OverlayInlineSourceFragment(
      pixels: Data(repeating: 255, count: 16),
      width: 2,
      height: 2,
      descent: 0,
      referenceFontSize: 13
    ))
    let plan = HorizontalTextRenderer.plan(
      text: "hello",
      language: .init(identifier: "en"),
      fontSize: 13,
      appearance: .fallback,
      styles: [.init(range: NSRange(location: 2, length: 10), appearance: .fallback, sourceFragment: fragment)],
      width: 100,
      lineHeightMultiple: 1
    )
    #expect(!plan.complete)
    #expect(!plan.fits(CGSize(width: 100, height: 100)))
  }

  @Test
  func missingTargetOwnershipCannotEraseASourceFormula() throws {
    let fixture = try fixture()
    let recognized = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image).lines[0]
    #expect(recognized.styleRuns.contains { $0.sourceFragment != nil })
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    line.showTranslation("번역된 값은 28 - 1입니다.", language: .init(identifier: "ko"))
    #expect(!line.shouldReplaceSourcePixels)
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 600, height: 100)).isEmpty)
  }

  @Test
  func liveStyleStabilizationRetainsTheCurrentCapturedLiteral() throws {
    let fixture = try fixture()
    let line = OCRInlineSourceFragments.applying(to: .init(lines: [fixture.line]), image: fixture.image).lines[0]
    let old = OverlayLine.Source(recognized: line, language: .init(identifier: "en"))
    var current = old
    let index = try #require(current.styleRuns.firstIndex { $0.sourceFragment != nil })
    let previous = try #require(current.styleRuns[index].sourceFragment)
    var bytes = previous.pixels
    bytes[0] ^= 1
    current.styleRuns[index].sourceFragment = OverlayInlineSourceFragment(
      pixels: bytes,
      width: previous.width,
      height: previous.height,
      descent: previous.descent,
      referenceFontSize: previous.referenceFontSize
    )
    let stabilized = current.stabilized(relativeTo: old, imageSize: CGSize(width: 600, height: 100))
    #expect(stabilized.styleRuns[index].sourceFragment?.pixels == bytes)
    #expect(stabilized.styleRuns[index].sourceFragment != previous)
  }

  // MARK: Private

  private func fixture(
    textured: Bool = false,
    finalNumber: String = "1",
    connectedComma: Bool = false
  ) throws -> (line: OCRResult.Line, image: CGImage) {
    let text = "Values range from 28 - \(finalNumber), and other values stay here."
    let appearance = OverlaySourceAppearance(
      background: .init(red: 1, green: 1, blue: 1, alpha: 1),
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.13,
      fontWeight: .regular
    )
    let attributed = NSMutableAttributedString(
      string: text,
      attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.black]
    )
    let exponent = (text as NSString).range(of: "8")
    attributed.addAttributes([.font: NSFont.systemFont(ofSize: 9), .baselineOffset: 5], range: exponent)
    let native = CTLineCreateWithAttributedString(attributed)
    let context = try #require(CGContext(
      data: nil,
      width: 600,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 2400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(NSColor.white.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 600, height: 100))
    if textured {
      context.setFillColor(NSColor.black.cgColor)
      context.fill(CGRect(x: 0, y: 87, width: 600, height: 1))
    }
    context.textPosition = CGPoint(x: 10, y: 70)
    CTLineDraw(native, context)
    if connectedComma {
      let commaIndex = (text as NSString).range(of: ",").location
      let digit = 10 + CTLineGetOffsetForStringIndex(native, commaIndex - 1, nil)
      let comma = 10 + CTLineGetOffsetForStringIndex(native, commaIndex, nil)
      context.setFillColor(NSColor.black.cgColor)
      context.fill(CGRect(x: digit + 2, y: 70, width: comma - digit + 1, height: 1))
    }
    let regex = try NSRegularExpression(pattern: #"\S+"#)
    let runs = regex.matches(in: text, range: NSRange(text.startIndex..<text.endIndex, in: text))
      .map { match -> OverlaySourceStyleRun in
        let start = CTLineGetOffsetForStringIndex(native, match.range.location, nil)
        let end = CTLineGetOffsetForStringIndex(native, NSMaxRange(match.range), nil)
        let ink = CTLineGetBoundsWithOptions(
          CTLineCreateWithAttributedString(attributed.attributedSubstring(from: match.range)),
          [.useGlyphPathBounds]
        )
        return .init(
          range: match.range,
          box: CGRect(x: (10 + start) / 600, y: 0.12, width: (end - start) / 600, height: 0.3),
          appearance: appearance,
          inkBox: CGRect(
            x: (10 + start + ink.minX) / 600,
            y: (30 - ink.maxY) / 100,
            width: ink.width / 600,
            height: ink.height / 100
          )
        )
      }
    return (
      .init(
        boundingBoxNormalized: CGRect(x: 0, y: 0.12, width: 0.8, height: 0.3),
        text: text,
        imageAspectRatio: 6,
        appearance: appearance,
        styleRuns: runs
      ),
      try #require(context.makeImage())
    )
  }

  private func pixels(_ image: CGImage) throws -> Data {
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
    return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
  }
}
