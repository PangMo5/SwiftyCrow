// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - CaptureDeadline

/// Time budgets for the capture pipeline's calls into system daemons.
///
/// These are stall detectors, not latency targets. The slow legitimate case is
/// the first use after an idle period, when `replayd` and the translation
/// service aren't running and have to be launched (and a translation model may
/// have to be paged back in); the budgets leave room for that and nothing more.
enum CaptureDeadline {
  /// Bounds the complete OCR pipeline, including system recognition, region
  /// refinement, appearance analysis, and source restoration. This is not a
  /// model-loading measurement or an expected duration for ordinary captures.
  static let ocr = Duration.seconds(120)
  static let screenCapture = Duration.seconds(6)
  /// A batch streams its responses, so this bounds the whole batch rather than
  /// any single line.
  static let translationBatch = Duration.seconds(45)
}

// MARK: - DeadlineStage

/// Which pipeline stage a deadline belongs to — names the stall in both the
/// user-facing message and the log.
enum DeadlineStage: String, Sendable {
  case ocr = "Text recognition"
  case screenCapture = "Screen capture"
  case translation = "Translation"
}

// MARK: - DeadlineExceededError

struct DeadlineExceededError: Error, LocalizedError, Equatable {
  var stage: DeadlineStage

  var errorDescription: String? {
    switch stage {
    case .ocr: String(localized: "Text recognition didn't respond in time.")
    case .screenCapture: String(localized: "Screen capture didn't respond in time.")
    case .translation: String(localized: "Translation didn't respond in time.")
    }
  }
}

// MARK: - withDeadline

/// Runs `operation` with a hard deadline, **abandoning** it once the deadline
/// passes instead of waiting for it to unwind.
///
/// Abandoning is the point, and it's why this isn't a task group: a group waits
/// for every child before returning, so a child parked inside ScreenCaptureKit /
/// Vision / Translation would hold the group open and the deadline would never
/// actually fire. Those frameworks talk to on-demand system daemons and don't
/// reliably honour cancellation, so refusing to keep waiting is the only bound
/// available. The abandoned task is cancelled and whatever it eventually
/// produces is dropped.
func withDeadline<T: Sendable>(
  _ duration: Duration,
  stage: DeadlineStage,
  clock: any Clock<Duration>,
  operation: @Sendable @escaping () async throws -> T
) async throws -> T {
  // Whichever task finishes the stream first wins; the loser's call is a no-op.
  let (outcome, continuation) = AsyncThrowingStream<T, any Error>.makeStream(
    bufferingPolicy: .bufferingOldest(1)
  )
  let work = Task {
    do {
      continuation.yield(try await operation())
      continuation.finish()
    } catch {
      continuation.finish(throwing: error)
    }
  }
  let timer = Task {
    try? await clock.sleep(for: duration)
    continuation.finish(throwing: DeadlineExceededError(stage: stage))
  }
  defer {
    work.cancel()
    timer.cancel()
  }
  var iterator = outcome.makeAsyncIterator()
  // The stream also finishes when *this* task is cancelled, which is the nil
  // case — the deferred cancels then tear both children down.
  guard let value = try await iterator.next() else {
    throw CancellationError()
  }
  return value
}
