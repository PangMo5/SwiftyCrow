// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRCoverageTests {
  @Test
  func nonemptyDocumentStillRequiresCoverageForMissingBodyAndCode() {
    let title = CGRect(x: 0.3, y: 0.1, width: 0.4, height: 0.1)
    let code = CGRect(x: 0.2, y: 0.45, width: 0.5, height: 0.03)
    let body = CGRect(x: 0.05, y: 0.8, width: 0.9, height: 0.04)
    #expect(OCRCoverage.uncovered([title, code, body], by: [title]) == [code, body])
    #expect(OCRCoverage.uncovered([title, code, body], by: [title, code, body]).isEmpty)
    let crop = OCRCoverage.cropBounds(for: [code, body], imageSize: CGSize(width: 1000, height: 1000))
    #expect(crop?.contains(CGPoint(x: 300, y: 150)) == false)
    #expect(crop?.contains(CGPoint(x: 220, y: 460)) == true)
    #expect(crop?.contains(CGPoint(x: 900, y: 820)) == true)
  }

  @Test
  func neighboringControlsJointlyCoverDetectionButDuplicatesDoNot() {
    let row = CGRect(x: 0, y: 0, width: 1, height: 0.1)
    let left = CGRect(x: 0, y: 0, width: 0.4, height: 0.1)
    let right = CGRect(x: 0.6, y: 0, width: 0.4, height: 0.1)
    #expect(OCRCoverage.uncovered([row], by: [left, right]).isEmpty)
    #expect(OCRCoverage.uncovered([row], by: [left, left]) == [row])
  }

  @Test
  func noMissingTextDoesNotCreateAnotherRecognitionCrop() {
    #expect(OCRCoverage.cropBounds(for: [], imageSize: CGSize(width: 2220, height: 1256)) == nil)
    let edge = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
    #expect(OCRCoverage.cropBounds(for: [edge], imageSize: CGSize(width: 100, height: 100)) == CGRect(
      x: 0,
      y: 0,
      width: 13,
      height: 13
    ))
  }
}
