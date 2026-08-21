// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import os

// MARK: - Log

/// Shared log handles, so the subsystem string lives in one place.
///
/// The capture pipeline calls into three on-demand system daemons
/// (ScreenCaptureKit's `replayd`, Vision, and the Translation service). When one
/// of them stalls there is nothing on screen but a spinner, so each stage logs
/// its own outcome — that's the only way to tell afterwards which stage stalled.
enum Log {
  static let capture = Logger(subsystem: subsystem, category: "Capture")
  static let loginItem = Logger(subsystem: subsystem, category: "LoginItem")
  static let ocr = Logger(subsystem: subsystem, category: "OCR")
  static let translation = Logger(subsystem: subsystem, category: "Translation")

  private static let subsystem = "dev.PangMo5.SwiftyCrow"
}

// MARK: - Duration

extension Duration {
  /// Seconds to two decimals — `Duration`'s own description is too noisy to scan
  /// in a log line.
  var loggedSeconds: String {
    let total = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return String(format: "%.2f", total)
  }
}
