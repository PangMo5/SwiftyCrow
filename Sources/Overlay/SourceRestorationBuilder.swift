// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Extends masks to observed ink, not an arbitrary larger rectangle. On textured
/// surfaces, replace only glyph pixels using nearby background samples while
/// retaining the actual surrounding pixels in a local restoration tile.
enum SourceRestorationBuilder {

  // MARK: Internal

  static func applying(to result: OCRResult, image: CGImage) -> OCRResult {
    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return result }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { return result }
    defer { withExtendedLifetime(context) { } }
    let pixels = data.bindMemory(to: UInt8.self, capacity: image.width * image.height * 4)
    func color(_ x: Int, _ y: Int) -> Pixel {
      let i = (y * image.width + x) * 4
      return Pixel(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
    }
    var result = result
    for i in result.lines.indices {
      if Task.isCancelled { break }
      let line = result.lines[i]
      guard !OCRTextSemantics.isCode(line.text), !OCRTextSemantics.isIdentifier(line.text) else { continue }
      let bounds = line.boundingBoxNormalized
      var samples = [Int]()
      for y in [Int(bounds.minY * CGFloat(image.height)) - 2, Int(bounds.maxY * CGFloat(image.height)) + 2]
        where y >= 0 && y < image.height
      {
        for x in stride(
          from: max(0, Int(bounds.minX * CGFloat(image.width))),
          to: min(image.width, Int(bounds.maxX * CGFloat(image.width))),
          by: 3
        ) {
          samples.append(color(x, y).luminance)
        }
      }
      samples.sort()
      var histogram = [Int: Int]()
      for sample in samples { histogram[sample / 12, default: 0] += 1 }
      let textured = samples.count >= 30 && samples[samples.count * 9 / 10] - samples[samples.count / 10] > 24
        && histogram.values.count(where: { $0 * 20 >= samples.count }) >= 3
      if textured {
        // Background variation is not an inline badge/code style. Keeping
        // those false style spans would repaint blocks over the restored tile.
        result.lines[i].styleRuns = line.styleRuns.map { run in
          var run = run
          run.appearance.background = line.appearance.background
          return run
        }
      }
      let patches = textured
        ? [OverlaySourcePatch(box: line.boundingBoxNormalized, appearance: line.appearance)]
        : line.replacementPatches
      result.lines[i].replacementPatches = patches
      for j in patches.indices {
        var patch = patches[j]
        guard !patch.erasesDistinctSurface || textured else { continue }
        if textured { patch.erasesDistinctSurface = false }
        let fg = components(patch.appearance.foreground)
        let bg = components(patch.appearance.background)
        let contrast = distance(fg, bg)
        guard contrast >= 30 else { continue }
        let box = patch.box
        let original = CGRect(
          x: box.minX * CGFloat(image.width),
          y: box.minY * CGFloat(image.height),
          width: box.width * CGFloat(image.width),
          height: box.height * CGFloat(image.height)
        ).integral
        let margin = max(2, min(8, Int(original.height * 0.15)))
        let rect = original.insetBy(dx: -CGFloat(margin), dy: -CGFloat(margin)).intersection(CGRect(
          x: 0,
          y: 0,
          width: image.width,
          height: image.height
        )).integral
        let x0 = Int(rect.minX)
        let y0 = Int(rect.minY)
        let w = Int(rect.width)
        let h = Int(rect.height)
        guard w > 0, h > 0 else { continue }
        var ink = [Bool](repeating: false, count: w * h)
        var queue = [Int]()
        for y in 0..<h {
          for x in 0..<w {
            let c = color(x0 + x, y0 + y)
            if
              original.insetBy(dx: 0, dy: -CGFloat(margin)).contains(CGPoint(x: x0 + x, y: y0 + y)),
              distance(c, fg) < contrast / 2
            {
              ink[y * w + x] = true
              queue.append(y * w + x)
            }
          }
        }
        guard !queue.isEmpty else { continue }
        var cursor = 0
        while cursor < queue.count {
          let k = queue[cursor]
          cursor += 1
          let x = k % w
          let y = k / w
          for ny in max(0, y - 1)...min(h - 1, y + 1) {
            for nx in max(0, x - 1)...min(w - 1, x + 1) {
              let next = ny * w + nx
              guard !ink[next] else { continue }
              let c = color(x0 + nx, y0 + ny)
              guard distance(c, bg) >= max(8, contrast / 8), distance(c, fg) < distance(c, bg) else { continue }
              ink[next] = true
              queue.append(next)
            }
          }
        }
        var minX = original.minX
        var minY = original.minY
        var maxX = original.maxX
        var maxY = original.maxY
        for k in queue {
          minX = min(minX, CGFloat(x0 + k % w))
          minY = min(minY, CGFloat(y0 + k / w))
          maxX = max(maxX, CGFloat(x0 + k % w + 1))
          maxY = max(maxY, CGFloat(y0 + k / w + 1))
        }
        patch.box = CGRect(
          x: minX / CGFloat(image.width),
          y: minY / CGFloat(image.height),
          width: (maxX - minX) / CGFloat(image.width),
          height: (maxY - minY) / CGFloat(image.height)
        )
        // The spread of non-glyph pixels distinguishes texture from a flat
        // surface. Keep the cheap color fill for ordinary UI and paper.
        var background = [Int]()
        for k in stride(from: 0, to: ink.count, by: 3) where !ink[k] {
          background.append(color(x0 + k % w, y0 + k / w).luminance)
        }
        background.sort()
        if
          textured || (background.count > 20 && background[background.count * 9 / 10] - background[background.count / 10] > 24),
          let tile = CGContext(
            data: nil,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ), let destination = tile.data
        {
          let out = destination.bindMemory(to: UInt8.self, capacity: w * h * 4)
          let originalInk = ink
          for k in originalInk.indices where originalInk[k] {
            let x = k % w
            let y = k / w
            for ny in max(0, y - 1)...min(h - 1, y + 1) {
              for nx in max(0, x - 1)...min(w - 1, x + 1) { ink[ny * w + nx] = true }
            }
          }
          for k in ink.indices {
            let x = k % w
            let y = k / w
            var sample = color(x0 + x, y0 + y)
            if ink[k] {
              search: for radius in 1...max(w, h) {
                for (nx, ny) in [(x - radius, y), (x + radius, y), (x, y - radius), (x, y + radius)] {
                  if nx >= 0, nx < w, ny >= 0, ny < h, !ink[ny * w + nx] {
                    sample = color(x0 + nx, y0 + ny)
                    break search
                  }
                }
              }
            }
            out[k * 4] = UInt8(sample.r)
            out[k * 4 + 1] = UInt8(sample.g)
            out[k * 4 + 2] = UInt8(sample.b)
            out[k * 4 + 3] = 255
          }
          patch.box = CGRect(
            x: rect.minX / CGFloat(image.width),
            y: rect.minY / CGFloat(image.height),
            width: rect.width / CGFloat(image.width),
            height: rect.height / CGFloat(image.height)
          )
          patch.restorationPNG = tile.makeImage()?.pngData
        }
        result.lines[i].replacementPatches[j] = patch
      }
    }
    return result
  }

  // MARK: Private

  private struct Pixel {
    var r: Int
    var g: Int
    var b: Int

    var luminance: Int {
      (r + g + b) / 3
    }
  }

  private static func components(_ c: OverlayColor) -> Pixel {
    Pixel(
      r: Int(c.red * 255),
      g: Int(c.green * 255),
      b: Int(c.blue * 255)
    )
  }

  private static func distance(_ a: Pixel, _ b: Pixel) -> Int {
    max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
  }
}
