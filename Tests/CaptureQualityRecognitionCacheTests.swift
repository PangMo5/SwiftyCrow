// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct CaptureQualityRecognitionCacheTests {
  @Test
  func reuseRequiresIdenticalPixelsAndSourceHintAndKeepsOnlyOneImage() {
    var cache = CaptureQualityRecognitionCache()
    let result = OCRResult(lines: [.init(boundingBoxNormalized: .zero, text: "原文")])
    let image = Data([1, 2, 3])
    #expect(cache.lookup(data: image, language: "auto") == nil)
    cache.store(result, data: image, language: "auto")
    #expect(cache.lookup(data: image, language: "auto") == result)
    #expect(cache.lookup(data: Data([1, 2, 4]), language: "auto") == nil)
    #expect(cache.lookup(data: image, language: "ja") == nil)
    cache.store(result, data: Data([4]), language: "auto")
    #expect(cache.lookup(data: image, language: "auto") == nil)
  }
}
