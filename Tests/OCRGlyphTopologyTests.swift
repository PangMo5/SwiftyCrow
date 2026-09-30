// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Synchronization
import Testing
@testable import SwiftyCrow

struct OCRGlyphTopologyTests {
  @Test
  func opticalCorrectionRequiresOneUnambiguousNativeHypothesis() {
    let observed = OCRGlyphTopology.Signature(components: 3, holes: 2)
    let candidates: [VisionTextRecognizer.TextCandidate] = [.init(text: "18", confidence: 1), .init(text: "i8", confidence: 0.3)]
    #expect(OCRInlineGlyphRecovery.select(original: "is", observed: observed, candidates: candidates) == "i8")
    #expect(OCRInlineGlyphRecovery.select(original: "i8", observed: observed, candidates: candidates) == nil)
    #expect(OCRInlineGlyphRecovery
      .select(original: "18", observed: .init(components: 2, holes: 2), candidates: candidates) == nil)
    #expect(OCRInlineGlyphRecovery
      .select(original: "i8", observed: .init(components: 2, holes: 2), candidates: candidates) == nil)
    #expect(OCRInlineGlyphRecovery.select(
      original: "i8",
      observed: .init(components: 3, holes: 0),
      candidates: [.init(text: "is", confidence: 1)]
    ) == nil)
    #expect(OCRInlineGlyphRecovery.select(
      original: "is",
      observed: observed,
      candidates: candidates + [.init(text: "j8", confidence: 0.3)]
    ) == nil)
    #expect(OCRInlineGlyphRecovery.select(
      original: "is",
      observed: observed,
      candidates: [.init(text: "i8", confidence: 0.1)]
    ) == nil)
  }

  @Test(arguments: [(false, 1), (true, 1), (false, 6), (true, 6)])
  func correctionRequiresAMeasuredInlineSurfaceAndPreservesOtherText(_ scenario: (Bool, Int)) async throws {
    let (inverse, copies) = scenario
    let original = inverse ? "18" : "is"
    let corrected = inverse ? "18" : "i8"
    let text = "Keep \(original) inside this description for today."
    let base = OverlaySourceAppearance(background: .init(red: 1, green: 1, blue: 1, alpha: 1), foreground: .black, confidence: 1)
    var chip = base
    chip.background = .init(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
    let run = OverlaySourceStyleRun(
      range: (text as NSString).range(of: original),
      box: CGRect(x: 0.18, y: 0.18, width: 0.2, height: 0.2),
      appearance: chip
    )
    let patch = OverlaySourcePatch(
      box: CGRect(x: 0.15, y: 0.15, width: 0.26, height: 0.26),
      appearance: chip,
      erasesDistinctSurface: true
    )
    let tightPatch = OverlaySourcePatch(box: run.box, appearance: chip, erasesDistinctSurface: true)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.18, width: 0.8, height: 0.2),
      text: text,
      appearance: base,
      replacementPatches: [tightPatch, patch],
      styleRuns: [run]
    )
    #expect(OCRInlineGlyphRecovery.spans(in: line).count == 1)
    #expect(OCRInlineGlyphRecovery.spans(in: line).first?.surface == patch.box)
    var reversed = line
    reversed.replacementPatches.reverse()
    #expect(OCRInlineGlyphRecovery.spans(in: reversed).first?.surface == patch.box)
    var ordinary = line
    ordinary.replacementPatches = []
    #expect(OCRInlineGlyphRecovery.spans(in: ordinary).isEmpty)
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.translateBy(x: 0, y: 100)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    let rows = [".#..###..", inverse ? ".#..#.#.." : "....#.#..", ".#..###..", ".#..#.#..", ".#..###.."]
    for (y, row) in rows.enumerated() { for (x, value) in row.enumerated() where value == "#" {
      context.fill(CGRect(x: 20 + x, y: 20 + y, width: 1, height: 1))
    } }
    let image = try #require(context.makeImage())
    let requests = Mutex(0)
    let result = try await OCRInlineGlyphRecovery.recover(
      .init(lines: [ordinary] + Array(repeating: line, count: copies)),
      image: image,
      language: .init(code: "en")
    ) { _, crop, _ in
      #expect(crop == CGRect(x: 15, y: 15, width: 26, height: 26))
      requests.withLock { $0 += 1 }
      return [.init(text: "18", confidence: 1), .init(text: "i8", confidence: 0.3)]
    }
    #expect(requests.withLock { $0 } == (inverse ? 0 : min(4, copies)))
    #expect(result.lines[0] == ordinary)
    #expect(result.lines[1].text == "Keep \(corrected) inside this description for today.")
    #expect(result.lines[1].styleRuns == line.styleRuns)
    #expect(result.lines[1].replacementPatches == line.replacementPatches)
    #expect(result.lines.dropFirst(1 + min(4, copies)).allSatisfy { $0 == line })
  }

  @Test
  func disconnectedDotsAndEnclosedCountersRemainDistinct() {
    let rows = [".........", ".#..###..", "....#.#..", ".#..###..", ".#..#.#..", ".#..###..", "........."]
    #expect(OCRGlyphTopology.signature(mask: rows.flatMap { $0.map { $0 == "#" } }, width: 9, height: 7)
      == .init(components: 3, holes: 2))
  }

  @Test
  func diagonalStrokesAreConnectedWithoutInventingACounter() {
    let rows = [".....", ".#...", "..#..", "...#.", "....."]
    #expect(OCRGlyphTopology.signature(mask: rows.flatMap { $0.map { $0 == "#" } }, width: 5, height: 5)
      == .init(components: 1, holes: 0))
  }

  @Test
  func clippedOrEmptyInkCannotSupplyOpticalEvidence() {
    #expect(OCRGlyphTopology.signature(mask: [Bool](repeating: false, count: 25), width: 5, height: 5) == nil)
    var clipped = [Bool](repeating: false, count: 25)
    clipped[0] = true
    #expect(OCRGlyphTopology.signature(mask: clipped, width: 5, height: 5) == nil)
    #expect(OCRGlyphTopology.signature(mask: clipped, width: 0, height: 0) == nil)
  }

  @Test
  func referenceFacesDistinguishDotsAndCountersWithoutAWordDictionary() {
    #expect(SourceTypography.glyphTopologies(text: "i8") == [.init(components: 3, holes: 2)])
    #expect(SourceTypography.glyphTopologies(text: "18") == [.init(components: 2, holes: 2)])
    #expect(SourceTypography.glyphTopologies(text: "is") == [.init(components: 3, holes: 0)])
    #expect(SourceTypography.glyphTopologies(text: "A B") != SourceTypography.glyphTopologies(text: "A H"))
  }
}
