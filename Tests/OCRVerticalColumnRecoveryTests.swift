// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Synchronization
import Testing
@testable import SwiftyCrow

struct OCRVerticalColumnRecoveryTests {

  // MARK: Internal

  @Test
  func oneColumnKeepsItsPrefixButExcludesRubyAndNeighbors() {
    let (source, prefix, body) = sample()
    var ruby = prefix
    ruby.text = "カイ"
    ruby.boundingBoxNormalized = CGRect(x: 0.34, y: 0.12, width: 0.01, height: 0.04)
    var neighbor = body
    neighbor.boundingBoxNormalized.origin.x = 0.35
    let fragments = OCRVerticalColumnRecovery.fragments(for: source, candidates: [neighbor, body, ruby, prefix])
    #expect(fragments.map(\.text) == [prefix.text, body.text])
    var overlapping = body
    overlapping.boundingBoxNormalized.origin.y = 0.12
    #expect(OCRVerticalColumnRecovery.fragments(for: source, candidates: [prefix, body, overlapping]).isEmpty)
    var separated = body
    separated.boundingBoxNormalized.origin.y = 0.3
    #expect(OCRVerticalColumnRecovery.fragments(for: source, candidates: [prefix, separated]).isEmpty)
    var incomplete = body
    incomplete.boundingBoxNormalized.size.height = 0.1
    #expect(OCRVerticalColumnRecovery.fragments(for: source, candidates: [prefix, incomplete]).isEmpty)
    var confident = source
    confident.recognitionConfidence = 0.9
    #expect(OCRVerticalColumnRecovery.fragments(for: confident, candidates: [prefix, body]).isEmpty)
  }

  @Test
  func localAgreementRetainsEveryFragmentAndItsGeometryWithoutInflatingConfidence() async throws {
    let (source, prefix, body) = sample()
    let fragments = OCRVerticalColumnRecovery.fragments(for: source, candidates: [body, prefix])
    let reads = Mutex(0)
    let combined = try #require(try await OCRVerticalColumnRecovery.confirmedColumn(fragments) { fragment in
      reads.withLock { $0 += 1 }
      #expect(fragment.text == prefix.text)
      var confirmed = fragment
      confirmed.replacementPatches.append(.init(box: CGRect(x: 0.335, y: 0.1, width: 0.012, height: 0.09), isAnnotation: true))
      return confirmed
    })
    #expect(reads.withLock { $0 } == 1)
    #expect(combined.text == prefix.text + body.text)
    #expect(combined.recognitionConfidence == prefix.recognitionConfidence)
    #expect(combined.replacementPatches.count == 3)
    #expect(combined.styleRuns[1].range.location == prefix.text.utf16.count)
    #expect(combined.spacingAnchors[1].range.location == prefix.text.utf16.count)
    #expect(combined.recognitionLanguages == ["ja"])
    #expect(JapaneseRubyOCRCorrector.preferredCorrection(
      original: source.text,
      candidate: combined.text,
      confidence: combined.recognitionConfidence
    ) == nil)
    #expect(JapaneseRubyOCRCorrector.preferredCorrection(
      original: source.text,
      candidate: combined.text,
      confidence: combined.recognitionConfidence,
      independentlyConfirmed: true
    ) == combined.text)
  }

  @Test
  func anUnconfirmedPrefixCannotDisappearIntoAShorterCorrection() async throws {
    let (source, prefix, body) = sample()
    let fragments = OCRVerticalColumnRecovery.fragments(for: source, candidates: [prefix, body])
    let missing = try await OCRVerticalColumnRecovery.confirmedColumn(fragments) { _ in nil }
    #expect(missing == nil)
    let changed = try await OCRVerticalColumnRecovery.confirmedColumn(fragments) { fragment in
      var changed = fragment
      changed.text = "別の内容"
      return changed
    }
    #expect(changed == nil)
    let displaced = try await OCRVerticalColumnRecovery.confirmedColumn(fragments) { fragment in
      var displaced = fragment
      displaced.boundingBoxNormalized.origin.x = 0.8
      return displaced
    }
    #expect(displaced == nil)
  }

  // MARK: Private

  private func sample() -> (OCRResult.Line, OCRResult.Line, OCRResult.Line) {
    let source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3, y: 0.1, width: 0.04, height: 0.4),
      text: "旧字、最後まで読む",
      recognitionConfidence: 0.1,
      isVerticalBlock: true,
      verticalCharScale: 0.03
    )
    func row(_ text: String, box: CGRect, confidence: Float) -> OCRResult.Line {
      .init(
        boundingBoxNormalized: box,
        text: text,
        recognitionConfidence: confidence,
        isVerticalBlock: true,
        verticalCharScale: 0.03,
        replacementPatches: [.init(box: box)],
        styleRuns: [.init(range: NSRange(location: 0, length: text.utf16.count), box: box)],
        spacingAnchors: [.init(range: NSRange(location: 0, length: 1), box: box)],
        recognitionLanguages: ["ja"]
      )
    }
    return (
      source,
      row("第一章、", box: CGRect(x: 0.3, y: 0.1, width: 0.035, height: 0.09), confidence: 0.3),
      row("最後まで読む", box: CGRect(x: 0.301, y: 0.2, width: 0.03, height: 0.3), confidence: 0.5)
    )
  }
}
