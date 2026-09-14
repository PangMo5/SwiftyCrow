// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
#if os(macOS)
import CoreVideo
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Decoded video review pixels")
struct VideoAuditTests {
  @Test
  func paddingDoesNotChangePixelIdentityOrColorMetrics() throws {
    func frame(padding: UInt8) throws -> DecodedPixels {
      var value: CVPixelBuffer?
      try require(
        CVPixelBufferCreate(nil, 3, 2, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess,
        "Cannot allocate test frame"
      )
      let buffer = try #require(value)
      CVPixelBufferLockBaseAddress(buffer, [])
      let base = try #require(CVPixelBufferGetBaseAddress(buffer))
      let stride = CVPixelBufferGetBytesPerRow(buffer)
      memset(base, Int32(padding), stride * 2)
      let rows: [[UInt8]] = [
        [0, 0, 0, 255, 255, 0, 255, 255, 255, 255, 255, 255],
        [255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255],
      ]
      for (row, bytes) in rows.enumerated() {
        bytes.withUnsafeBytes { memcpy(base.advanced(by: row * stride), $0.baseAddress!, bytes.count) }
      }
      CVPixelBufferUnlockBaseAddress(buffer, [])
      return try DecodedPixels(buffer)
    }
    let first = try frame(padding: 0)
    let second = try frame(padding: 91)
    #expect(first.data == second.data)
    #expect(first.data.count == 3 * 2 * 4)
    #expect(first.metrics().dark == 1)
    #expect(first.metrics().magenta == 1)
    #expect(try first.image().width == 3)
    #expect(try first.image().height == 2)
  }
}
#endif
