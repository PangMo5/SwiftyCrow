// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Synchronization
import Testing
@testable import SwiftyCrow

struct CaptureAnalysisExecutorTests {
  @Test(arguments: [0, 1, 3, 8])
  func longCaptureRespectsConcurrencyBudgetAndPreservesOrder(_ limit: Int) async {
    let counts = Mutex((active: 0, maximum: 0, completed: 0))
    let values = Array(0..<300)
    let result = await CaptureAnalysisExecutor.map(values, maximumConcurrency: limit) { value in
      counts.withLock { $0.active += 1
        $0.maximum = max($0.maximum, $0.active)
      }
      // Vary work across rows so completion order need not equal input order.
      let sum = (0..<(100 + value % 17)).reduce(value) { $0 &+ $1 }
      counts.withLock { $0.active -= 1
        $0.completed += 1
      }
      return (value, sum)
    }
    #expect(result.map(\.0) == values)
    #expect(result.map(\.1) == values.map { value in (0..<(100 + value % 17)).reduce(value, &+) })
    let observed = counts.withLock { $0 }
    #expect(observed.active == 0)
    #expect(observed.completed == 300)
    #expect(observed.maximum <= max(1, limit))
  }

  @Test
  func emptyAndSingleInputNeedNoWorkers() async {
    #expect(await CaptureAnalysisExecutor.map([Int]()) { $0 * 2 } == [])
    #expect(await CaptureAnalysisExecutor.map([3]) { $0 * 2 } == [6])
  }
}
