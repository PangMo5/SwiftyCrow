// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
@testable import SwiftyCrow

/// Opt-in, one-entry cache for a native language matrix. OCR depends on the exact
/// image and source hint, never the target. No disk persistence or error caching.
struct CaptureQualityRecognitionCache {
  func lookup(data: Data, language: String) -> OCRResult? {
    guard let entry, entry.data == data, entry.language == language else { return nil }
    return entry.result
  }

  mutating func store(_ result: OCRResult, data: Data, language: String) {
    entry = (data, language, result)
  }

  private var entry: (data: Data, language: String, result: OCRResult)?

}
