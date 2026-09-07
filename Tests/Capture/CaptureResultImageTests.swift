// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Testing
@testable import SwiftyCrow

@Suite("Capture image export")
@MainActor
struct CaptureResultImageTests {
  @Test
  func exportsAllCornersAtSourceResolutionWithoutAWindow() throws {
    let size = CGSize(width: 1800, height: 1200)
    let context = try #require(CGContext(
      data: nil,
      width: 1800,
      height: 1200,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    for (rect, color) in [
      (CGRect(x: 0, y: 600, width: 900, height: 600), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
      (CGRect(x: 900, y: 600, width: 900, height: 600), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
      (CGRect(x: 0, y: 0, width: 900, height: 600), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
      (CGRect(x: 900, y: 0, width: 900, height: 600), CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
    ] {
      context.setFillColor(color)
      context.fill(rect)
    }
    let source = try #require(context.makeImage()?.pngData)
    let output = try #require(CaptureResultImage.png(imageData: source, imageSize: size, lines: []))
    let original = try #require(NSBitmapImageRep(data: source))
    let rendered = try #require(NSBitmapImageRep(data: output))
    #expect(rendered.pixelsWide == 1800)
    #expect(rendered.pixelsHigh == 1200)
    for (x, y) in [(10, 10), (1790, 10), (10, 1190), (1790, 1190)] {
      let expected = try #require(original.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      let actual = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
      #expect(abs(actual.redComponent - expected.redComponent) < 0.03)
      #expect(abs(actual.greenComponent - expected.greenComponent) < 0.03)
      #expect(abs(actual.blueComponent - expected.blueComponent) < 0.03)
    }
  }

  @Test(arguments: [false, true])
  func exportIncludesTranslatedGlyphs(horizontal: Bool) throws {
    let size = CGSize(width: 600, height: 400)
    let context = try #require(CGContext(
      data: nil,
      width: 600,
      height: 400,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let data = try #require(context.makeImage()?.pngData)
    var line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6), text: "Source text"),
      language: Locale.Language(identifier: "en")
    ))
    if !horizontal { line.source.layout = .vertical(characterScale: 0.05, progression: .rightToLeft) }
    line.showTranslation(horizontal ? "Complete translated text" : "日本語の翻訳", language: Locale.Language(identifier: horizontal
        ? "en"
        : "ja"))
    let output = try #require(CaptureResultImage.png(imageData: data, imageSize: size, lines: [line]))
    let rendered = try #require(NSBitmapImageRep(data: output))
    var darkPixels = 0
    for y in stride(from: 85, to: 315, by: 2) {
      for x in stride(from: 125, to: 475, by: 2) {
        let color = try #require(rendered.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        if color.redComponent < 0.5 { darkPixels += 1 }
      }
    }
    #expect(darkPixels > 20)
    let corner = try #require(rendered.colorAt(x: 10, y: 10)?.usingColorSpace(.deviceRGB))
    #expect(corner.redComponent > 0.98)
  }

  @Test(arguments: [0.1, 0.65, 1.0, 1.41])
  func scalingTheCompositedPreviewCannotRevealSourcePixels(scale: Double) throws {
    let size = CGSize(width: 400, height: 240)
    let context = try #require(CGContext(
      data: nil,
      width: 400,
      height: 240,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    // Magenta represents original glyph pixels that must be completely erased.
    context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 80, y: 96, width: 240, height: 48))
    let source = try #require(context.makeImage()?.pngData)
    var line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(boundingBoxNormalized: CGRect(x: 0.2, y: 0.4, width: 0.6, height: 0.2), text: "Original text"),
      language: Locale.Language(identifier: "en")
    ))
    line.showTranslation("번역된 내용", language: Locale.Language(identifier: "ko"))
    let composite = try #require(CaptureResultImage.render(imageData: source, imageSize: size, lines: [line]))
    let width = Int((size.width * scale).rounded())
    let height = Int((size.height * scale).rounded())
    let scaled = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    scaled.interpolationQuality = .high
    scaled.draw(composite, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bitmap = NSBitmapImageRep(cgImage: try #require(scaled.makeImage()))
    var sourcePixels = 0
    for y in 0..<height {
      for x in 0..<width {
        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
        if color.redComponent > 0.6, color.blueComponent > 0.6, color.greenComponent < 0.4 {
          sourcePixels += 1
        }
      }
    }
    #expect(sourcePixels == 0)
  }

  @Test
  func refusesMissingOrInvalidCapture() {
    #expect(CaptureResultImage.png(imageData: nil, imageSize: .zero, lines: []) == nil)
    #expect(CaptureResultImage.png(imageData: Data(), imageSize: CGSize(width: 10, height: 10), lines: []) == nil)
  }
}
