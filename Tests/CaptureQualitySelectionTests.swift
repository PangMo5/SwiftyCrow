// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct CaptureQualitySelectionTests {
  let cases = [
    CaptureQualityCase(id: "ja-card-ko", source: "ja.png", structure: "cards", originalLanguage: "ja", targetLanguage: "ko"),
    CaptureQualityCase(id: "ar-table-ja", source: "ar.png", structure: "table", originalLanguage: "ar", targetLanguage: "ja"),
  ]

  @Test
  func strategyIsExplicitAndUnknownValuesDoNotDowngradeTheRun() throws {
    let data = Data(#"{"id":"high","source":"input.png","translationStrategy":"highFidelity"}"#.utf8)
    #expect(try JSONDecoder().decode(CaptureQualityCase.self, from: data).translationStrategy == .highFidelity)
    let invalid = Data(#"{"id":"bad","source":"input.png","translationStrategy":"highFidelty"}"#.utf8)
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(CaptureQualityCase.self, from: invalid) }
  }

  @Test(arguments: [
    ("SWIFTYCROW_QUALITY_CASE", "ja-card-ko", "ja-card-ko"),
    ("SWIFTYCROW_QUALITY_SOURCE", "ar", "ar-table-ja"),
    ("SWIFTYCROW_QUALITY_TARGET", "ko", "ja-card-ko"),
    ("SWIFTYCROW_QUALITY_STRUCTURE", "table", "ar-table-ja"),
  ])
  func exactSelection(_ input: (String, String, String)) throws {
    #expect(try CaptureQualitySelection.select(cases, environment: [input.0: input.1]).map(\.id) == [input.2])
  }

  @Test
  func invalidSelectionsFailInsteadOfPassingWithoutTests() {
    #expect(throws: CaptureQualitySelection.SelectionError.self) {
      try CaptureQualitySelection.select(cases, environment: ["SWIFTYCROW_QUALITY_CASE": "typo"])
    }
    #expect(throws: CaptureQualitySelection.SelectionError.self) {
      try CaptureQualitySelection.select(
        cases,
        environment: ["SWIFTYCROW_QUALITY_SOURCE": "ar", "SWIFTYCROW_QUALITY_TARGET": "ko"]
      )
    }
    #expect(throws: CaptureQualitySelection.SelectionError.self) {
      try CaptureQualitySelection.select([], environment: [:])
    }
    #expect(throws: CaptureQualitySelection.SelectionError.self) {
      try CaptureQualitySelection.select(cases + cases, environment: [:])
    }
  }

  @Test(arguments: ["", "..", "../outside", "nested/case"])
  func outputIDsCannotEscapeTheirArtifactDirectory(_ id: String) {
    #expect(throws: CaptureQualitySelection.SelectionError.self) {
      try CaptureQualitySelection.select([CaptureQualityCase(id: id, source: "source.png")], environment: [:])
    }
  }

  @Test @MainActor
  func failedRerunCannotKeepAnOldSuccessfulReport() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let output = root.appendingPathComponent("output")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    try Data("old success".utf8).write(to: output.appendingPathComponent("broken-metrics.json"))
    try Data("old image".utf8).write(to: output.appendingPathComponent("broken-result.png"))
    try Data("not a PNG".utf8).write(to: root.appendingPathComponent("broken.png"))
    await #expect(throws: (any Error).self) {
      try await CaptureQualityRunner().run(.init(id: "broken", source: "broken.png"), root: root, output: output)
    }
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("broken-metrics.json").path))
    #expect(!FileManager.default.fileExists(atPath: output.appendingPathComponent("broken-result.png").path))
  }

}
