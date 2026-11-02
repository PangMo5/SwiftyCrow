// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Attributed overlay styles")
struct OverlayAttributedStyleTests {

  // MARK: Internal

  @Test(arguments: [
    "Open report.pdf and budget.xlsx to review.",
    "資料.pdfを開いてください。",
    "افتح report.pdf الآن.",
    "Review report.v2.pdf.",
  ])
  func `inline file ownership does not depend on font style`(_ text: String) throws {
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text),
      language: .init(identifier: "en"),
    )
    let attributed = try #require(source.attributedTextForTranslation())
    let literals = attributed.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
      .map { String(attributed.characters[$0.range]) }
    #expect(literals == OCRTextSemantics.fileNameRanges(in: text).map { String(text[$0]) })
    let plan = try #require(TranslationLiteralPlan(attributed))
    #expect(String(try #require(plan.restoring(plan.requestText)).characters) == text)
    #expect(!source.isProtectedLiteral)
  }

  @Test
  func `native style ownership maps inflection without changing primary text`() throws {
    let link = try #require(URL(string: "swiftycrow-style://run/0"))
    var source = AttributedString("Signed")
    source.link = link
    source.inlinePresentationIntent = .emphasized
    source += AttributedString(" numbers may be negative.")
    let target = "부호가 있는 숫자는 음수일 수 있습니다."
    var native = AttributedString(target)
    native[try #require(native.range(of: "부호가 있는"))].link = link
    let result = TranslationStyleMapper.alignNativeStyles(source: source, target: target, native: native, preserving: nil)
    #expect(result.unmatched.isEmpty)
    #expect(String(result.target.characters) == target)
    #expect(result.target.runs.filter { $0.link == link }.map { String(result.target.characters[$0.range]) } == ["부호가 있는"])
    let different = AttributedString("서명된 숫자는 음수일 수 있습니다.")
    #expect(!TranslationStyleMapper.alignNativeStyles(
      source: source,
      target: target,
      native: different,
      preserving: nil,
    ).unmatched.isEmpty)
  }

  @Test(arguments: [": artificial", "artificial:", "(artificial)", "[artificial]"])
  func `punctuation cannot override neighboring lexical weight`(_ text: String) throws {
    let base = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    var word = base
    word.fontWeight = .semibold
    var punctuation = base
    punctuation.fontWeight = .bold
    let wordRange = (text as NSString).range(of: "artificial")
    let length = (text as NSString).length
    let ranges = [
      NSRange(location: 0, length: wordRange.location),
      wordRange,
      NSRange(location: NSMaxRange(wordRange), length: length - NSMaxRange(wordRange)),
    ].filter { $0.length > 0 }
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1),
      text: text,
      appearance: base,
      styleRuns: ranges.map { range in
        .init(
          range: range,
          box: CGRect(
            x: Double(range.location) / Double(length),
            y: 0.2,
            width: Double(range.length) / Double(length),
            height: 0.1,
          ),
          appearance: range == wordRange ? word : punctuation,
        )
      },
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    let source = try #require(line.source.attributedTextForTranslation())
    let wordRun = try #require(source.runs.first { String(source.characters[$0.range]).contains("artificial") })
    #expect(String(source.characters[wordRun.range]) == "artificial")
    var target = AttributedString("인공")
    target.link = wordRun.link
    line.showTranslation("인공", attributedText: target, language: .init(identifier: "ko"))
    #expect(try #require(line.displayedStyleRuns.first).appearance.fontWeight == .semibold)
  }

  @Test(arguments: [
    ("백채널 (언어학)", "위키피디아의 백채널(언어학)", "백채널(언어학)"),
    ("Alpha(Beta)", "Alpha ( Beta ) value", "Alpha ( Beta )"),
    ("Alpha  (Beta)", "Alpha(Beta)", "Alpha(Beta)"),
  ])
  func `ordinary style alignment allows bracket spacing`(_ sample: (String, String, String)) throws {
    let link = try #require(URL(string: "swiftycrow-style://run/0"))
    var source = AttributedString("Source phrase")
    source.link = link
    let result = TranslationStyleMapper.align(source: source, target: sample.1, alternatives: [link: sample.0])
    #expect(result.unmatched.isEmpty)
    #expect(String(result.target.characters) == sample.1)
    #expect(result.target.runs.filter { $0.link != nil }.map { String(result.target.characters[$0.range]) } == [sample.2])
  }

  @Test(arguments: [("the rapist (term)", "therapist(term)"), ("Alpha (Beta)", "Alpha\n(Beta)")])
  func `bracket spacing cannot join words or paragraphs`(_ sample: (String, String)) throws {
    var source = AttributedString(sample.0)
    source.link = try #require(URL(string: "swiftycrow-style://run/0"))
    #expect(TranslationStyleMapper.align(source: source, target: sample.1).unmatched.count == 1)
  }

  @Test
  func `literal styles still require exact bracket spacing`() throws {
    var source = AttributedString("a (b)")
    source.link = try #require(URL(string: "swiftycrow-style://run/0"))
    source.inlinePresentationIntent = .code
    #expect(TranslationStyleMapper.align(source: source, target: "a(b)").unmatched.count == 1)
  }

  @Test
  func `restoration and translation completion order produces the same final styles`() throws {
    let originalAppearance = OverlaySourceAppearance(
      background: .init(red: 0.8, green: 0.7, blue: 0.6, alpha: 1),
      foreground: .black,
      confidence: 1,
      fontWeight: .bold,
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Caption",
      appearance: .fallback,
      styleRuns: [.init(
        range: NSRange(location: 0, length: 7),
        box: CGRect(x: 0, y: 0, width: 1, height: 1),
        appearance: originalAppearance,
      )],
    )
    let source = OverlayLine.Source(recognized: recognized, language: .init(identifier: "en"))
    var restored = source
    restored.styleRuns[0].appearance.background = .white
    var attributed = AttributedString("캡션")
    attributed.link = try #require(URL(string: "swiftycrow-style://run/0"))
    var translationFirst = OverlayLine(id: UUID(), source: source)
    translationFirst.showTranslation("캡션", attributedText: attributed, language: .init(identifier: "ko"))
    translationFirst.source = restored
    var restorationFirst = OverlayLine(id: UUID(), source: restored)
    restorationFirst.showTranslation("캡션", attributedText: attributed, language: .init(identifier: "ko"))
    #expect(translationFirst.displayedStyleRuns == restorationFirst.displayedStyleRuns)
    #expect(try #require(translationFirst.displayedStyleRuns.first).appearance.background == .white)
    #expect(translationFirst.translatedText == "캡션")
  }

  @Test
  func `refreshed styles follow semantic ranges instead of run storage order`() throws {
    let first = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    var second = first
    second.fontWeight = .bold
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Red Blue",
      appearance: first,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 3), box: CGRect(x: 0, y: 0, width: 0.4, height: 1), appearance: first),
        .init(range: NSRange(location: 4, length: 4), box: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), appearance: second),
      ],
    )
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
    var target = AttributedString("빨강 파랑")
    target[try #require(target.range(of: "빨강"))].link = try #require(URL(string: "swiftycrow-style://run/0"))
    target[try #require(target.range(of: "파랑"))].link = try #require(URL(string: "swiftycrow-style://run/1"))
    line.showTranslation("빨강 파랑", attributedText: target, language: .init(identifier: "ko"))
    line.source.styleRuns.reverse()
    line.source.styleRuns[0].appearance.isUnderlined = true
    let runs = line.displayedStyleRuns
    #expect(try #require(runs.first(where: { $0.range.location == 0 })).appearance == first)
    #expect(try #require(runs.first(where: { $0.range.location == 3 })).appearance.isUnderlined)
  }

  @Test
  func `one broken context marker does not drop independent valid spans`() throws {
    var source = AttributedString("Alpha Beta")
    let first = try #require(URL(string: "swiftycrow-style://run/0"))
    let second = try #require(URL(string: "swiftycrow-style://run/1"))
    source[try #require(source.range(of: "Alpha"))].link = first
    source[try #require(source.range(of: "Beta"))].link = second
    let result = TranslationStyleMapper.alignContextual(
      source: source,
      target: "알파 베타",
      response: "<s0>알파 <s1>베타</s1>",
    )
    #expect(result.target.runs.contains { $0.link == second })
    #expect(result.unmatched.map(\.link) == [first])
    #expect(String(result.target.characters) == "알파 베타")
  }

  @Test
  func `a wrapped colored word does not split because one glyph looks heavier`() throws {
    let blue = OverlayColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    let regular = OverlaySourceAppearance(background: .white, foreground: blue, confidence: 1, fontWeight: .regular)
    var heavy = regular
    heavy.fontWeight = .bold
    let text = "解决问题"
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.1),
      text: text,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: .regular),
      styleRuns: [
        .init(
          range: NSRange(location: 0, length: 3),
          box: CGRect(x: 0.6, y: 0.1, width: 0.09, height: 0.03),
          appearance: regular,
        ),
        .init(
          range: NSRange(location: 3, length: 1),
          box: CGRect(x: 0.1, y: 0.15, width: 0.03, height: 0.03),
          appearance: heavy,
        ),
      ],
    )
    let attributed = try #require(OverlayLine.Source(recognized: line, language: .init(identifier: "zh-Hans"))
      .attributedTextForTranslation())
    #expect(attributed.runs.count(where: { $0.link != nil }) == 1)
  }

  @Test
  func `contextual refinement cannot discard already aligned lexical styles`() throws {
    var source = AttributedString("Lernen und KI")
    let first = try #require(URL(string: "swiftycrow-style://run/0"))
    let second = try #require(URL(string: "swiftycrow-style://run/1"))
    source[try #require(source.range(of: "Lernen"))].link = first
    source[try #require(source.range(of: "KI"))].link = second
    #expect(TranslationStyleMapper.contextualRequest(source: source, links: [second]) == "Lernen und <s1>KI</s1>")
    let aligned = TranslationStyleMapper.alignContextual(
      source: source,
      target: "학습과 인공지능",
      response: "유효하지 않은 전혀 다른 <s1>표현</s1>",
      alternatives: [first: "학습"],
    )
    let retained = try #require(aligned.target.runs.first { $0.link == first })
    #expect(String(aligned.target.characters[retained.range]) == "학습")
    #expect(aligned.unmatched.map(\.link) == [second])
  }

  @Test
  func `contextual alignment retains inflected style without replacing plain wording`() throws {
    var source = AttributedString("人工智能包括学习和推理。")
    let link = try #require(URL(string: "swiftycrow-style://run/0"))
    source[try #require(source.range(of: "推理"))].link = link
    #expect(TranslationStyleMapper.contextualRequest(source: source) == "人工智能包括学习和<s0>推理</s0>。")
    let target = "인공지능에는 학습과 추론이 포함됩니다."
    let alignment = TranslationStyleMapper.alignContextual(
      source: source,
      target: target,
      response: "인공지능에는 학습과 <s0>추리</s0>가 포함됩니다.",
    )
    #expect(String(alignment.target.characters) == target)
    let styled = try #require(alignment.target.runs.first { $0.link == link })
    #expect(String(alignment.target.characters[styled.range]) == "추론이")
    #expect(alignment.unmatched.isEmpty)
  }

  @Test(arguments: [
    "<s0>설정",
    "<s9>설정</s9>",
    "<s0>설정</s1>",
    "<s0>설정</s0><s0>다시</s0>",
    "전혀 다른 문장에 <s0>뜻밖의 표현</s0>이 들어 있습니다.",
  ])
  func `invalid or unrelated context cannot assign A style`(_ response: String) throws {
    var source = AttributedString("Choose settings")
    source[try #require(source.range(of: "settings"))].link = try #require(URL(string: "swiftycrow-style://run/0"))
    let alignment = TranslationStyleMapper.alignContextual(source: source, target: "환경설정을 선택하세요.", response: response)
    #expect(String(alignment.target.characters) == "환경설정을 선택하세요.")
    #expect(alignment.target.runs.allSatisfy { $0.link == nil })
  }

  @Test
  func `apple aligned attributes map source styles onto translated words`() throws {
    let sourceText = "Proposal #179. Agent Skills handles reusable capabilities."
    let issueAppearance = OverlaySourceAppearance(
      background: .black,
      foreground: OverlayColor(red: 0.55, green: 0.58, blue: 0.63, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
    )
    let linkAppearance = OverlaySourceAppearance(
      background: .black,
      foreground: OverlayColor(red: 0.18, green: 0.52, blue: 0.95, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .medium,
      isUnderlined: true,
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1),
      text: sourceText,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "#179", in: sourceText),
          box: CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.1),
          appearance: issueAppearance,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "Agent Skills", in: sourceText),
          box: CGRect(x: 0.35, y: 0.2, width: 0.18, height: 0.1),
          appearance: linkAppearance,
        ),
      ],
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US"),
      ),
      initialContent: .pending,
    )

    let request = try #require(line.source.attributedTextForTranslation())
    #expect(request.runs.compactMap(\.link).count == 2)

    let targetText = "제안 #179에 관한 내용입니다. 에이전트 스킬은 재사용할 수 있습니다."
    var target = AttributedString(targetText)
    try tag("#179에", with: "swiftycrow-style://run/0", in: &target)
    try tag("에이전트 스킬은", with: "swiftycrow-style://run/1", in: &target)
    line.showTranslation(
      targetText,
      attributedText: target,
      language: Locale.Language(identifier: "ko-KR"),
    )

    let runs = line.displayedStyleRuns
    #expect(runs.count == 2)
    #expect((targetText as NSString).substring(with: runs[0].range) == "#179에")
    #expect(runs[0].appearance.foreground == issueAppearance.foreground)
    #expect((targetText as NSString).substring(with: runs[1].range) == "에이전트 스킬은")
    #expect(runs[1].appearance.foreground == linkAppearance.foreground)
    #expect(runs[1].appearance.isUnderlined)
  }

  @Test
  func `literal style mapper aligns technical tokens without retranslating the line`() throws {
    var source = AttributedString("Proposal #179. Agent Skills handles reusable capabilities.")
    try tag("#179", with: "swiftycrow-style://run/0", in: &source)
    try tag("Agent Skills", with: "swiftycrow-style://run/1", in: &source)

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "제안 #179에 관한 내용입니다. Agent Skills는 재사용할 수 있습니다.",
    )

    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link).count == 2)
  }

  @Test
  func `adjacent code fragments move as whole visual tokens`() throws {
    let sourceText = "Runs on macOS 26 with build 2.10.0. Done."
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.42, green: 0.44, blue: 0.48, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
    )
    let code = OverlaySourceAppearance(
      background: OverlayColor(red: 0.91, green: 0.93, blue: 0.96, alpha: 1),
      foreground: OverlayColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
      fontDesign: .monospaced,
    )
    // The final period is intentionally given the chip appearance to model
    // Vision sampling bleed at the edge of `<code>2.10.0</code>.`.
    let fragments = ["macOS", "26", "2", "10", "0", "."]
    var cursor = 0
    let styleRuns = fragments.compactMap { fragment -> OverlaySourceStyleRun? in
      let searchRange = NSRange(location: cursor, length: (sourceText as NSString).length - cursor)
      let range = (sourceText as NSString).range(of: fragment, range: searchRange)
      guard range.location != NSNotFound else { return nil }
      cursor = NSMaxRange(range)
      return OverlaySourceStyleRun(range: range, box: .zero, appearance: code)
    }
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.1),
      text: sourceText,
      appearance: base,
      styleRuns: styleRuns,
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US"),
      ),
      initialContent: .pending,
    )

    let attributedSource = try #require(line.source.attributedTextForTranslation())
    let sourceSpans: [String] = attributedSource.runs.compactMap { run in
      guard run.link != nil else { return nil }
      return String(attributedSource.characters[run.range])
    }
    #expect(sourceSpans == ["macOS 26", "2.10.0"])

    let target = "빌드 2.10.0으로 macOS 26에서 실행됩니다."
    let alignment = TranslationStyleMapper.align(source: attributedSource, target: target)
    #expect(alignment.unmatched.isEmpty)
    line.showTranslation(
      target,
      attributedText: alignment.target,
      language: Locale.Language(identifier: "ko-KR"),
    )
    let targetSpans = line.displayedStyleRuns.map {
      (target as NSString).substring(with: $0.range)
    }
    #expect(targetSpans == ["2.10.0", "macOS 26"])
  }

  @Test
  func `style spans never coalesce across A recovered hard break`() throws {
    let sourceText = "Two checks are pending.\nThe orange surface remains visible."
    let base = OverlaySourceAppearance(
      background: OverlayColor(red: 1, green: 0.94, blue: 0.84, alpha: 1),
      foreground: OverlayColor(red: 0.65, green: 0.40, blue: 0.02, alpha: 1),
      confidence: 1,
      foregroundConfidence: 0.2,
      fontWeight: .regular,
    )
    var emphasized = base
    emphasized.fontWeight = .bold
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.1),
      text: sourceText,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "Two checks are pending.", in: sourceText),
          box: CGRect(x: 0.1, y: 0.2, width: 0.25, height: 0.04),
          appearance: emphasized,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "The", in: sourceText),
          box: CGRect(x: 0.1, y: 0.25, width: 0.04, height: 0.04),
          appearance: emphasized,
        ),
      ],
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US"),
    )

    let attributed = try #require(source.attributedTextForTranslation())
    let spans = attributed.runs.compactMap { run in
      run.link.map { _ in String(attributed.characters[run.range]) }
    }

    #expect(spans == ["Two checks are pending.", "The"])
  }

  @Test(arguments: [false, true])
  func `leading emphasis uses the trailing body as its base style`(_ colored: Bool) throws {
    let text = "Apple Translation supplies the"
    let regular = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
    )
    var medium = regular
    medium.fontWeight = .medium
    var semibold = regular
    semibold.fontWeight = .semibold
    if colored {
      let blue = OverlayColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
      medium.foreground = blue
      semibold.foreground = blue
    }
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08),
      text: text,
      appearance: colored ? semibold : medium,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "Apple", in: text),
          box: CGRect(x: 0.1, y: 0.2, width: 0.12, height: 0.08),
          appearance: semibold,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "Translation", in: text),
          box: CGRect(x: 0.23, y: 0.2, width: 0.24, height: 0.08),
          appearance: medium,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "supplies", in: text),
          box: CGRect(x: 0.48, y: 0.2, width: 0.18, height: 0.08),
          appearance: regular,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "the", in: text),
          box: CGRect(x: 0.67, y: 0.2, width: 0.08, height: 0.08),
          appearance: regular,
        ),
      ],
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US"),
    )

    let attributed = try #require(source.attributedTextForTranslation())
    let spans = attributed.runs.compactMap { run in
      run.link.map { _ in String(attributed.characters[run.range]) }
    }

    #expect(source.appearance.fontWeight == .regular)
    #expect(source.appearance.foreground == regular.foreground)
    #expect(spans == ["Apple Translation"])
  }

  @Test
  func `link words coalesce across underline sampling jitter`() throws {
    let text = "Open the translation report, compare"
    let base = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .medium,
    )
    let blue = OverlayColor(red: 0.30, green: 0.57, blue: 1, alpha: 1)
    var firstWord = base
    firstWord.foreground = blue
    firstWord.fontWeight = .bold
    firstWord.isUnderlined = true
    var secondWord = firstWord
    secondWord.fontWeight = .semibold
    secondWord.isUnderlined = false
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08),
      text: text,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "translation", in: text),
          box: CGRect(x: 0.28, y: 0.2, width: 0.24, height: 0.08),
          appearance: firstWord,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "report", in: text),
          box: CGRect(x: 0.53, y: 0.2, width: 0.14, height: 0.08),
          appearance: secondWord,
        ),
      ],
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US"),
    )
    let attributed = try #require(source.attributedTextForTranslation())
    let linkedRuns = attributed.runs.filter { $0.link != nil }
    let linked = try #require(linkedRuns.first)
    let link = try #require(linked.link)

    #expect(linkedRuns.count == 1)
    #expect(String(attributed.characters[linked.range]) == "translation report")

    let alignment = TranslationStyleMapper.align(
      source: attributed,
      target: "번역 보고서를 열고 비교합니다.",
      alternatives: [link: "번역 보고서"],
    )
    let targetRuns = alignment.target.runs.filter { $0.link != nil }
    let targetRun = try #require(targetRuns.first)
    #expect(targetRuns.count == 1)
    #expect(String(alignment.target.characters[targetRun.range]) == "번역 보고서")
  }

  @Test
  func `style mapper uses short translated alternative when literal changes`() throws {
    var source = AttributedString("rameshsunkara opened this issue")
    let link = try #require(URL(string: "swiftycrow-style://run/0"))
    let range = try #require(source.range(of: "rameshsunkara"))
    source[range].link = link

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "라마쉬순카라가 이 이슈를 열었습니다.",
      alternatives: [link: "라마쉬순카라"],
    )

    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link) == [link])
  }

  @Test
  func `inline code prefers exact spelling over A capitalized product name`() throws {
    var source = AttributedString("Quartz includes the quartz command.")
    let link = try #require(URL(string: "swiftycrow-style://run/1"))
    let range = try #require(source.range(of: "quartz"))
    source[range].link = link
    let alignment = TranslationStyleMapper.align(source: source, target: "Quartz: quartz 명령을 포함합니다.")
    let styled = try #require(alignment.target.runs.first { $0.link == link })
    #expect(String(alignment.target.characters[styled.range]) == "quartz")
    source[range].inlinePresentationIntent = .code
    let missing = TranslationStyleMapper.align(source: source, target: "Quartz는 명령을 포함합니다.")
    #expect(missing.unmatched.count == 1)
    #expect(missing.target.runs.allSatisfy { $0.link == nil })
  }

  @Test
  func `colored enclosing punctuation keeps its foreground`() throws {
    let sourceText = "（旧石器）"
    let base = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .semibold,
    )
    let orange = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.25, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.08),
      text: sourceText,
      appearance: base,
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "（", in: sourceText),
          box: CGRect(x: 0.2, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange,
        ),
        OverlaySourceStyleRun(
          range: try range(of: "）", in: sourceText),
          box: CGRect(x: 0.76, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange,
        ),
      ],
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "ja-JP"),
    )
    let attributed = try #require(source.attributedTextForTranslation())
    let alignment = TranslationStyleMapper.align(source: attributed, target: "(구석기)")

    #expect(attributed.runs.compactMap(\.link).count == 2)
    #expect(alignment.unmatched.isEmpty)
    #expect(alignment.target.runs.compactMap(\.link).count == 2)
  }

  @Test
  func `one recognized bracket mirrors its style to the translated pair`() throws {
    let sourceText = "旧石器）"
    let orange = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.25, alpha: 1),
      confidence: 1,
      foregroundConfidence: 1,
      fontWeight: .regular,
    )
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.08),
      text: sourceText,
      appearance: OverlaySourceAppearance(
        background: .white,
        foreground: .black,
        confidence: 1,
        foregroundConfidence: 1,
        fontWeight: .semibold,
      ),
      styleRuns: [
        OverlaySourceStyleRun(
          range: try range(of: "）", in: sourceText),
          box: CGRect(x: 0.76, y: 0.1, width: 0.04, height: 0.08),
          appearance: orange,
        )
      ],
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP"),
      ),
      initialContent: .pending,
    )
    let source = try #require(line.source.attributedTextForTranslation())
    let alignment = TranslationStyleMapper.align(source: source, target: "(구석기)")
    line.showTranslation(
      "(구석기)",
      attributedText: alignment.target,
      language: Locale.Language(identifier: "ko-KR"),
    )

    #expect(line.displayedStyleRuns.count == 2)
    #expect(line.displayedStyleRuns.allSatisfy { $0.appearance.foreground == orange.foreground })
  }

  @Test
  func `monospaced code only line keeps original pixels`() {
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontDesign = .monospaced
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.05),
      text: ".github/instructions/*.instructions.md",
      appearance: appearance,
    )
    let source = OverlayLine.Source(
      recognized: recognized,
      language: Locale.Language(identifier: "en-US"),
    )
    var spacedRecognition = recognized
    spacedRecognition.text = ". github/instructions/*.instructions.md"
    let spaced = OverlayLine.Source(
      recognized: spacedRecognition,
      language: Locale.Language(identifier: "en-US"),
    )

    #expect(source.isProtectedLiteral)
    #expect(spaced.isProtectedLiteral)
  }

  @Test
  func `fixed pitch value does not freeze row labels or distant navigation`() {
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontDesign = .monospaced
    let navigation = source(text: "Numeric Operations", box: CGRect(x: 0.08, y: 0.56, width: 0.12, height: 0.02))
    let label = source(text: "Architecture-dependent", box: CGRect(x: 0.46, y: 0.56, width: 0.15, height: 0.02))
    let token = source(text: "isize", box: CGRect(x: 0.65, y: 0.56, width: 0.04, height: 0.02), appearance: appearance)
    let values = [navigation, label, token]
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: values))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 1, in: values))
    #expect(OverlayTranslationPolicy.preservesSource(at: 2, in: values))
    let code = source(text: ".config/tool", box: CGRect(x: 0.65, y: 0.56, width: 0.15, height: 0.02), appearance: appearance)
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: [navigation, code]))
  }

  @Test
  func `a protected numeric cell does not freeze its natural language row label`() {
    let label = source(text: "16-bit", box: CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.03))
    var number = source(text: "116", box: CGRect(x: 0.32, y: 0.4, width: 0.04, height: 0.03))
    number.preservesSource = true
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: [label, number]))
    #expect(OverlayTranslationPolicy.preservesSource(at: 1, in: [label, number]))
  }

  @Test
  func `metadata gaps use physical geometry in A wide capture`() {
    var codeAppearance = OverlaySourceAppearance.fallback
    codeAppearance.fontDesign = .monospaced
    var label = source(text: "GitHub Copilot", box: CGRect(x: 0.05, y: 0.4, width: 0.15, height: 0.03))
    var path = source(text: ".config/tool", box: CGRect(x: 0.3, y: 0.4, width: 0.15, height: 0.03), appearance: codeAppearance)
    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: [label, path]))
    label.imageAspectRatio = 4
    path.imageAspectRatio = 4
    #expect(!OverlayTranslationPolicy.preservesSource(at: 0, in: [label, path]))
    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: [label, path]) == nil)
  }

  @Test
  func `compact table metadata beside code keeps original pixels`() {
    var codeAppearance = OverlaySourceAppearance.fallback
    codeAppearance.fontDesign = .monospaced
    let label = source(text: "GitHub Copilot", box: CGRect(x: 0.05, y: 0.4, width: 0.15, height: 0.04))
    let code = source(
      text: ".github/instructions/*.instructions.md",
      box: CGRect(x: 0.25, y: 0.4, width: 0.35, height: 0.04),
      appearance: codeAppearance,
    )
    let prose = source(
      text: "This explanatory sentence should still be translated for the reader.",
      box: CGRect(x: 0.05, y: 0.5, width: 0.7, height: 0.04),
    )
    let sources = [label, code, prose]

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 2, in: sources))
  }

  @Test
  func `visual repository metadata keeps original pixels`() {
    let language = source(
      text: "• Swift",
      box: CGRect(x: 0.05, y: 0.8, width: 0.08, height: 0.04),
    )
    let count = source(
      text: "& 572",
      box: CGRect(x: 0.14, y: 0.8, width: 0.05, height: 0.04),
    )
    let prose = source(
      text: "Chapter 2",
      box: CGRect(x: 0.05, y: 0.9, width: 0.1, height: 0.04),
    )
    let sources = [language, count, prose]

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: sources))
    #expect(OverlayTranslationPolicy.preservesSource(at: 1, in: sources))
    #expect(!OverlayTranslationPolicy.preservesSource(at: 2, in: sources))
  }

  @Test(arguments: [
    ("• Keep each bullet on a readable line.", false),
    ("● All systems operational", false),
    ("• Swift", true),
    ("● Swift 94 11", true),
  ])
  func `bullet preservation distinguishes prose from compact metadata`(
    _ text: String,
    expectedPreservation: Bool,
  ) {
    let value = source(text: text, box: CGRect(x: 0.1, y: 0.2, width: 0.4, height: 0.04))

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: [value]) == expectedPreservation)
  }

  @Test(arguments: [
    ("AGPL 3.0-only", true),
    ("macOS 14+", true),
    ("Chapter 2", false),
  ])
  func `versioned technical metadata keeps its exact source value`(
    _ text: String,
    expectedPreservation: Bool,
  ) {
    let value = source(text: text, box: CGRect(x: 0.1, y: 0.2, width: 0.15, height: 0.04))

    #expect(OverlayTranslationPolicy.preservesSource(at: 0, in: [value]) == expectedPreservation)
  }

  @Test
  func `compact badge labels use their trailing values as translation context`() {
    let sources = [
      source(text: "release", box: CGRect(x: 0.0275, y: 0.345, width: 0.0465, height: 0.045)),
      source(text: "v1.12.0", box: CGRect(x: 0.0807, y: 0.345, width: 0.0519, height: 0.045)),
      source(text: "downloads", box: CGRect(x: 0.1488, y: 0.345, width: 0.0692, height: 0.045)),
      source(text: "233", box: CGRect(x: 0.2249, y: 0.345, width: 0.0254, height: 0.045)),
      source(text: "macOS", box: CGRect(x: 0.2676, y: 0.345, width: 0.0450, height: 0.045)),
      source(text: "14+", box: CGRect(x: 0.3218, y: 0.345, width: 0.0277, height: 0.045)),
      source(text: "License", box: CGRect(x: 0.3655, y: 0.345, width: 0.0487, height: 0.045)),
      source(text: "AGPL 3.0-only", box: CGRect(x: 0.4164, y: 0.345, width: 0.0969, height: 0.045)),
    ]

    #expect(OverlayTranslationPolicy.trailingContext(at: 0, in: sources) == "v1.12.0")
    #expect(OverlayTranslationPolicy.trailingContext(at: 2, in: sources) == "233")
    #expect(OverlayTranslationPolicy.trailingContext(at: 4, in: sources) == "14+")
    #expect(OverlayTranslationPolicy.trailingContext(at: 6, in: sources) == "AGPL 3.0-only")
    #expect(OverlayTranslationPolicy.trailingContext(at: 1, in: sources) == nil)
    #expect(OverlayTranslationPolicy.trailingContext(at: 7, in: sources) == nil)
  }

  @Test
  func `contextual translation keeps only the translated label`() {
    #expect(
      TranslationTextStructure.label(fromContextualTranslation: "라이선스: AGPL 3.0 전용")
        == "라이선스"
    )
    #expect(
      TranslationTextStructure.label(fromContextualTranslation: "릴리즈：v1.12.0")
        == "릴리즈"
    )
    #expect(TranslationTextStructure.label(fromContextualTranslation: "구분자 없음") == nil)
  }

  @Test
  func `unmatched style does not replace the plain translation`() throws {
    var source = AttributedString("狼煙")
    try tag("狼煙", with: "swiftycrow-style://run/0", in: &source)

    let alignment = TranslationStyleMapper.align(
      source: source,
      target: "봉화입니다.",
    )

    #expect(String(alignment.target.characters) == "봉화입니다.")
    #expect(alignment.unmatched.map(\.text) == ["狼煙"])
  }

  @Test
  func `translation cannot turn one recovered line break into A blank paragraph`() {
    let normalized = TranslationTextStructure.matchingSourceBreaks(
      "두 개의 수표가 대기 중입니다.\n\n오렌지색 표면은 유지됩니다.",
      source: "Two checks are pending.\nThe orange surface remains visible.",
    )

    #expect(normalized == "두 개의 수표가 대기 중입니다.\n오렌지색 표면은 유지됩니다.")
  }

  @Test
  func `intentional source paragraph spacing is retained`() {
    let normalized = TranslationTextStructure.matchingSourceBreaks(
      "첫 문단입니다.\n\n\n둘째 문단입니다.",
      source: "First paragraph.\n\nSecond paragraph.",
    )

    #expect(normalized == "첫 문단입니다.\n\n둘째 문단입니다.")
  }

  // MARK: Private

  private func range(of substring: String, in text: String) throws -> NSRange {
    let range = (text as NSString).range(of: substring)
    return try #require(range.location != NSNotFound ? range : nil)
  }

  private func tag(
    _ substring: String,
    with link: String,
    in attributed: inout AttributedString,
  ) throws {
    let range = try #require(attributed.range(of: substring))
    attributed[range].link = URL(string: link)
  }

  private func source(
    text: String,
    box: CGRect,
    appearance: OverlaySourceAppearance = .fallback,
  ) -> OverlayLine.Source {
    OverlayLine.Source(
      recognized: OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        appearance: appearance,
      ),
      language: Locale.Language(identifier: "en-US"),
    )
  }

}
