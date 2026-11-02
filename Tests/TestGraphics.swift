// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Testing

enum TestGraphics {
  /// Keep optional fixture creation outside other #require expansions.
  static func sRGBColorSpace(sourceLocation: SourceLocation = #_sourceLocation) throws -> CGColorSpace {
    try #require(CGColorSpace(name: CGColorSpace.sRGB), sourceLocation: sourceLocation)
  }
}
