// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreText
import Foundation

import Testing
@testable import SwiftyCrow

/// Tests the compositor contract with known OCR/target text, without invoking a
/// model. Passing this matrix says nothing about native OCR or translation fluency.
@Suite("Offline capture structure and language matrix")
struct CaptureQualityMatrixTests {
  struct Scenario: Sendable, CustomTestStringConvertible {
    var source: CaptureQualityLanguage
    var target: CaptureQualityLanguage
    var structure: CaptureQualityStructure
    var dark: Bool

    var testDescription: String {
      "\(structure.rawValue)/\(source.code)->\(target.code)/\(dark ? "dark-retina" : "light")"
    }
  }

  static let scenarios: [Scenario] = CaptureQualityLanguage.all.flatMap { source in
    CaptureQualityLanguage.all.filter { $0.code != source.code }.flatMap { target in
      CaptureQualityStructure.allCases.flatMap { structure in
        [false, true].map { Scenario(source: source, target: target, structure: structure, dark: $0) }
      }
    }
  }

  @Test(arguments: scenarios)
  func translatedBlocksStayReadableInsideIndependentContainers(_ item: Scenario) throws {
    let scale: CGFloat = item.dark ? 1.5 : 1
    let canvas = CGSize(width: 1200 * scale, height: 800 * scale)
    let originals = item.structure.blocks(item.source)
    let targets = item.structure.blocks(item.target)
    let lines = originals.enumerated().map { index, block in
      let normalized = CGRect(
        x: block.rect.minX / 1200,
        y: block.rect.minY / 800,
        width: block.rect.width / 1200,
        height: block.rect.height / 800
      )
      let appearance = OverlaySourceAppearance(
        background: item.dark ? .black : .white,
        foreground: item.dark ? .white : .black,
        confidence: 1,
        fontSizeScale: block.size / 800,
        fontWeight: block.role == .heading
          ? .bold
          : .regular
      )
      let recognized = OCRResult.Line(
        boundingBoxNormalized: normalized,
        text: block.text,
        imageAspectRatio: 1.5,
        preventsJoining: block.role == .label,
        preservesSource: block.role == .literal,
        rowCount: block.role == .prose ? 3 : 1,
        appearance: appearance,
        replacementPatches: [.init(
          box: normalized,
          appearance: appearance
        )],
        alignment: .leading
      )
      var line = OverlayLine(
        id: UUID(),
        source: .init(
          recognized: recognized,
          language: Locale.Language(identifier: item.source.code)
        ),
        initialContent: .pending
      )
      if block.role != .literal {
        line.showTranslation(targets[index].text, language: Locale.Language(identifier: item.target.code))
      }
      return line
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    let changedIndices = originals.indices.filter { originals[$0].role != .literal && originals[$0].text != targets[$0].text }
    #expect(placements.count == changedIndices.count)
    for index in originals.indices where originals[index].text == targets[index].text {
      #expect(!lines[index].shouldReplaceSourcePixels)
    }
    #expect(CaptureQualityMetrics.layoutIssues(placements, canvas: canvas, minimumFontRatio: 0.5).isEmpty)
    for placement in placements {
      let index = try #require(lines.firstIndex { $0.id == placement.id })
      let expected = originals[index].rect.applying(CGAffineTransform(scaleX: scale, y: scale))
      #expect(expected.insetBy(dx: -1, dy: -1).contains(placement.frame))
      let plan = HorizontalTextRenderer.plan(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        fontSize: placement.fontSize,
        appearance: placement.line.source.appearance,
        styles: [],
        width: placement.frame.width,
        lineHeightMultiple: placement.lineHeightMultiple
      )
      let ranges = plan.lines.map { CTLineGetStringRange($0) }
      #expect(ranges.first?.location == 0)
      #expect(ranges.last.map { $0.location + $0.length } == targets[index].text.utf16.count)
      #expect(try #require(HorizontalTextRenderer.image(for: placement, scale: 1)).width > 0)
      for other in placements where other.id != placement.id {
        #expect(placement.frame.intersection(other.frame).isEmpty)
      }
    }
    #expect(lines.filter { $0.source.preservesSource }.allSatisfy { !$0.shouldReplaceSourcePixels })
  }

  @Test(arguments: CaptureQualityLanguage.all)
  func parallelMenuItemsDoNotBecomeOneSentence(_ language: CaptureQualityLanguage) {
    let lines = language.labels.enumerated().map { i, label in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.04 + Double(i) * 0.24, y: 0.2, width: 0.2, height: 0.05),
        text: label,
        imageAspectRatio: 1.5,
        recognitionGroupID: 1
      )
    }
    let result = OCRVisualStructure.classifying(OCRResult(lines: lines)).coalescingParagraphFragments()
    #expect(result.lines.count == 4)
    #expect(Set(result.lines.map(\.text)) == Set(language.labels))
  }
}
