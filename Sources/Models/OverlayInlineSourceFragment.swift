// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// A capture-owned literal whose two-dimensional glyph arrangement cannot be
/// represented faithfully by the OCR transcript. Immutable RGBA samples avoid
/// decoding an image during repeated fitting passes.
struct OverlayInlineSourceFragment: Equatable, Hashable, Sendable {

  // MARK: Lifecycle

  init?(pixels: Data, width: Int, height: Int, descent: CGFloat, referenceFontSize: CGFloat) {
    guard
      width > 0, height > 0, width <= Int.max / 4 / height,
      pixels.count == width * height * 4,
      descent.isFinite, descent >= 0, descent <= CGFloat(height),
      referenceFontSize.isFinite, referenceFontSize > 0
    else { return nil }
    self.pixels = pixels
    self.width = width
    self.height = height
    self.descent = descent
    self.referenceFontSize = referenceFontSize
  }

  // MARK: Internal

  let pixels: Data
  let width: Int
  let height: Int
  let descent: CGFloat
  let referenceFontSize: CGFloat

  var image: CGImage? {
    guard
      width > 0, height > 0, width <= Int.max / 4 / height,
      pixels.count == width * height * 4,
      let provider = CGDataProvider(data: pixels as CFData)
    else { return nil }
    return CGImage(
      width: width,
      height: height,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    )
  }
}
