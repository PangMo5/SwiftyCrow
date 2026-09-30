// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct LiveSourceIdentityTests {
  @Test
  func identicalPixelsCannotAcquireADifferentCharacterOrFont() {
    let old = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.6, height: 0.05), text: "更新過程中請勿中斷裝置連線。"),
      language: Locale.Language(identifier: "zh-Hant")
    )
    let line = OverlayLine(id: UUID(), source: old)
    var noisy = old
    noisy.text = "更新過程申請勿中斷裝置連線。"
    noisy.appearance.fontSizeScale = 0.5
    #expect(LiveSourceIdentity.sources(
      [noisy],
      previous: [line],
      verifiedBounds: [line.id: CGRect(x: 0, y: 0, width: 1, height: 1)]
    ) == [old])
    #expect(LiveSourceIdentity.sources([noisy], previous: [line], verifiedBounds: [:]) == [noisy])
    var changedLanguage = noisy
    changedLanguage.language = Locale.Language(identifier: "ja")
    #expect(LiveSourceIdentity
      .sources([changedLanguage], previous: [line], verifiedBounds: [line.id: old.box]) == [changedLanguage])
    var outside = noisy
    outside.box.origin.x -= 0.01
    #expect(LiveSourceIdentity.sources([outside], previous: [line], verifiedBounds: [line.id: old.box]) == [outside])
    #expect(LiveSourceIdentity.sources([], previous: [line], verifiedBounds: [line.id: old.box]) == [old])
  }
}
