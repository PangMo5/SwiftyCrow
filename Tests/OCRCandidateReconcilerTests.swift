// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRCandidateReconcilerTests {
  @Test
  func spellingConfidenceCannotEraseNativeLiteralOwnership() {
    let box = CGRect(x: 0.2, y: 0.3, width: 0.05, height: 0.02)
    let cell = OCRTableCell(table: 0, row: 3, column: 1, box: box)
    let native = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "x128",
      preventsJoining: true,
      preservesSource: true,
      recognitionConfidence: 0.3,
      tableCell: cell
    )
    let reread = OCRResult.Line(boundingBoxNormalized: box.insetBy(dx: 0.004, dy: 0), text: "1128", recognitionConfidence: 1)
    #expect(OCRCandidateReconciler.adding([reread], to: [native]) == [native])
    #expect(OCRCandidateReconciler.canonical([reread, native]) == [native])
    #expect(!OCRLineRefiner.needsRefinement(native))
    var prose = reread
    prose.boundingBoxNormalized.origin.y += 0.1
    #expect(OCRCandidateReconciler.adding([prose], to: [native]).count == 2)
  }

  @Test
  func equallyConfidentClippedAscendersDoNotDuplicateTheCompleteRow() {
    let complete = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1141666654, y: 0.0451219514, width: 0.0983333333, height: 0.0219512195),
      text: "The free dictionary"
    )
    let clipped = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1191666676, y: 0.0451219512, width: 0.0958333333, height: 0.012195122),
      text: "Tho froo dictionary"
    )
    #expect(OCRCandidateReconciler.canonical([complete, clipped]) == [complete])
    #expect(OCRCandidateReconciler.canonical([clipped, complete]) == [complete])
    var annotation = clipped
    annotation.boundingBoxNormalized.origin.y -= 0.012
    #expect(OCRCandidateReconciler.canonical([complete, annotation]).count == 2)
  }

  @Test(arguments: [
    ("3.3. runcuons", "3.3. Functions"),
    ("4.7. Wnat Is ownersnid", "4.1. What is Ownership?"),
    ("integer overtow", "Integer Overflow"),
    ("Understanding Ownership", "Understanding Ownership"),
  ])
  func strongerRereadOwnsTheSameThinObservedRow(_ text: (String, String)) {
    let thin = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.31, y: 0.754, width: 0.05, height: 0.008),
      text: text.0,
      recognitionConfidence: 0.4
    )
    let complete = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.31, y: 0.75, width: 0.051, height: 0.017),
      text: text.1,
      recognitionConfidence: 0.9
    )
    #expect(OCRCandidateReconciler.canonical([thin, complete]) == [complete])
    #expect(OCRCandidateReconciler.canonical([complete, thin]) == [complete])
    #expect(OCRCandidateReconciler.adding([complete], to: [thin]) == [complete])
    var confidentThin = thin
    confidentThin.recognitionConfidence = 1
    confidentThin.text = text.1
    var weakComplete = complete
    weakComplete.recognitionConfidence = 0.4
    #expect(OCRCandidateReconciler.adding([confidentThin], to: [weakComplete]) == [confidentThin])
    var annotation = thin
    annotation.boundingBoxNormalized.origin.y = 0.745
    #expect(OCRCandidateReconciler.canonical([annotation, complete]).count == 2)
    var neighbor = thin
    neighbor.boundingBoxNormalized.origin.x += 0.04
    #expect(OCRCandidateReconciler.canonical([neighbor, complete]).count == 2)
  }

  @Test
  func overlappingWordTailCannotBeAppendedToTheCompleteWord() {
    let whole = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0500, y: 0.219512, width: 0.057422, height: 0.017073),
      text: "Beginning",
      imageAspectRatio: 1200.0 / 820,
      recognitionConfidence: 0.72
    )
    let tail = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.069167, y: 0.220732, width: 0.038255, height: 0.019512),
      text: "ginning",
      imageAspectRatio: 1200.0 / 820,
      recognitionConfidence: 1
    )
    #expect(OCRCandidateReconciler.canonical([whole, tail]) == [whole])
    var separate = tail
    separate.boundingBoxNormalized.origin.y += 0.03
    #expect(OCRCandidateReconciler.canonical([whole, separate]).count == 2)
  }

  @Test(arguments: [
    ("Current Swiftvcrow source", "Current SwiftyCrow source is available under the license."),
    ("現在のアプリケーション", "現在のアプリケーションはライセンスに従って提供されています。"),
    ("当前应用程序代码", "当前应用程序代码按照许可证提供，请阅读使用说明。"),
    ("هذا التطبيق متاح", "هذا التطبيق متاح بموجب الترخيص ويرجى قراءة التعليمات."),
    ("האפליקציה הזאת", "האפליקציה הזאת זמינה בהתאם לרישיון ולהוראות השימוש."),
  ])
  func overlappingPrefixHasOneOwnerAcrossScripts(_ text: (String, String)) {
    let partial = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.809, width: 0.29, height: 0.022),
      text: text.0,
      imageAspectRatio: 1.77,
      recognitionConfidence: 0.6
    )
    let complete = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.813, width: 0.86, height: 0.025),
      text: text.1,
      imageAspectRatio: 1.77,
      recognitionConfidence: 0.9
    )
    let resolved = OCRCandidateReconciler.canonical([partial, complete])
    #expect(resolved == [complete])
    #expect(OCRCandidateReconciler.canonical(resolved) == resolved)
  }

  @Test
  func almostIdenticalAreasCannotRemoveBothHypotheses() {
    let a = OCRResult.Line(boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.04), text: "文章 Text نص")
    var b = a
    b.boundingBoxNormalized.size.width -= 0.000001
    #expect(OCRCandidateReconciler.canonical([a, b]) == [a])
    #expect(OCRCandidateReconciler.canonical([b, a]) == [b])
  }

  @Test
  func repeatedWordsInDifferentRowsRemainIndependent() {
    let rows = [0.1, 0.2, 0.3].map { OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: $0, width: 0.3, height: 0.04),
      text: "次へ التالي Next"
    ) }
    #expect(OCRCandidateReconciler.canonical(rows) == rows)
  }
}
