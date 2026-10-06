// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct SourceArtworkIsolationTests {
  struct OutlineVariant: Sendable {
    static let all = [false, true].flatMap { dark in
      [false, true].flatMap { trailing in
        [false, true].map { square in OutlineVariant(dark: dark, trailing: trailing, square: square) }
      }
    }

    var dark: Bool
    var trailing: Bool
    var square: Bool

  }

  @Test(arguments: [1, 2], OutlineVariant.all)
  func anUntranscribedOutlinedControlCannotBeErasedWithItsLabel(
    _ scale: Int,
    _ variant: OutlineVariant
  ) {
    let dark = variant.dark
    let trailing = variant.trailing
    let square = variant.square
    let background: OverlayColor = dark ? .black : .white
    let foreground: OverlayColor = dark ? .white : .black
    let box = CGRect(x: 0.1, y: 0.44, width: 0.41, height: 0.18)
    let line = OCRResult.Line(boundingBoxNormalized: box, text: "Label", styleRuns: [
      .init(range: NSRange(location: 0, length: 5), box: box)
    ])
    let refined = SourceArtworkIsolation.refine(line, width: 200 * scale, height: 100 * scale, background: background) { x, y in
      let px = trailing ? 122 - CGFloat(x) / CGFloat(scale) : CGFloat(x) / CGFloat(scale)
      let py = CGFloat(y) / CGFloat(scale)
      let radius = square ? max(abs(px - 28.5), abs(py - 50.5)) : hypot(px - 28.5, py - 50.5)
      if radius >= 7.5, radius <= 9 { return foreground }
      if px >= 45, px < 101, py >= 45, py < 56, Int(px) % 10 < 6 { return foreground }
      return background
    }
    #expect(refined.text == "Label")
    #expect(refined.boundingBoxNormalized.width < box.width * 0.75)
    #expect(refined.alignment == (trailing ? .trailing : .leading))
    #expect(refined.preventsJoining)
    let icon = CGRect(x: trailing ? 0.42 : 0.095, y: 0.41, width: 0.1, height: 0.2)
    #expect(!refined.boundingBoxNormalized.intersects(icon))
    #expect(refined.replacementPatches.allSatisfy { !$0.box.intersects(icon) })
    #expect(refined.styleRuns.allSatisfy { !$0.box.intersects(icon) })
  }

  @Test(arguments: [false, true])
  func aLetterOOrAnOpenOutlineCannotBeRemovedAsAControl(_ open: Bool) {
    let box = CGRect(x: 0.1, y: 0.4, width: 0.41, height: 0.22)
    let line = OCRResult.Line(boundingBoxNormalized: box, text: "Open", styleRuns: [
      .init(range: NSRange(location: 0, length: 4), box: box)
    ])
    let refined = SourceArtworkIsolation.refine(line, width: 200, height: 100, background: .white) { x, y in
      let radius = hypot(CGFloat(x) - 28.5, CGFloat(y) - 50.5)
      if radius >= 7.5, radius <= 9, !(open && y < 48) { return .black }
      if (45..<101).contains(x), (open ? 45..<56 : 42..<60).contains(y), x % 10 < 6 { return .black }
      return .white
    }
    #expect(refined == line)
  }

  @Test
  func aTranscribedLetterOWithAWideWordGapRetainsItsOwner() {
    let box = CGRect(x: 0.1, y: 0.4, width: 0.41, height: 0.22)
    let line = OCRResult.Line(boundingBoxNormalized: box, text: "O label", styleRuns: [
      .init(range: NSRange(location: 0, length: 7), box: box)
    ])
    let refined = SourceArtworkIsolation.refine(line, width: 200, height: 100, background: .white) { x, y in
      let radius = hypot(CGFloat(x) - 28.5, CGFloat(y) - 50.5)
      if radius >= 7.5, radius <= 9 { return .black }
      if (45..<101).contains(x), (45..<56).contains(y), x % 10 < 6 { return .black }
      return .white
    }
    #expect(refined == line)
  }

  @Test
  func aColoredEmblemDoesNotBelongToThePublisherTextMask() {
    let box = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
    let line = OCRResult.Line(boundingBoxNormalized: box, text: "Publisher", styleRuns: [
      .init(range: NSRange(location: 0, length: 9), box: box)
    ])
    let refined = SourceArtworkIsolation.refine(line, width: 200, height: 100, background: .white) { x, y in
      if (20 ..< 46).contains(x), (31 ..< 69).contains(y) {
        return OverlayColor(red: 1, green: 0.2, blue: 0, alpha: 1)
      }
      if (62 ..< 179).contains(x), (38 ..< 62).contains(y), x % 10 < 6 { return .black }
      return .white
    }
    #expect(refined.boundingBoxNormalized.minX >= 0.3)
    #expect(refined.replacementPatches.allSatisfy { $0.box.minX >= 0.3 })
    #expect(refined.text == line.text)
  }

  @Test
  func aColoredRecognizedWordIsNotRemovedAsArtwork() {
    let box = CGRect(x: 0.1, y: 0.3, width: 0.8, height: 0.4)
    let line = OCRResult.Line(boundingBoxNormalized: box, text: "Red text", styleRuns: [
      .init(range: NSRange(location: 0, length: 3), box: CGRect(x: 0.1, y: 0.3, width: 0.13, height: 0.4)),
      .init(range: NSRange(location: 4, length: 4), box: CGRect(x: 0.31, y: 0.38, width: 0.58, height: 0.24)),
    ])
    let refined = SourceArtworkIsolation.refine(line, width: 200, height: 100, background: .white) { x, y in
      if (20 ..< 46).contains(x), (31 ..< 69).contains(y) {
        return OverlayColor(red: 1, green: 0.2, blue: 0, alpha: 1)
      }
      if (62 ..< 179).contains(x), (38 ..< 62).contains(y) { return .black }
      return .white
    }
    #expect(refined == line)
  }
}
