// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Language selection identity")
struct LanguageIdentityTests {
  @Test(arguments: [("en-US", "en-Latn-US"), ("ko-KR", "ko-Kore-KR"), ("ja-JP", "ja-Jpan-JP")])
  func shortConfigCodesMatchSystemPickerTags(short: String, expanded: String) {
    let configured = Language(code: short)
    let catalog = Language(code: expanded)
    #expect(configured == catalog)
    #expect(configured.id == catalog.id)
    #expect(Set([configured, catalog]).count == 1)
    #expect(configured.code == short)
  }

  @Test
  func distinctScriptsRegionsAndAutomaticDetectionKeepTheirIdentity() {
    #expect(Language(code: "zh-Hans") != Language(code: "zh-Hant"))
    #expect(Language(code: "en-US") != Language(code: "en-GB"))
    #expect(Language.auto != Language(code: "en-US"))
    #expect(Language.auto.id == "auto")
  }
}
