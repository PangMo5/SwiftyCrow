// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SWIFTYCROW_LIVE_QUALITY_ROOT"] != nil))
@MainActor
struct LiveCaptureQualityProbeTests {
  @Test
  func nativeLiveSequences() async throws {
    let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SWIFTYCROW_LIVE_QUALITY_ROOT"]))
    let failures = try await LiveCaptureQualityRunner.run(
      root: root,
      sourceLanguage: ProcessInfo.processInfo
        .environment["SWIFTYCROW_LIVE_QUALITY_LANGUAGE"]
    )
    #expect(failures == 0)
  }
}
