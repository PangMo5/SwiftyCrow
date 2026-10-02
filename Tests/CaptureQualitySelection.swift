// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
@testable import SwiftyCrow

// MARK: - CaptureQualityCase

struct CaptureQualityCase: Decodable {
  var id: String
  var source: String
  var structure: String?
  var requiredText: [String]?
  var requiredWords: [String]?
  var originalLanguage: String?
  var sourceLanguage: String?
  var targetLanguage: String?
  var translationStrategy: TranslationStrategy?
  var minimumFontRatio: CGFloat?
  var protectedRectangles: [[Double]]?
  var requiredParagraphs: [String]?
  var requiredTranslatedText: [String]?
  var requiredStyles: [CaptureStyleExpectation]?
  var textAvoidanceRegions: [[Double]]?
  var requiredLiteralText: [String]?
  var requiredProseText: [String]?
  var requiredAlignments: [CaptureAlignmentExpectation]?
  var requiredFontScales: [CaptureFontExpectation]?
  var requiredLineCounts: [CaptureLineCountExpectation]?
  var requiredTranslations: [CaptureTranslationExpectation]?
  var requiredRestoredBackgrounds: [CaptureBackgroundExpectation]?
  var maximumReviewLines: Int?
  var requiredSourceFragments: [CaptureSourceFragmentExpectation]?
  var requiredSourceOccurrences: [String: Int]?
  var forbiddenSourceText: [String]?
}

// MARK: - CaptureSourceFragmentExpectation

struct CaptureSourceFragmentExpectation: Decodable {
  var sourcePrefix: String
  /// Required original glyph extent in normalized source-image coordinates.
  var region: [Double]
}

// MARK: - CaptureBackgroundExpectation

struct CaptureBackgroundExpectation: Decodable {
  var region: [Int]
  var color: [Int]
  var maximumChannelError: Int
}

// MARK: - CaptureTranslationExpectation

struct CaptureTranslationExpectation: Decodable {
  var sourcePrefix: String
  var targetIncludes: [String]
  var targetExcludes: [String]
}

// MARK: - CaptureLineCountExpectation

struct CaptureLineCountExpectation: Decodable {
  var source: String
  var maximum: Int
}

// MARK: - CaptureFontExpectation

struct CaptureFontExpectation: Decodable {
  var source: String
  var minimum: CGFloat
  var maximum: CGFloat
  var sourceIsExact: Bool?
}

// MARK: - CaptureAlignmentExpectation

struct CaptureAlignmentExpectation: Decodable {
  var source: String
  var alignment: String
}

// MARK: - CaptureStyleExpectation

struct CaptureStyleExpectation: Decodable {
  var source: String
  var target: String
  var kind: String
  var sourceIsExact: Bool?
}

// MARK: - CaptureQualitySelection

/// One selection contract for Xcode tests and the standalone VM runner.
/// Misspelled filters and empty manifests fail instead of reporting a false pass.
enum CaptureQualitySelection {
  enum SelectionError: Error { case duplicateIDs, emptySelection, invalidID }

  static func load(
    root: URL,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> [CaptureQualityCase] {
    let manifest = environment["SWIFTYCROW_QUALITY_MANIFEST"] ?? "corpus.json"
    let cases = try JSONDecoder().decode(
      [CaptureQualityCase].self,
      from: Data(contentsOf: root.appendingPathComponent(manifest))
    )
    return try select(cases, environment: environment)
  }

  static func select(_ cases: [CaptureQualityCase], environment: [String: String]) throws -> [CaptureQualityCase] {
    guard
      cases.allSatisfy({ !$0.id.isEmpty && $0.id != "." && $0.id != ".." &&
          $0.id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
      })
    else { throw SelectionError.invalidID }
    guard Set(cases.map(\.id)).count == cases.count else { throw SelectionError.duplicateIDs }
    guard
      cases.allSatisfy({ item in
        (item.requiredSourceOccurrences ?? [:]).allSatisfy { !$0.key.isEmpty && $0.value > 0 }
          && (item.forbiddenSourceText ?? []).allSatisfy { !$0.isEmpty }
          && (item.requiredStyles ?? []).allSatisfy {
            ["color", "weight", "plain", "italic", "upright"].contains($0.kind)
          }
      })
    else { throw CocoaError(.coderInvalidValue) }
    let filters: [(String, (CaptureQualityCase) -> String?)] = [
      ("SWIFTYCROW_QUALITY_CASE", { $0.id }),
      ("SWIFTYCROW_QUALITY_STRUCTURE", { $0.structure }),
      ("SWIFTYCROW_QUALITY_SOURCE", { $0.originalLanguage }),
      ("SWIFTYCROW_QUALITY_TARGET", { $0.targetLanguage }),
    ]
    let selected = cases.filter { item in
      filters.allSatisfy { key, value in environment[key].map { $0 == value(item) } ?? true }
    }
    guard !selected.isEmpty else { throw SelectionError.emptySelection }
    return selected
  }

}
