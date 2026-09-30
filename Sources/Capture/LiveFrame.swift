// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CryptoKit
import Foundation

/// Exact pixel identity schedules OCR even for a small change. OCR determines
/// whether the source text changed before replacing its displayed translation.
struct LiveFrame: Equatable, Sendable {

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
    bytes.withUnsafeBytes { buffer in
      for row in 0..<image.height {
        let start = row * image.bytesPerRow
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[start..<(start + rowLength)]))
      }
    }
    pixelData = bytes
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

  struct Witness: Equatable, Sendable {
    var bounds: CGRect
    var digest: Data
    var width: Int
    var height: Int
    var bitsPerPixel: Int
    var bitmapInfo: UInt32
  }

  let backdrop: OverlayBackdrop
  let signature: Signature

  var imageSize: CGSize {
    CGSize(width: signature.width, height: signature.height)
  }

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.signature == rhs.signature
  }

  func witness(for source: OverlayLine.Source) -> Witness? {
    var bounds = (source.layoutBounds ?? source.box).union(source.box)
    for patch in source.replacementPatches {
      let frame = OverlayLayoutEngine.replacementFrame(
        for: patch,
        sourceLayout: source.layout,
        sourceSurface: source.surface,
        in: imageSize,
        displayScale: 1
      )
      bounds = bounds.union(CGRect(
        x: frame.minX / imageSize.width,
        y: frame.minY / imageSize.height,
        width: frame.width / imageSize.width,
        height: frame.height / imageSize.height
      ))
    }
    if let surface = source.surface { bounds = bounds.union(surface.clippingBox ?? surface.box) }
    return witness(for: bounds)
  }

  /// Exact pixels for the region we may erase or occupy. A witness belongs to
  /// the recognition frame, never to a later frame with coincidentally equal text.
  func witness(for bounds: CGRect) -> Witness? {
    guard signature.bitsPerPixel % 8 == 0 else { return nil }
    let rect = CGRect(
      x: bounds.minX * imageSize.width,
      y: bounds.minY * imageSize.height,
      width: bounds.width * imageSize.width,
      height: bounds.height * imageSize.height
    )
    .insetBy(dx: -2, dy: -2).integral.intersection(CGRect(origin: .zero, size: imageSize))
    guard !rect.isNull, !rect.isEmpty else { return nil }
    let bytesPerPixel = signature.bitsPerPixel / 8
    let rowBytes = backdrop.image.bytesPerRow
    var hasher = SHA256()
    pixelData.withUnsafeBytes { buffer in
      for y in Int(rect.minY)..<Int(rect.maxY) {
        let start = y * rowBytes + Int(rect.minX) * bytesPerPixel
        let end = start + Int(rect.width) * bytesPerPixel
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[start..<end]))
      }
    }
    return Witness(
      bounds: bounds,
      digest: Data(hasher.finalize()),
      width: signature.width,
      height: signature.height,
      bitsPerPixel: signature.bitsPerPixel,
      bitmapInfo: signature.bitmapInfo
    )
  }

  func matches(_ witness: Witness) -> Bool {
    self.witness(for: witness.bounds) == witness
  }

  // MARK: Private

  private let pixelData: Data

}
