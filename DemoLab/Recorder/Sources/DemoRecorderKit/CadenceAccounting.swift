// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

/// A presentation slot is reserved exactly once, even if encoding rejects it.
/// Startup waits do not reserve slots because the movie clock has not started.
struct CadenceAccounting: Sendable {
  private(set) var nextFrameIndex = 0
  private(set) var skippedFrameCount = 0
  private(set) var rejectedFrameCount = 0
  var droppedFrameCount: Int { skippedFrameCount + rejectedFrameCount }

  mutating func reserve(elapsed: Double, fps: Int) -> Int {
    let target = max(nextFrameIndex, Int((elapsed * Double(fps)).rounded()))
    skippedFrameCount += target - nextFrameIndex
    nextFrameIndex = target + 1
    return target
  }

  mutating func rejectReservedFrame() {
    rejectedFrameCount += 1
  }
}
