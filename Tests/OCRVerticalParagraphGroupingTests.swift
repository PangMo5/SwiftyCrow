// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRVerticalParagraphGroupingTests {

  // MARK: Internal

  @Test(arguments: [0.03, 0.2])
  func nativeColumnPitchCarriesQuotationAndFinalSentenceIntoOneReadingFlow(_ inkPopulation: CGFloat) throws {
    let input = lines().map { source in
      var line = source
      line.appearance.foregroundConfidence = inkPopulation
      return line
    }
    let grouped = OCRResult(lines: input).coalescingParagraphFragments(clearVerticalExpansion: { _, _ in true })
    let paragraph = try #require(grouped.lines.first)
    #expect(grouped.lines.count == 1)
    #expect(paragraph.text == "準備を終えて説明を聞いた。うなずいた。「始めよう！」全員が答えた。")
    #expect(paragraph.rowCount == 5)
    #expect(paragraph.replacementPatches == input.flatMap(\.replacementPatches))
    #expect(paragraph.styleRuns.map(\.range.location) == [0, 6, 13, 19, 26])
    #expect(grouped.coalescingParagraphFragments(clearVerticalExpansion: { _, _ in true }) == grouped)
  }

  @Test(arguments: [
    "no pixels",
    "divider",
    "indent",
    "spacing",
    "different surface",
    "no established paragraph",
    "mixed containers",
  ])
  func uncertainBoundariesRemainSeparate(_ reason: String) {
    var input = lines()
    switch reason {
    case "indent": input[1].boundingBoxNormalized.origin.y += 0.035
    case "spacing": input[1].boundingBoxNormalized.origin.x -= 0.018
    case "different surface": input[1].appearance.background = .init(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
    case "no established paragraph": input[3].recognitionGroupID = 7
    case "mixed containers": input[3].recognitionContainer = CGRect(x: 0.3, y: 0.1, width: 0.1, height: 0.6)
    default: break
    }
    let corridor: ((OCRVerticalParagraphGrouping.Region, OCRVerticalParagraphGrouping.Region) -> Bool)? = reason == "no pixels"
      ? nil
      : { _, _ in reason != "divider" }
    let grouped = OCRResult(lines: input).coalescingParagraphFragments(clearVerticalExpansion: corridor)
    #expect(grouped.lines.count > 1)
    #expect(!grouped.lines.contains { $0.text.contains("うなずいた。「始めよう！」") })
  }

  @Test(arguments: [CGPoint(x: 58, y: 60), CGPoint(x: 52, y: 90), CGPoint(x: 70, y: 37)])
  func expandedLayoutRejectsGraphicsBesideAndBelowShortColumns(_ graphic: CGPoint) {
    let existing = OCRVerticalParagraphGrouping.Region(
      box: CGRect(x: 0.3, y: 0.2, width: 0.13, height: 0.3),
      background: .white
    )
    let next = OCRVerticalParagraphGrouping.Region(
      box: CGRect(x: 0.25, y: 0.18, width: 0.032, height: 0.22),
      background: .white
    )
    #expect(OCRVerticalParagraphGrouping.clearExpansion(from: existing, to: next, width: 200, height: 200) { _, _ in .white })
    #expect(!OCRVerticalParagraphGrouping.clearExpansion(from: existing, to: next, width: 200, height: 200) { x, y in
      CGPoint(x: x, y: y) == graphic ? .black : .white
    })
    #expect(!OCRVerticalParagraphGrouping.clearExpansion(from: existing, to: next, width: 200, height: 200) { _, _ in nil })
  }

  // MARK: Private

  private func lines() -> [OCRResult.Line] {
    let texts = ["全員が答えた。", "「始めよう！」", "うなずいた。", "説明を聞いた。", "準備を終えて"]
    return texts.enumerated().map { index, text in
      let box = CGRect(x: 0.2 + CGFloat(index) * 0.05, y: 0.2, width: 0.032, height: index == 0 ? 0.2 : 0.3)
      let appearance = OverlaySourceAppearance(
        background: .white,
        foreground: .black,
        confidence: 0.9,
        foregroundConfidence: 0.2,
        fontSizeScale: 0.03,
        fontWeight: .regular
      )
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        isVerticalBlock: true,
        verticalCharScale: 0.032,
        recognitionGroupID: index >= 2 ? 10 : index,
        appearance: appearance,
        replacementPatches: [.init(box: box, appearance: appearance)],
        styleRuns: [.init(range: NSRange(location: 0, length: text.utf16.count), box: box, appearance: appearance)]
      )
    }
  }
}
