// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Testing
@testable import SwiftyCrow

struct EdgeBackgroundIndexTests {
  @Test
  func anEnclosedWhiteControlIsNotTheWhitePageBackground() throws {
    let size = 20
    var pixels = [UInt8](repeating: 255, count: size * size * 4)
    for y in 5 ... 14 {
      for x in 5 ... 14 where x == 5 || x == 14 || y == 5 || y == 14 {
        for channel in 0 ..< 3 { pixels[(y * size + x) * 4 + channel] = 0 }
      }
    }
    let index = try #require(EdgeBackgroundIndex(pixels: pixels, width: size, height: size))
    #expect(index.connected[2 * size + 2])
    #expect(!index.connected[10 * size + 10])
    #expect(!index.connected[5 * size + 5])
  }
}
