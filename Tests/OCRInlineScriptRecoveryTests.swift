// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRInlineScriptRecoveryTests {
  @Test(arguments: ["가격이 $50에서 $15로 상승했습니다", "日本語の引用", "مرحبا بالعالم", "שלום עולם", "Ελληνικό κείμενο"])
  func acceptsObservedScriptsInsteadOfInventingALatinSpelling(_ text: String) {
    #expect(OCRInlineScriptRecovery.accepts(text, confidence: 0.9))
    #expect(!OCRInlineScriptRecovery.accepts(text, confidence: 0.2))
  }

  @Test(arguments: ["The price is $50", "$50", "Présentation", "Résumé", "\u{FFFD}가격"])
  func rejectsNonEvidence(_ text: String) {
    #expect(!OCRInlineScriptRecovery.accepts(text, confidence: 1))
  }

  @Test
  func cropsOnlyDamagedInlineWordsAndKeepsAdjacentProseOutside() {
    let tokens = ["as", "a|b|", "$500|1", "$15₴", "x|[|..", "This", "reverses"]
    var offset = 0
    let runs = tokens.enumerated().map { index, text -> OverlaySourceStyleRun in
      defer { offset += text.utf16.count + 1 }
      return .init(
        range: NSRange(location: offset, length: text.utf16.count),
        box: CGRect(x: Double(index) * 0.1, y: 0.2, width: 0.09, height: 0.04)
      )
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0.2, width: 0.7, height: 0.04),
      text: tokens.joined(separator: " "),
      styleRuns: runs
    )
    let spans = OCRInlineScriptRecovery.suspiciousSpans(in: line)
    #expect(spans.count == 1)
    #expect((line.text as NSString).substring(with: spans[0].range) == "a|b| $500|1 $15₴ x|[|..")
  }
}
