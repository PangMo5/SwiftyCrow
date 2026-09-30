// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Retained source layout constraints")
struct OverlayLayoutExclusionsTests {
  @Test
  func compressedGeometryMatchesAnExhaustiveWeightedGridOracle() {
    let xs: [CGFloat] = [0, 17, 48, 100]
    let ys: [CGFloat] = [0, 13, 34, 60]
    let frame = CGRect(x: 0, y: 0, width: 100, height: 60)
    var cells = [CGRect]()
    for row in 0..<3 {
      for column in 0..<3 {
        let width = xs[column + 1] - xs[column]
        let height = ys[row + 1] - ys[row]
        cells.append(CGRect(x: xs[column], y: ys[row], width: width, height: height))
      }
    }
    for mask in 0..<512 {
      let blocked = cells.indices.filter { mask & (1 << $0) != 0 }.map { cells[$0] }
      let free = cells.indices.filter { mask & (1 << $0) == 0 }.map { cells[$0] }
      var expected: CGFloat = 0
      for top in 0..<3 {
        for bottom in (top + 1)...3 {
          for left in 0..<3 {
            for right in (left + 1)...3 {
              let clear = (top..<bottom).allSatisfy { y in
                (left..<right).allSatisfy { x in mask & (1 << (y * 3 + x)) == 0 }
              }
              if clear { expected = max(expected, (xs[right] - xs[left]) * (ys[bottom] - ys[top])) }
            }
          }
        }
      }
      for positive in [false, true] {
        let permitted = free.isEmpty ? [CGRect(x: 200, y: 200, width: 1, height: 1)] : free
        let actual = OverlayLayoutExclusions.largestRectangle(
          in: frame,
          excluding: positive ? [] : blocked,
          allowed: positive ? permitted : [],
          alignment: .leading
        )
        #expect(abs((actual.map { $0.width * $0.height } ?? 0) - expected) < 0.000_001, "mask=\(mask), positive=\(positive)")
        if let actual {
          #expect(frame.contains(actual))
          #expect(blocked.allSatisfy { !actual.intersects($0) })
        }
      }
    }
  }

  @Test
  func aBottomIntrusionKeepsTheFullWidthAboveIt() {
    let frame = CGRect(x: 0, y: 0, width: 100, height: 60)
    #expect(OverlayLayoutExclusions.largestRectangle(
      in: frame,
      excluding: [CGRect(x: 30, y: 50, width: 50, height: 10)],
      alignment: .leading
    ) == CGRect(x: 0, y: 0, width: 100, height: 50))
    #expect(OverlayLayoutExclusions.largestRectangle(in: frame, excluding: [frame], alignment: .center) == nil)
  }

  @Test
  func existingParagraphCorridorsRemainHardConstraints() {
    let result = OverlayLayoutExclusions.largestRectangle(
      in: CGRect(x: 0, y: 0, width: 100, height: 60),
      excluding: [CGRect(x: 50, y: 40, width: 20, height: 20)],
      allowed: [CGRect(x: 0, y: 0, width: 60, height: 30), CGRect(x: 0, y: 30, width: 100, height: 30)],
      alignment: .leading
    )
    #expect(result == CGRect(x: 0, y: 0, width: 50, height: 60))
  }

  @Test(arguments: [0.5, 1.0, 2.0], [CGPoint.zero, CGPoint(x: 503, y: 700)])
  func layoutConstraintsRetainPhysicalScaleAndContext(_ scale: CGFloat, _ offset: CGPoint) throws {
    let transform = CGAffineTransform(translationX: offset.x, y: offset.y).scaledBy(x: scale, y: scale)
    let frame = CGRect(x: 97.6446287556, y: 954.5, width: 126.363636, height: 63.25)
    let obstruction = CGRect(x: 136, y: 1008, width: 36, height: 10)
    let expected = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 1008 - frame.minY).applying(transform)
    let actual = try #require(OverlayLayoutExclusions.largestRectangle(
      in: frame.applying(transform),
      excluding: [obstruction.applying(transform)],
      alignment: .leading
    ))
    #expect(abs(actual.minX - expected.minX) < 0.000_001)
    #expect(abs(actual.minY - expected.minY) < 0.000_001)
    #expect(abs(actual.width - expected.width) < 0.000_001)
    #expect(abs(actual.height - expected.height) < 0.000_001)
  }

  @MainActor
  @Test(arguments: [("ko", "히!"), ("en", "Hi!"), ("ar", "مرحبا"), ("zh-Hans", "嗨！")], [-0.25, 0, 0.25])
  func translatedInkDoesNotPaintRetainedArtwork(_ sample: (String, String), _ angle: CGFloat) throws {
    let size = CGSize(width: 200, height: 160)
    let artwork = CGRect(x: 70, y: 100, width: 50, height: 12)
    var pixels = [UInt8](repeating: 255, count: 200 * 160 * 4)
    for y in 100..<112 {
      for x in 70..<120 {
        for channel in 0..<3 { pixels[(y * 200 + x) * 4 + channel] = 0 }
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let original = try #require(CGImage(
      width: 200,
      height: 160,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      bytesPerRow: 800,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
      provider: provider,
      decode: nil,
      shouldInterpolate: false,
      intent: .defaultIntent
    ))
    let box = CGRect(x: 0.2, y: 0.2, width: 0.55, height: 0.5)
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .init(red: 1, green: 0, blue: 1, alpha: 1),
      confidence: 1,
      fontSizeScale: 0.48,
      fontWeight: .bold
    )
    var transparent = appearance
    transparent.background.alpha = 0
    var recognized = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Original",
      rotationRadians: angle,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: transparent)]
    )
    let obstacle = artwork.insetBy(dx: -1, dy: -1)
    recognized.layoutExclusions = [CGRect(
      x: obstacle.minX / size.width,
      y: obstacle.minY / size.height,
      width: obstacle.width / size.width,
      height: obstacle.height / size.height
    )]
    var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "ja")))
    line.showTranslation(sample.1, language: .init(identifier: sample.0))
    let placements = OverlayLayoutEngine.placements(for: [line], in: size)
    let placement = try #require(placements.first)
    #expect(placement.fontSize >= 24)
    #expect(HorizontalTextRenderer.plan(for: placement).fits(placement.frame.size))
    let rendered = try #require(CaptureResultImage.render(imageData: original.pngData, imageSize: size, lines: [line]))
    let protected = CGRect(
      x: artwork.minX / size.width,
      y: artwork.minY / size.height,
      width: artwork.width / size.width,
      height: artwork.height / size.height
    )
    #expect(CaptureQualityMetrics.protectedPixelChanges(original: original, rendered: rendered, rectangles: [protected]) == 0)
    if sample.0 == "ko", angle == 0 {
      line.source.layoutExclusions = []
      let unconstrained = try #require(CaptureResultImage.render(imageData: original.pngData, imageSize: size, lines: [line]))
      #expect(CaptureQualityMetrics
        .protectedPixelChanges(original: original, rendered: unconstrained, rectangles: [protected]) > 0)
    }
  }
}
