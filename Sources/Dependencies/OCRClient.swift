// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import DependenciesMacros

// MARK: - OCRClient

@DependencyClient
struct OCRClient {
  var recognizeText: @Sendable (_ image: CGImage, _ language: Language) async throws -> OCRResult
  /// Publishes final text/geometry before raster restoration finishes. The
  /// callback must not render these provisional source masks.
  var recognizeCapture: @Sendable (
    _ image: CGImage,
    _ language: Language,
    _ textReady: @Sendable (OCRResult) async -> Void
  ) async throws -> OCRResult
}

// MARK: DependencyKey

extension OCRClient: DependencyKey {
  static let liveValue = OCRClient(
    recognizeText: { image, language in try await OCRPipeline.recognize(image, language: language) },
    recognizeCapture: { image, language, textReady in
      try await OCRPipeline.recognize(image, language: language, textReady: textReady)
    }
  )
}

extension DependencyValues {
  var ocr: OCRClient {
    get { self[OCRClient.self] }
    set { self[OCRClient.self] = newValue }
  }
}
