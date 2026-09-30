// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

/// Opt-in integration probe. Inputs and output stay outside the repository's fixtures.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_ROOT"] != nil))
@MainActor
struct CaptureQualityProbeTests {

  @Test
  func renderRealCaptures() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_ROOT"]))
    let run = ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_RUN"] ?? "baseline"
    let output = root.appendingPathComponent(run)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let cases = try CaptureQualitySelection.load(root: root)
    let runner = CaptureQualityRunner()
    for item in cases {
      do {
        let report = try await runner.run(item, root: root, output: output)
        #expect(report.issues.isEmpty, "\(item.id): \(report.issues)")
      } catch {
        Issue.record(error, "Capture case \(item.id) failed")
        try JSONSerialization.data(withJSONObject: ["error": String(describing: error)], options: .prettyPrinted)
          .write(to: output.appendingPathComponent("\(item.id)-failure.json"))
      }
    }
  }
}
