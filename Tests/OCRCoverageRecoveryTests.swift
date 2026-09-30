// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Uncovered text and wide table rows")
struct OCRCoverageRecoveryTests {

  // MARK: Internal

  @Test(arguments: [false, true])
  func distantControlsKeepIndependentlyRecognizedLabelsSeparate(mirrored: Bool) {
    let labels = ["الأهداف الرئيسية", "النهج", "التطبيقات", "الفلسفة"]
    let lines = labels.enumerated().flatMap { index, text in
      let y = 0.1 + Double(index) * 0.04
      let width = index == 0 ? 0.18 : 0.09
      return [
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: mirrored ? 0.9 : 0.06, y: y, width: 0.06, height: 0.022),
          text: "[show]",
          recognitionGroupID: index + 10
        ),
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.53 - width / 2, y: y, width: width, height: 0.022),
          text: text,
          recognitionGroupID: index
        ),
      ]
    }
    let result = OCRVisualStructure.classifying(.init(lines: lines))
    #expect(result.lines.filter { labels.contains($0.text) }.allSatisfy { $0.preventsJoining })
  }

  @Test
  func distantWrappedParagraphIsNotInferredToBeTableLabels() {
    let lines = (0..<4).flatMap { index in
      let y = 0.1 + Double(index) * 0.04
      return [
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.06, y: y, width: 0.06, height: 0.022),
          text: "[show]",
          recognitionGroupID: index + 10
        ),
        OCRResult.Line(
          boundingBoxNormalized: CGRect(x: 0.43, y: y, width: 0.18, height: 0.022),
          text: "A nearby article row \(index)",
          recognitionGroupID: 1
        ),
      ]
    }
    let result = OCRVisualStructure.classifying(.init(lines: lines))
    #expect(result.lines.filter { $0.text.hasPrefix("A nearby article row") }.allSatisfy { !$0.preventsJoining })
  }

  @Test
  func wordEvidenceDoesNotClaimAnAbsentBaselineInsideAParentRectangle() {
    let first = CGRect(x: 0.1, y: 0.1, width: 0.8, height: 0.03)
    let last = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.03)
    let missing = CGRect(x: 0.1, y: 0.15, width: 0.8, height: 0.03)
    let line = OCRResult.Line(
      boundingBoxNormalized: first.union(last),
      text: "First and last rows",
      styleRuns: [
        .init(range: NSRange(location: 0, length: 5), box: first),
        .init(range: NSRange(location: 6, length: 4), box: last),
      ]
    )
    #expect(OCRCoverage.uncovered([missing], by: OCRCoverage.evidenceBoxes(for: line)) == [missing])
  }

  @Test
  func whitespaceInsideARecognizedRowDoesNotTriggerRecovery() {
    let a = CGRect(x: 0.1, y: 0.1, width: 0.15, height: 0.03)
    let b = CGRect(x: 0.7, y: 0.1, width: 0.15, height: 0.03)
    let line = OCRResult.Line(
      boundingBoxNormalized: a.union(b),
      text: "One row",
      styleRuns: [.init(range: NSRange(location: 0, length: 3), box: a), .init(range: NSRange(location: 4, length: 3), box: b)]
    )
    #expect(OCRCoverage.uncovered([a.union(b)], by: OCRCoverage.evidenceBoxes(for: line)).isEmpty)
  }

  @Test
  func failedLongRowSplitsOnlyAtBlankGapsAndRetainsRightToLeftOrder() async throws {
    let (image, detected) = try rowFixture()
    let recovered = try await OCRCoverage.recoveringUncoveredRows([detected], recognized: [], image: image) { crop in
      let right = crop.midX > 127
      let box = CGRect(x: right ? 130.0 / 300 : 20.0 / 300, y: 35.0 / 80, width: 105.0 / 300, height: 10.0 / 80)
      return [.init(
        boundingBoxNormalized: box,
        text: right ? "Intelligence بداية" : "نهاية الجملة",
        imageAspectRatio: 300.0 / 80,
        horizontalGlyphScale: box.height
      )]
    }
    #expect(recovered.map(\.text).joined(separator: " ") == "Intelligence بداية نهاية الجملة")
    #expect(OCRCoverage.uncovered([detected], by: recovered.flatMap(OCRCoverage.evidenceBoxes)).isEmpty)
  }

  @Test
  func partialSubregionRecognitionIsNotAcceptedAsACompleteRow() async throws {
    let (image, detected) = try rowFixture()
    let recovered = try await OCRCoverage.recoveringUncoveredRows([detected], recognized: [], image: image) { crop in
      guard crop.midX < 127 else { return [] }
      return [.init(
        boundingBoxNormalized: CGRect(x: 20.0 / 300, y: 35.0 / 80, width: 105.0 / 300, height: 10.0 / 80),
        text: "نهاية الجملة",
        imageAspectRatio: 300.0 / 80
      )]
    }
    #expect(recovered.isEmpty)
  }

  @Test
  func completeRowsDoNotInvokeTheAdditionalRecognizer() async throws {
    let (image, detected) = try rowFixture()
    let recovered = try await OCRCoverage.recoveringUncoveredRows(
      [detected],
      recognized: [.init(boundingBoxNormalized: detected, text: "Already recognized")],
      image: image
    ) { _ in
      Issue.record("A fully covered row must not invoke recovery")
      return []
    }
    #expect(recovered.isEmpty)
  }

  @Test
  func aNarrowWordIsNotDiscardedBecauseItIsTallerThanItIsWide() {
    let width = 150
    let height = 20
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 5..<15 {
      for x in Array(5..<11) + Array(17..<147) {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
      }
    }
    let pieces = OCRCoverage.whitespaceSplit(
      of: CGRect(x: 0, y: 0, width: width, height: height),
      pixels: Data(pixels),
      width: width,
      height: height
    )
    #expect(pieces.count == 2)
    #expect(pieces.first?.width == 17)
  }

  @Test
  func shortScriptGlyphsOnTheSameBaselineStillOwnTheirWordSpan() {
    let row = CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.03)
    let word = CGRect(x: 0.21, y: 0.408, width: 0.08, height: 0.016)
    #expect(OCRCoverage.coversHorizontalSpan(row, by: [word]))
    #expect(!OCRCoverage.coversHorizontalSpan(row, by: [word.offsetBy(dx: 0, dy: 0.1)]))
    #expect(!OCRCoverage.coversHorizontalSpan(row, by: [CGRect(x: 0.21, y: 0.408, width: 0.035, height: 0.016)]))
  }

  @Test
  func recoveryAcceptsAShortLeafOnlyWhenTheWholeRowStillHasCoverage() async throws {
    let (image, detected) = try rowFixture()
    let recovered = try await OCRCoverage.recoveringUncoveredRows([detected], recognized: [], image: image) { crop in
      let right = crop.midX > 127
      return [.init(
        boundingBoxNormalized: CGRect(
          x: right ? 130.0 / 300 : 20.0 / 300,
          y: right ? 38.0 / 80 : 35.0 / 80,
          width: 105.0 / 300,
          height: right ? 4.0 / 80 : 10.0 / 80
        ),
        text: right ? "AI" : "بداية الجملة",
        imageAspectRatio: 300.0 / 80
      )]
    }
    let text = recovered.map(\.text).joined(separator: " ")
    #expect(text.contains("AI"))
    #expect(text.contains("بداية الجملة"))
    #expect(OCRCoverage.uncovered([detected], by: recovered.flatMap(OCRCoverage.evidenceBoxes)).isEmpty)
  }

  // MARK: Private

  private func rowFixture() throws -> (CGImage, CGRect) {
    let context = try #require(CGContext(
      data: nil,
      width: 300,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 1200,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 300, height: 80))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    for x in [20, 75, 130, 185] { context.fill(CGRect(x: x, y: 35, width: 50, height: 10)) }
    return (try #require(context.makeImage()), CGRect(x: 20.0 / 300, y: 35.0 / 80, width: 215.0 / 300, height: 10.0 / 80))
  }

}
