// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import FoundationModels
import Testing
import Translation
@testable import SwiftyCrow

struct TranslationModelResolverTests {
  @Test(arguments: [
    SystemLanguageModel.Availability.UnavailableReason.deviceNotEligible,
    .appleIntelligenceNotEnabled,
    .modelNotReady,
  ])
  func installedTraditionalModelsCannotAuthorizeHighFidelity(_ reason: SystemLanguageModel.Availability.UnavailableReason) {
    #expect(throws: TranslationModelResolver.ModelError.self) {
      try TranslationModelResolver.validateAppleIntelligence(.unavailable(reason))
    }
  }

  @Test
  func readyAppleIntelligencePassesTheDevicePreflight() throws {
    try TranslationModelResolver.validateAppleIntelligence(.available)
  }

  @Test
  func onlyModelErrorsBecomeDownloadOrUnsupportedGuidance() {
    let source = Locale.Language(identifier: "ko")
    let target = Locale.Language(identifier: "en")
    #expect(TranslationModelResolver
      .explaining(TranslationError.notInstalled, source: source, target: target) is TranslationModelResolver.ModelError)
    #expect(TranslationModelResolver
      .explaining(TranslationError.unsupportedLanguagePairing, source: source, target: target) is TranslationModelResolver
      .ModelError)
    let unrelated = NSError(domain: "CaptureAudit", code: 41)
    let preserved = TranslationModelResolver.explaining(unrelated, source: source, target: target) as NSError
    #expect(preserved.domain == unrelated.domain && preserved.code == unrelated.code)
    #expect(TranslationModelResolver.explaining(CancellationError(), source: source, target: target) is CancellationError)
  }
}
