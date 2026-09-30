// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// A conservative optical discriminator for short OCR hypotheses. Connected
/// strokes and enclosed counters must agree at several contrast thresholds.
/// Matching topology is evidence only when it uniquely separates the native
/// hypotheses; it is not a recognizer or a text-substitution dictionary.
enum OCRGlyphTopology {
  struct Signature: Hashable, Sendable {
    var components: Int
    var holes: Int
  }

  static func signature(image: CGImage, background: OverlayColor) -> Signature? {
    guard
      image.width > 2, image.height > 2, image.width * image.height <= 65_536,
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ),
      let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let bg = [background.red, background.green, background.blue].map { Int(($0 * 255).rounded()) }
    let contrast = (0..<image.width * image.height).map { index in
      (0..<3).map { abs(Int(bytes[index * 4 + $0]) - bg[$0]) }.max()!
    }
    guard let maximum = contrast.max(), maximum >= 64 else { return nil }
    let observations = [0.35, 0.5, 0.65].compactMap { threshold in
      signature(mask: contrast.map { Double($0) > Double(maximum) * threshold }, width: image.width, height: image.height)
    }
    guard observations.count == 3, Set(observations).count == 1 else { return nil }
    return observations.first
  }

  static func signature(mask: [Bool], width: Int, height: Int) -> Signature? {
    guard width > 2, height > 2, width <= 65_536 / height, mask.count == width * height else { return nil }
    // A clipped stroke cannot establish the number of connected components.
    guard
      (0..<width).allSatisfy({ !mask[$0] && !mask[(height - 1) * width + $0] }),
      (0..<height).allSatisfy({ !mask[$0 * width] && !mask[$0 * width + width - 1] })
    else { return nil }
    func count(ink: Bool) -> Int {
      var seen = [Bool](repeating: false, count: mask.count)
      var result = 0
      for start in mask.indices where mask[start] == ink && !seen[start] {
        seen[start] = true
        var queue = [start]
        var offset = 0
        var edge = false
        while offset < queue.count {
          let index = queue[offset]
          offset += 1
          let x = index % width
          let y = index / width
          edge = edge || x == 0 || y == 0 || x == width - 1 || y == height - 1
          for dy in -1...1 { for dx in -1...1 {
            // Eight-connected ink and four-connected paper are dual, avoiding
            // artificial holes at diagonally connected antialiased strokes.
            guard dx != 0 || dy != 0, ink || abs(dx) + abs(dy) == 1 else { continue }
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let next = ny * width + nx
            if !seen[next], mask[next] == ink { seen[next] = true
              queue.append(next)
            }
          } }
        }
        if ink || !edge { result += 1 }
      }
      return result
    }
    let components = count(ink: true)
    guard components > 0 else { return nil }
    return Signature(components: components, holes: count(ink: false))
  }
}
