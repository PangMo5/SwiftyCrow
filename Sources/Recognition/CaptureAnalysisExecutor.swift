// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Bounds concurrent raster analysis for long captures while retaining source
/// order. Queued inputs are values, not hundreds of already-created child tasks.
enum CaptureAnalysisExecutor {
  @concurrent
  static func map<Element: Sendable, Output: Sendable>(
    _ elements: [Element],
    maximumConcurrency: Int = min(8, ProcessInfo.processInfo.activeProcessorCount),
    transform: @escaping @Sendable (Element) -> Output
  ) async -> [Output] {
    guard elements.count > 1 else { return elements.map(transform) }
    return await withTaskGroup(of: (Int, Output).self) { group in
      let limit = min(elements.count, max(1, maximumConcurrency))
      var next = limit
      for index in 0..<limit {
        group.addTask { (index, transform(elements[index])) }
      }
      var ordered = [Output?](repeating: nil, count: elements.count)
      while let (index, output) = await group.next() {
        ordered[index] = output
        if next < elements.count {
          let queued = next
          next += 1
          group.addTask { (queued, transform(elements[queued])) }
        }
      }
      // Each input is scheduled exactly once and all tasks are drained above.
      return ordered.map { $0! }
    }
  }
}
