// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct SourceArtworkIsolationTests {
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
