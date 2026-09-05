// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CryptoKit
import Foundation

/// A captured frame can invalidate stale text before the much slower OCR stage
/// finishes. Only the digest lives in reducer state; pixels belong to the OCR
/// effect (and, in detached mode, the displayed backdrop).
struct LiveFrame: Sendable {

  // MARK: Lifecycle

  init(image: CGImage) throws {
    guard let data = image.dataProvider?.data else {
      throw ScreenCaptureError.unreadableImage
    }
    // Hash actual pixels, excluding uninitialized row padding. Exact equality
    // avoids missing small labels/scrolls that a thumbnail can erase.
    let bytes = data as Data
    let rowLength = (image.width * image.bitsPerPixel + 7) / 8
    guard rowLength <= image.bytesPerRow, bytes.count >= image.bytesPerRow * image.height else {
      throw ScreenCaptureError.unreadableImage
    }
    var hasher = SHA256()
    for row in 0..<image.height {
      let start = row * image.bytesPerRow
      hasher.update(data: bytes[start..<(start + rowLength)])
    }
    signature = Signature(
      digest: Data(hasher.finalize()),
      width: image.width,
      height: image.height,
      bitsPerPixel: image.bitsPerPixel,
      bitmapInfo: image.bitmapInfo.rawValue
    )
    backdrop = OverlayBackdrop(image: image)
  }

  // MARK: Internal

  struct Signature: Equatable, Sendable {
    var digest: Data
    var width: Int
    var height: Int
    var bitsPerPixel: Int
    var bitmapInfo: UInt32
  }

  struct Settings: Equatable, Sendable {
    init(_ settings: AppSettings) {
      source = settings.languages.source
      target = settings.languages.target
      strategy = settings.translation.strategy
      mode = settings.overlay.liveMode
    }

    var source: Language
    var target: Language
    var strategy: TranslationStrategy
    var mode: OverlayLiveMode
  }

  let backdrop: OverlayBackdrop
  let signature: Signature

  var imageSize: CGSize {
    CGSize(width: signature.width, height: signature.height)
  }
}
