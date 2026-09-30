// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct TranslationLiteralPlanTests {
  @Test
  func attributedRoundTripRetainsNonliteralOwnershipAndRestoresCodeAfterReordering() throws {
    var code = AttributedString("i8")
    code.inlinePresentationIntent = .code
    code.link = URL(string: "swiftycrow-style://run/0")!
    var formula = AttributedString("2⁷ − 1")
    formula.link = URL(string: "swiftycrow-style://run/1?source=pixels")!
    let source = code + AttributedString(" holds ") + formula
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.requestText == "ZXQ000XQZ holds 2⁷ − 1")
    #expect(plan.requestAttributedText.runs.filter { $0.link != nil }.map(\.link) == [formula.link])
    var translatedFormula = AttributedString("127")
    translatedFormula.link = formula.link
    let response = AttributedString("값 ") + translatedFormula + AttributedString("은 ZXQ000XQZ에 저장돼요 👩‍💻.")
    let restored = try #require(plan.restoring(response))
    #expect(String(restored.characters) == "값 127은 i8에 저장돼요 👩‍💻.")
    #expect(restored.runs.filter { $0.link == formula.link }.map { String(restored.characters[$0.range]) } == ["127"])
    #expect(restored.runs.filter { $0.inlinePresentationIntent?.contains(.code) == true }
      .map { String(restored.characters[$0.range]) } == ["i8"])
    #expect(plan.restoring(AttributedString("값 127에는 코드가 없습니다.")) == nil)
    #expect(plan.restoring(AttributedString("ZXQ000XQZ ZXQ000XQZ")) == nil)
  }

  @Test
  func punctuationCanAssembleAnIdentifierWithoutAbsorbingFollowingProse() throws {
    let text = "Use foo.bar types."
    let base = OverlaySourceAppearance(background: .init(red: 1, green: 1, blue: 1, alpha: 1), foreground: .black, confidence: 1)
    var chip = base
    chip.background = .init(red: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    let runs = ["foo", "bar"].enumerated().map { index, token in
      OverlaySourceStyleRun(
        range: (text as NSString).range(of: token),
        box: CGRect(x: Double(index) * 0.1, y: 0, width: 0.1, height: 0.1),
        appearance: chip
      )
    }
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text, appearance: base, styleRuns: runs),
      language: .init(identifier: "en")
    )
    #expect(try #require(TranslationLiteralPlan(source.attributedTextForTranslation())).requestText == "Use ZXQ000XQZ types.")
  }

  @Test
  func codeChipCannotAbsorbTheFollowingPlainWordWhenColorsAreSimilar() throws {
    let text = "Use usize types here."
    let base = OverlaySourceAppearance(
      background: .init(red: 0.999, green: 0.999, blue: 0.999, alpha: 1),
      foreground: .init(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
      confidence: 1
    )
    var code = base
    code.background = .init(red: 0.973, green: 0.975, blue: 0.973, alpha: 1)
    code.fontDesign = .monospaced
    var plain = base
    plain.background = .init(red: 0.994, green: 0.994, blue: 0.994, alpha: 1)
    let runs = [
      OverlaySourceStyleRun(
        range: (text as NSString).range(of: "usize"),
        box: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.03),
        appearance: code
      ),
      OverlaySourceStyleRun(
        range: (text as NSString).range(of: "types"),
        box: CGRect(x: 0.21, y: 0.1, width: 0.1, height: 0.03),
        appearance: plain
      ),
    ]
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text, appearance: base, styleRuns: runs),
      language: .init(identifier: "en")
    )
    let plan = try #require(TranslationLiteralPlan(source.attributedTextForTranslation()))
    #expect(plan.requestText == "Use ZXQ000XQZ types here.")
  }

  @Test
  func adjacentCodeChipsRetainTheirLiteralRoleAfterStyleCoalescing() throws {
    let text = "Use u32 u64 values."
    let base = OverlaySourceAppearance(background: .init(red: 1, green: 1, blue: 1, alpha: 1), foreground: .black, confidence: 1)
    var code = base
    code.background = .init(red: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    let runs = ["u32", "u64"].enumerated().map { index, value in
      OverlaySourceStyleRun(
        range: (text as NSString).range(of: value),
        box: CGRect(x: 0.1 + Double(index) * 0.12, y: 0.1, width: 0.1, height: 0.03),
        appearance: code
      )
    }
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text, appearance: base, styleRuns: runs),
      language: .init(identifier: "en")
    )
    let plan = try #require(TranslationLiteralPlan(source.attributedTextForTranslation()))
    #expect(plan.requestText == "Use ZXQ000XQZ values.")
    #expect(String(try #require(plan.restoring("ZXQ000XQZ 값을 사용하세요.")).characters) == "u32 u64 값을 사용하세요.")
  }

  @Test
  func aChangedLiteralRoleInvalidatesSemanticReuseButRecoloringDoesNot() {
    let text = "Use u32 to store the number."
    let base = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1, fontWeight: .regular)
    var chip = base
    chip.background = .init(red: 0.88, green: 0.88, blue: 0.88, alpha: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.1),
      text: text,
      appearance: base,
      styleRuns: [.init(range: (text as NSString).range(of: "u32"), box: .zero, appearance: chip)]
    )
    let source = OverlayLine.Source(recognized: line, language: .init(identifier: "en"))
    var plain = source
    plain.styleRuns = []
    #expect(!source.canReuseTranslation(relativeTo: plain, imageSize: CGSize(width: 1000, height: 800)))
    var recolored = source
    recolored.styleRuns[0].appearance.foreground = .init(red: 0.2, green: 0.4, blue: 0.9, alpha: 1)
    #expect(source.canReuseTranslation(relativeTo: recolored, imageSize: CGSize(width: 1000, height: 800)))
  }

  @Test
  func inlineTypeAndVersionAreProtectedWithoutFreezingAnOrdinaryStyledWord() throws {
    let text = "Use u32 and version v2.10.0, then open settings."
    let base = OverlaySourceAppearance(
      background: .init(red: 0.9969, green: 0.9969, blue: 0.9969, alpha: 1),
      foreground: .black,
      confidence: 1,
      fontWeight: .regular
    )
    var chip = base
    chip.background = .init(red: 0.9722, green: 0.9751, blue: 0.9721, alpha: 1)
    chip.foreground = .init(red: 0.2, green: 0.11, blue: 0.016, alpha: 1)
    let runs = ["u32", "v2.10.0", "open"].enumerated().map { index, value in
      OverlaySourceStyleRun(
        range: (text as NSString).range(of: value),
        box: CGRect(x: Double(index) * 0.25, y: 0, width: 0.1, height: 0.1),
        appearance: chip
      )
    }
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .zero, text: text, appearance: base, styleRuns: runs),
      language: .init(identifier: "en")
    )
    let plan = try #require(TranslationLiteralPlan(source.attributedTextForTranslation()))
    #expect(plan.requestText == "Use ZXQ000XQZ and version ZXQ001XQZ, then open settings.")
  }

  @Test
  func reorderedLiteralsRetainExactSpellingAndTheirOwnStyles() throws {
    var source = AttributedString("Use u8 with 2⁸ − 1 and isize.")
    for (index, value) in ["u8", "2⁸ − 1", "isize"].enumerated() {
      let range = try #require(source.range(of: value))
      source[range].inlinePresentationIntent = .code
      source[range].link = URL(string: "swiftycrow-style://run/\(index)")!
    }
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.requestText == "Use ZXQ000XQZ with ZXQ001XQZ and ZXQ002XQZ.")
    let decoded = try #require(plan.restoring("ZXQ002XQZ와 ZXQ000XQZ에는 ZXQ001XQZ을 사용하세요."))
    #expect(String(decoded.characters) == "isize와 u8에는 2⁸ − 1을 사용하세요.")
    let aligned = TranslationStyleMapper.align(source: source, target: String(decoded.characters), preserving: decoded)
    #expect(aligned.unmatched.isEmpty)
    for (index, value) in ["u8", "2⁸ − 1", "isize"].enumerated() {
      let range = try #require(aligned.target.range(of: value))
      #expect(aligned.target[range].link == URL(string: "swiftycrow-style://run/\(index)"))
    }
  }

  @Test(arguments: [
    "Missing",
    "ZXQ000XQZ ZXQ000XQZ",
    "ZXQ001XQZ",
    "zxq000xqz",
    "ZXQ000XQZ ZXQ",
    "ZXQ000XQZ ZXQ009XQZ",
    "ZXQ 000XQZ",
    "ZXQ000 XQZ",
  ])
  func malformedMarkerResponsesCannotBeDisplayed(_ response: String) throws {
    var source = AttributedString("u8")
    source.inlinePresentationIntent = .code
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.restoring(response) == nil)
  }

  @Test
  func adjacentAttributeRunsDoNotIntroduceSpacesInsideAnIdentifier() throws {
    var source = AttributedString("Use foo.Bar")
    let a = try #require(source.range(of: "foo."))
    let b = try #require(source.range(of: "Bar"))
    source[a].inlinePresentationIntent = .code
    source[b].inlinePresentationIntent = .code
    source[a].link = URL(string: "swiftycrow-style://run/0")!
    source[b].link = URL(string: "swiftycrow-style://run/1")!
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.requestText == "Use ZXQ000XQZ")
    let restored = try #require(plan.restoring("ZXQ000XQZ을 사용하세요"))
    #expect(String(restored.characters) == "foo.Bar을 사용하세요")
    #expect(restored.runs.compactMap(\.link).count == 2)
  }

  @Test
  func sourceMarkerLookalikesCannotCollideWithGeneratedMarkers() throws {
    var source = AttributedString("The text ZXQ000XQZ refers to u8.")
    source[try #require(source.range(of: "u8"))].inlinePresentationIntent = .code
    let plan = try #require(TranslationLiteralPlan(source))
    #expect(plan.requestText == "The text ZXQ000XQZ refers to ZXQX000XQZ.")
    #expect(String(try #require(plan.restoring("ZXQ000XQZ는 ZXQX000XQZ을 가리킵니다.")).characters) == "ZXQ000XQZ는 u8을 가리킵니다.")
  }

  @Test
  func plainProseDoesNotAcquireProtectedMarkers() {
    #expect(TranslationLiteralPlan(nil) == nil)
    #expect(TranslationLiteralPlan(AttributedString("Read the documentation.")) == nil)
  }
}
