// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ConcurrencyExtras
import Foundation
import Testing
@testable import SwiftyCrow

struct OCRPreparationTests {
  @Test
  func startupAndForegroundShareOnePreparation() async throws {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let calls = LockIsolated(0)
    let preparation = OCRPreparation {
      calls.withValue { $0 += 1 }
      started.continuation.yield(())
      for await _ in release.stream { break }
    }
    await preparation.start()
    for await _ in started.stream { break }
    await preparation.start()
    async let first: Void = preparation.beginRecognition()
    async let second: Void = preparation.beginRecognition()
    release.continuation.yield(())
    try await first
    try await second
    await preparation.start()
    #expect(calls.value == 1)
  }

  @Test
  func foregroundBeforeStartupDoesNotAddASecondRecognition() async throws {
    let calls = LockIsolated(0)
    let preparation = OCRPreparation { calls.withValue { $0 += 1 } }
    try await preparation.beginRecognition()
    await preparation.start()
    #expect(calls.value == 0)
  }
}
