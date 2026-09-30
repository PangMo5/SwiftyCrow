// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import SwiftyCrow

@Suite("Source restoration color ownership")
struct SourceRestorationColorTests {

  // MARK: Internal

  enum OutlineBackdrop: CaseIterable, Sendable {
    case flat
    case textured
    case framed
  }

  struct OutlineScenario: Sendable, CustomStringConvertible {
    var scale: Int
    var dark: Bool
    var backdrop: OutlineBackdrop

    var description: String {
      "scale=\(scale), dark=\(dark), backdrop=\(backdrop)"
    }
  }

  static let rowOutlineScenarios = [1, 2, 3, 4].flatMap { scale in
    [false, true].flatMap { dark in
      [false, true].flatMap { owner in [0, 2].map { (scale, dark, owner, $0) } }
    }
  }

  static var outlineScenarios: [OutlineScenario] {
    [1, 2, 3].flatMap { scale in
      [false, true].flatMap { dark in
        OutlineBackdrop.allCases.map { OutlineScenario(scale: scale, dark: dark, backdrop: $0) }
      }
    }
  }

  @Test(arguments: [1, 2, 3].flatMap { scale in
    [false, true].flatMap { dark in [false, true].map { (scale, dark, $0) } }
  })
  func adjacentSurfaceCannotTintAFlatTextBackground(_ scenario: (Int, Bool, Bool)) async throws {
    let (scale, dark, quantized) = scenario
    let width = 140 * scale
    let height = 80 * scale
    let background: UInt8 = dark ? 51 : 204
    let neighbor: UInt8 = dark ? 0 : 255
    let foreground: UInt8 = dark ? 255 : 0
    var original = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        // Adjacent8-bit values straddle a four-level quantization boundary.
        // They are one material, not two unrelated surface colors.
        let material = quantized ? UInt8(Int(background) + (dark ? 1 : -1) * (x % 2)) : background
        let value = y < 45 * scale ? material : neighbor
        for channel in 0..<3 { original[(y * width + x) * 4 + channel] = value }
      }
    }
    var source = original
    let glyphs = [
      CGRect(x: 36, y: 22, width: 5, height: 22),
      CGRect(x: 36, y: 39, width: 18, height: 5),
      CGRect(x: 65, y: 27, width: 5, height: 17),
      CGRect(x: 90, y: 22, width: 5, height: 22),
    ]
    for glyph in glyphs {
      for y in Int(glyph.minY) * scale..<Int(glyph.maxY) * scale {
        for x in Int(glyph.minX) * scale..<Int(glyph.maxX) * scale {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = foreground }
        }
      }
    }
    let gray = CGFloat(background) / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let box = CGRect(x: 30.0 / 140, y: 20.0 / 80, width: 70.0 / 140, height: 24.0 / 80)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Header label",
      horizontalGlyphScale: 22.0 / 80,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)],
      surface: quantized ? .init(box: box, confidence: 1) : nil
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var maximumError = 0
    for y in 18 * scale..<48 * scale {
      for x in 28 * scale..<103 * scale {
        let offset = (y * width + x) * 4
        maximumError = max(maximumError, abs(Int(output[offset]) - Int(original[offset])))
      }
    }
    #expect(maximumError <= 1, "Restoration mixed neighboring surfaces: \(maximumError)")
  }

  @Test(arguments: [[UInt8(234), 236, 240], [232, 235, 240], [230, 235, 245]])
  func aTextOwnerCrossingTwoMaterialsDoesNotInventUniformBackgroundEvidence(_ button: [UInt8]) async throws {
    let width = 140
    let height = 80
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 20..<46 { for x in 80..<114 {
      let i = (y * width + x) * 4
      pixels[i] = button[0]
      pixels[i + 1] = button[1]
      pixels[i + 2] = button[2]
    } }
    for origin in [40, 90] { for y in 23..<42 { for x in origin..<origin + 8 {
      let i = (y * width + x) * 4
      pixels[i] = 20
      pixels[i + 1] = 24
      pixels[i + 2] = 28
    } } }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
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
    ))
    let appearance = OverlaySourceAppearance(
      background: .white,
      foreground: .init(red: 20.0 / 255, green: 24.0 / 255, blue: 28.0 / 255, alpha: 1),
      confidence: 1
    )
    let box = CGRect(x: 30.0 / 140, y: 20.0 / 80, width: 80.0 / 140, height: 24.0 / 80)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Heading action",
      horizontalGlyphScale: 22.0 / 80,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let result = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: image)
    #expect(!result.lines[0].needsReview, "A second observed material cannot be filtered out of the uniformity evidence")
  }

  @Test(arguments: [1, 2, 3], [false, true])
  func aFlatSurfaceDoesNotRetainResamplingRings(scale: Int, dark: Bool) async throws {
    let width = 140 * scale
    let height = 80 * scale
    let background: UInt8 = dark ? 51 : 204
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for i in 0..<width * height { for channel in 0..<3 { pixels[i * 4 + channel] = background } }
    let glyphs = [
      CGRect(x: 50 * scale, y: 24 * scale, width: 16 * scale, height: 18 * scale),
      // Original text can lie wholly outside the inset available to its
      // translation while still belonging to the same detected material.
      CGRect(x: 90 * scale, y: 24 * scale, width: 10 * scale, height: 18 * scale),
    ]
    for (extent, value) in [(2, dark ? UInt8(43) : 212), (1, dark ? UInt8(55) : 200), (0, dark ? UInt8(255) : 0)] {
      for glyph in glyphs {
        let box = glyph.insetBy(dx: -CGFloat(extent), dy: -CGFloat(extent))
        for y in Int(box.minY)..<Int(box.maxY) { for x in Int(box.minX)..<Int(box.maxX) {
          for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = value }
        } }
      }
    }
    let gray = CGFloat(background) / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let box = CGRect(x: 40.0 / 140, y: 20.0 / 80, width: 70.0 / 140, height: 24.0 / 80)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Raster label",
      horizontalGlyphScale: 18.0 / 80,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)],
      surface: .init(
        box: CGRect(x: 20.0 / 140, y: 10.0 / 80, width: 44.0 / 140, height: 50.0 / 80),
        confidence: 1,
        clippingBox: CGRect(x: 20.0 / 140, y: 10.0 / 80, width: 100.0 / 140, height: 50.0 / 80)
      )
    )
    let output = try await Self.restoredPixels(pixels, width: width, height: height, line: line)
    var maximum = 0
    for glyph in glyphs {
      let scope = glyph.insetBy(dx: -2, dy: -2)
      for y in Int(scope.minY)..<Int(scope.maxY) { for x in Int(scope.minX)..<Int(scope.maxX) {
        maximum = max(maximum, abs(Int(output[(y * width + x) * 4]) - Int(background)))
      } }
    }
    #expect(maximum <= 1, "Resampling ring remains: \(maximum)")
  }

  @Test(arguments: rowOutlineScenarios)
  func connectedOutlinesRequireTheSameObservedOwner(_ scenario: (Int, Bool, Bool, Int)) async throws {
    let (scale, dark, ownsSecondRow, antialias) = scenario
    let width = 180 * scale
    let height = 110 * scale
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = dark ? 51 : 204 }
      }
    }
    func fill(_ rect: CGRect, value: UInt8) {
      for y in Int(rect.minY * CGFloat(scale))..<Int(rect.maxY * CGFloat(scale)) {
        for x in Int(rect.minX * CGFloat(scale))..<Int(rect.maxX * CGFloat(scale)) {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = value }
        }
      }
    }
    // The two outlines touch across separately observed rows. Neither patch
    // contains the whole component, but both glyphs belong to this paragraph.
    let outline = CGRect(x: 36, y: 24, width: 20, height: 62)
      .insetBy(dx: -CGFloat(antialias), dy: -CGFloat(antialias))
    fill(outline, value: dark ? 5 : 250)
    for y in [28, 58] {
      let glyph = CGRect(x: 40, y: y, width: 12, height: 24)
      if antialias > 0 {
        fill(glyph.insetBy(dx: -CGFloat(antialias), dy: -CGFloat(antialias)), value: dark ? 105 : 150)
      }
      fill(glyph, value: dark ? 240 : 15)
    }
    let artwork = CGRect(x: 125, y: 15, width: 12, height: 70)
    fill(artwork, value: dark ? 5 : 250)
    let appearance = OverlaySourceAppearance(
      background: .init(red: dark ? 0.2 : 0.8, green: dark ? 0.2 : 0.8, blue: dark ? 0.2 : 0.8, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let boxes = [26.0, 56.0].map { CGRect(x: 30.0 / 180, y: $0 / 110, width: 60.0 / 180, height: 28.0 / 110) }
    let line = OCRResult.Line(
      boundingBoxNormalized: ownsSecondRow ? boxes[0].union(boxes[1]) : boxes[0],
      text: "Two rows",
      horizontalGlyphScale: 24.0 / 110,
      appearance: appearance,
      replacementPatches: (ownsSecondRow ? boxes : [boxes[0]]).map { .init(box: $0, appearance: appearance) }
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var remnants = 0
    var residualValues = [UInt8: Int]()
    for y in Int(outline.minY) * scale..<Int(outline.maxY) * scale {
      for x in Int(outline.minX) * scale..<Int(outline.maxX) * scale {
        let value = output[(y * width + x) * 4]
        if abs(Int(value) - (dark ? 51 : 204)) > 1 {
          remnants += 1
          residualValues[value, default: 0] += 1
        }
      }
    }
    if ownsSecondRow {
      #expect(remnants == 0, "Shared row outline remnants: \(remnants), values: \(residualValues)")
    } else {
      // A matching color continues into content this OCR owner did not claim.
      // Do not truncate that component at the patch edge and erase its halo.
      #expect(output[(30 * scale * width + 36 * scale) * 4] == (dark ? 5 : 250))
      for y in 58 * scale..<82 * scale {
        for x in 40 * scale..<52 * scale {
          #expect(output[(y * width + x) * 4] == source[(y * width + x) * 4])
        }
      }
    }
    for y in Int(artwork.minY) * scale..<Int(artwork.maxY) * scale {
      for x in Int(artwork.minX) * scale..<Int(artwork.maxX) * scale {
        #expect(output[(y * width + x) * 4] == source[(y * width + x) * 4])
      }
    }
  }

  @Test(arguments: [1, 2, 3], [false, true])
  func aSmallAccessoryThatOnlyGrazesTheOCRBoxKeepsItsOwnPixels(scale: Int, dark: Bool) async throws {
    let width = 140 * scale
    let height = 100 * scale
    let background: UInt8 = dark ? 35 : 220
    let foreground: UInt8 = dark ? 240 : 15
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = background }
      }
    }
    func fill(_ rect: CGRect) {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = foreground }
        }
      }
    }
    let glyph = CGRect(x: 70, y: 28, width: 22, height: 24)
    fill(glyph)
    // Only its leftmost pixel intersects the observation. The component is
    // entirely inside the padded analysis tile, unlike a long external border.
    var accessory = [CGRect]()
    for x in 0..<6 {
      let pixel = CGRect(x: 89 + x, y: 58 + min(x, 5 - x), width: 1, height: 1)
      accessory.append(pixel)
      fill(pixel)
    }
    let gray = CGFloat(background) / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let box = CGRect(x: 30.0 / 140, y: 0.2, width: 60.0 / 140, height: 0.45)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Read more",
      horizontalGlyphScale: 0.24,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var damaged = 0
    for rect in accessory {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          if output[(y * width + x) * 4] != source[(y * width + x) * 4] { damaged += 1 }
        }
      }
    }
    #expect(damaged == 0, "Accessory pixels changed: \(damaged)")
    // The real glyph extends two pixels past the same OCR edge. Its center
    // belongs to the observation, so this is still text that must disappear.
    var remnants = 0
    for y in Int(glyph.minY) * scale..<Int(glyph.maxY) * scale {
      for x in Int(glyph.minX) * scale..<Int(glyph.maxX) * scale {
        if abs(Int(output[(y * width + x) * 4]) - Int(background)) > 1 { remnants += 1 }
      }
    }
    #expect(remnants == 0, "Owned glyph remnants: \(remnants)")
  }

  @Test(arguments: [1, 2, 3], [false, true])
  func disconnectedInkOutsideAnObservedRowIsNotOwnedByPadding(scale: Int, dark: Bool) async throws {
    let width = 120 * scale
    let height = 80 * scale
    let background: UInt8 = dark ? 35 : 220
    let foreground: UInt8 = dark ? 240 : 15
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = background }
      }
    }
    let glyph = CGRect(x: 50, y: 30, width: 20, height: 20)
    let decoration = CGRect(x: 55, y: 24, width: 6, height: 4)
    for rect in [glyph, decoration] {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = foreground }
        }
      }
    }
    let gray = CGFloat(background) / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let box = CGRect(x: 45.0 / 120, y: 30.0 / 80, width: 35.0 / 120, height: 20.0 / 80)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Source text",
      horizontalGlyphScale: 20.0 / 80,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var damaged = 0
    for y in Int(decoration.minY) * scale..<Int(decoration.maxY) * scale {
      for x in Int(decoration.minX) * scale..<Int(decoration.maxX) * scale {
        if output[(y * width + x) * 4] != source[(y * width + x) * 4] { damaged += 1 }
      }
    }
    #expect(damaged == 0, "Unobserved decoration pixels changed: \(damaged)")
    #expect(abs(Int(output[(40 * scale * width + 60 * scale) * 4]) - Int(background)) <= 1)
  }

  @Test(arguments: [0, 1, 2, 3, 4, 5], [false, true])
  func wordGapsAndSplitObservationFragmentsAreNotArtwork(grouping: Int, dark: Bool) async throws {
    let width = 120
    let height = 80
    let background: UInt8 = dark ? 35 : 220
    let foreground: UInt8 = dark ? 240 : 15
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for index in 0..<width * height {
      for channel in 0..<3 { source[index * 4 + channel] = background }
    }
    let glyph = CGRect(x: 57, y: 28, width: 10, height: 24)
    for y in Int(glyph.minY)..<Int(glyph.maxY) {
      for x in Int(glyph.minX)..<Int(glyph.maxX) {
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = foreground }
      }
    }
    let gray = CGFloat(background) / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let boxes = [
      CGRect(x: 30.0 / 120, y: 0.25, width: 30.0 / 120, height: 0.5),
      CGRect(x: 64.0 / 120, y: 0.25, width: 26.0 / 120, height: 0.5),
    ]
    let lines: [OCRResult.Line] =
      if grouping == 0 {
        [.init(
          boundingBoxNormalized: boxes[0].union(boxes[1]),
          text: "Whole observation",
          horizontalGlyphScale: 0.3,
          appearance: appearance,
          replacementPatches: boxes.map { .init(box: $0, appearance: appearance) }
        )]
      } else {
        boxes.enumerated().map { index, box in
          var line = OCRResult.Line(
            boundingBoxNormalized: box,
            text: index == 0 ? "First words" : "Other words",
            horizontalGlyphScale: 0.3,
            recognitionGroupID: grouping == 2 ? 77 + index : 77,
            appearance: appearance,
            replacementPatches: [.init(box: box, appearance: appearance)]
          )
          if grouping == 3 { line.recognitionContextID = index }
          if grouping == 4 { line.tableCell = .init(table: 0, row: 0, column: index, box: box) }
          if grouping == 5 {
            line.recognitionContainer = CGRect(x: CGFloat(index) * 0.5, y: 0, width: 0.5, height: 1)
          }
          return line
        }
      }
    let output = try await Self.restoredPixels(source, width: width, height: height, lines: lines)
    var wrong = 0
    let expected = grouping >= 2 ? foreground : background
    for y in Int(glyph.minY)..<Int(glyph.maxY) {
      for x in Int(glyph.minX)..<Int(glyph.maxX) {
        if abs(Int(output[(y * width + x) * 4]) - Int(expected)) > 1 { wrong += 1 }
      }
    }
    #expect(wrong == 0, "Incorrectly attributed component pixels: \(wrong)")
  }

  @Test(arguments: gradientScenarios)
  func reconstructionRetainsAnUnderlyingSmoothGradient(_ scenario: (Int, Bool, Int)) async throws {
    let (scale, dark, direction) = scenario
    let width = 180 * scale
    let height = 100 * scale
    var original = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let horizontal = direction == 1 ? 0 : Double(x) / Double(scale) * 0.4
        let vertical = direction == 0 ? 0 : Double(y) / Double(scale) * 0.6
        let value = min(242, Int((150 + horizontal + vertical).rounded()))
        for channel in 0..<3 { original[(y * width + x) * 4 + channel] = UInt8(dark ? 255 - value : value) }
      }
    }
    var source = original
    let glyph = CGRect(x: 58 * scale, y: 32 * scale, width: 28 * scale, height: 26 * scale)
    for y in Int(glyph.minY)..<Int(glyph.maxY) {
      for x in Int(glyph.minX)..<Int(glyph.maxX) {
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = dark ? 245 : 10 }
      }
    }
    let gray: CGFloat = dark ? 55.0 / 255 : 200.0 / 255
    let appearance = OverlaySourceAppearance(
      background: .init(red: gray, green: gray, blue: gray, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let box = CGRect(x: 40.0 / 180, y: 0.2, width: 100.0 / 180, height: 0.55)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Gradient",
      horizontalGlyphScale: 0.26,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var total = 0
    var maximum = 0
    for y in Int(glyph.minY)..<Int(glyph.maxY) {
      for x in Int(glyph.minX)..<Int(glyph.maxX) {
        let offset = (y * width + x) * 4
        let error = abs(Int(output[offset]) - Int(original[offset]))
        total += error
        maximum = max(maximum, error)
      }
    }
    let mean = Double(total) / Double(Int(glyph.width * glyph.height))
    #expect(mean <= 1, "Gradient reconstruction MAE: \(mean)")
    #expect(maximum <= 2, "Gradient reconstruction maximum error: \(maximum)")
  }

  @Test
  func aProtectedStrokeFringeDoesNotRetainNearbyOwnedGlyphs() async throws {
    let width = 180
    let height = 100
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 204 }
      }
    }
    for y in 35..<64 {
      for x in 0..<width where y >= 61 || (x >= 80 && x < 95 && y < 60) {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
      }
    }
    let box = CGRect(x: 35.0 / 180, y: 0.25, width: 100.0 / 180, height: 0.4)
    let appearance = OverlaySourceAppearance(
      background: .init(red: 0.8, green: 0.8, blue: 0.8, alpha: 1),
      foreground: .black,
      confidence: 1
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Text",
      horizontalGlyphScale: 0.24,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let result = try await Self.restoredPixels(pixels, width: width, height: height, line: line)
    #expect((35..<60).allSatisfy { y in (80..<95).allSatisfy { x in result[(y * width + x) * 4] > 180 } })
    #expect((61..<64).allSatisfy { y in (0..<width).allSatisfy { x in result[(y * width + x) * 4] == 0 } })
  }

  @Test
  func connectedInkInAnotherObservedPatchStillBelongsToTheText() async throws {
    let width = 150
    let height = 80
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 40..<44 {
      for x in 35..<111 {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
      }
    }
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let boxes = [CGRect(x: 30, y: 30, width: 35, height: 20), CGRect(x: 60, y: 30, width: 55, height: 20)].map {
      CGRect(x: $0.minX / 150, y: $0.minY / 80, width: $0.width / 150, height: $0.height / 80)
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: boxes[0].union(boxes[1]),
      text: "Connected text",
      horizontalGlyphScale: 10.0 / 80,
      appearance: appearance,
      replacementPatches: boxes.map { .init(box: $0, appearance: appearance) }
    )
    let result = try await Self.restoredPixels(pixels, width: width, height: height, line: line)
    #expect((40..<44).allSatisfy { y in (35..<111).allSatisfy { x in result[(y * width + x) * 4] > 180 } })
  }

  @Test
  func aBoxContainingOnlyExternalArtworkHasNoOpaqueErasureOwner() async throws {
    let width = 100
    let height = 100
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 49..<52 {
      for x in 0..<width {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
      }
    }
    let box = CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.25)
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Text",
      horizontalGlyphScale: 0.1,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let result = try await Self.restoredPixels(pixels, width: width, height: height, line: line)
    #expect(result == pixels)
  }

  @Test(arguments: borderScenarios)
  func crossingArtworkSurvivesAnImpreciseTextBox(_ scenario: (Int, Bool, Bool, Bool)) async throws {
    let (scale, dark, curved, textured) = scenario
    let width = 200 * scale
    let height = 100 * scale
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let light = textured ? 190 + ((x / scale + y / scale * 3) % 5) * 7 : 204
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = UInt8(dark ? 255 - light : light) }
      }
    }
    func fill(_ rect: CGRect, value: UInt8) {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = value }
        }
      }
    }
    let foreground: UInt8 = dark ? 240 : 15
    var artwork = [CGRect]()
    if curved {
      for x in 0..<200 {
        let y = Int(61 + 0.002 * Double((x - 88) * (x - 88)))
        if y + 3 <= 100 { artwork.append(CGRect(x: x, y: y, width: 1, height: 3)) }
      }
    } else {
      for y in 0..<95 { artwork.append(CGRect(x: 100 + y * 2 / 3, y: y, width: 3, height: 1)) }
    }
    for rect in artwork { fill(rect, value: foreground) }
    let glyphs = [CGRect(x: 50, y: 34, width: 8, height: 20), CGRect(x: 85, y: 34, width: 12, height: 20)]
    for rect in glyphs { fill(rect, value: foreground) }
    let background = dark ? 0.2 : 0.8
    let appearance = OverlaySourceAppearance(
      background: .init(red: background, green: background, blue: background, alpha: 1),
      foreground: dark ? .white : .black,
      confidence: 1,
      fontWeight: .regular
    )
    // The OCR box overlaps a real boundary; its interior is not all text ink.
    let box = CGRect(x: 35.0 / 200, y: 25.0 / 100, width: 100.0 / 200, height: 40.0 / 100)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Text",
      horizontalGlyphScale: 24.0 / 100,
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var artworkChanges = 0
    for rect in artwork {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          if output[(y * width + x) * 4] != source[(y * width + x) * 4] { artworkChanges += 1 }
        }
      }
    }
    #expect(artworkChanges == 0, "Connected artwork must survive even where it crosses an OCR box")
    var remainingGlyphPixels = 0
    for rect in glyphs {
      for y in Int(rect.minY) * scale..<Int(rect.maxY) * scale {
        for x in Int(rect.minX) * scale..<Int(rect.maxX) * scale {
          let value = Int(output[(y * width + x) * 4])
          if (dark ? 255 - value : value) < 170 { remainingGlyphPixels += 1 }
        }
      }
    }
    #expect(remainingGlyphPixels == 0, "Protecting an external component must not retain the actual glyphs")
  }

  @Test(arguments: outlineScenarios)
  func outlinedGlyphsDoNotBecomeTheirOwnBackground(_ scenario: OutlineScenario) async throws {
    let scale = scenario.scale
    let dark = scenario.dark
    let backdrop = scenario.backdrop
    let width = 180 * scale
    let height = 80 * scale
    var source = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        let light = backdrop == .flat ? 204 : 190 + ((x / scale + y / scale * 3) % 5) * 7
        let value = UInt8(dark ? 255 - light : light)
        for channel in 0..<3 { source[(y * width + x) * 4 + channel] = value }
      }
    }
    let transform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
    let glyphs = [CGRect(x: 35, y: 28, width: 8, height: 24), CGRect(x: 70, y: 28, width: 14, height: 24)]
      .map { $0.applying(transform) }
    let outlines = glyphs.map { $0.insetBy(dx: CGFloat(-4 * scale), dy: CGFloat(-4 * scale)) }
    let artwork = CGRect(x: 125, y: 15, width: 12, height: 50).applying(transform)
    func fill(_ rect: CGRect, value: UInt8) {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          for channel in 0..<3 { source[(y * width + x) * 4 + channel] = value }
        }
      }
    }
    for rect in outlines + [artwork] { fill(rect, value: dark ? 5 : 250) }
    // Antialiasing also scales with source pixels; it separates the strong
    // stroke from the opposite-polarity outline by more than two pixels at3×.
    for rect in glyphs { fill(rect.insetBy(dx: CGFloat(-scale), dy: CGFloat(-scale)), value: dark ? 105 : 150) }
    for rect in glyphs { fill(rect, value: dark ? 240 : 15) }
    let frame = CGRect(x: 0, y: 64, width: 180, height: 3).applying(transform)
    if backdrop == .framed { fill(frame, value: dark ? 240 : 15) }
    let box = CGRect(x: 25.0 / 180, y: 20.0 / 80, width: 90.0 / 180, height: 40.0 / 80)
    // The white/black outline dominates OCR appearance sampling. It must not
    // be treated as the material beneath the glyph or copied back as a donor.
    let appearance = OverlaySourceAppearance(
      background: dark ? .black : .white,
      foreground: dark ? .white : .black,
      confidence: 1
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Outlined text",
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)]
    )
    let output = try await Self.restoredPixels(source, width: width, height: height, line: line)
    var remnants = 0
    for rect in outlines {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          let value = Int(output[(y * width + x) * 4])
          let light = dark ? 255 - value : value
          if !(190...218).contains(light) { remnants += 1 }
        }
      }
    }
    #expect(remnants == 0, "Both the glyph and its opposite-polarity outline must disappear")
    var artworkChanges = 0
    for rect in [artwork] + (backdrop == .framed ? [frame] : []) {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          if output[(y * width + x) * 4] != source[(y * width + x) * 4] { artworkChanges += 1 }
        }
      }
    }
    #expect(artworkChanges == 0)
  }

  @Test(arguments: [false, true])
  func texturedRestorationUsesObservedOwnershipBetweenRows(enclosed: Bool) async throws {
    let width = 240
    let height = 140
    var pixels = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0..<height {
      for x in 0..<width {
        for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = UInt8(190 + (x % 5) * 10) }
      }
    }
    let first = CGRect(x: 30, y: 30, width: 65, height: 20)
    let last = CGRect(x: 30, y: 90, width: 170, height: 20)
    let graphic = CGRect(x: 145, y: 38, width: 35, height: 18)
    for rect in [first.insetBy(dx: 8, dy: 5), last.insetBy(dx: 8, dy: 5), graphic] {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          for channel in 0..<3 { pixels[(y * width + x) * 4 + channel] = 0 }
        }
      }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let sourceImage = try #require(CGImage(
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
    ))
    func normalized(_ rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX / CGFloat(width),
        y: rect.minY / CGFloat(height),
        width: rect.width / CGFloat(width),
        height: rect.height / CGFloat(height)
      )
    }
    let appearance = OverlaySourceAppearance(
      background: .init(red: 0.84, green: 0.84, blue: 0.84, alpha: 1),
      foreground: .black,
      confidence: 1
    )
    let line = OCRResult.Line(
      boundingBoxNormalized: normalized(first.union(last)),
      text: "Two ragged rows",
      isReconstructedTextRegion: enclosed,
      appearance: appearance,
      replacementPatches: [first, last].map { .init(box: normalized($0), appearance: appearance) },
      surface: enclosed
        ? .init(
          box: normalized(first.union(last)),
          confidence: 1,
          clippingBox: normalized(first.union(last)),
          clippingRows: [normalized(first.union(last))]
        )
        : nil
    )
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: sourceImage)
    for patch in try #require(restored.lines.first).replacementPatches {
      let png = try #require(patch.restorationPNG)
      let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
      let tile = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
      let raster = try #require(CGContext(
        data: nil,
        width: tile.width,
        height: tile.height,
        bitsPerComponent: 8,
        bytesPerRow: tile.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      raster.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
      let bytes = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
      let renderingBox = try #require(patch.renderingBox)
      let originX = Int((renderingBox.minX * CGFloat(width)).rounded())
      let originY = Int((renderingBox.minY * CGFloat(height)).rounded())
      for y in 0..<tile.height {
        for x in 0..<tile.width where bytes[(y * tile.width + x) * 4 + 3] == 255 {
          for channel in 0..<3 {
            pixels[((originY + y) * width + originX + x) * 4 + channel] = bytes[(y * tile.width + x) * 4 + channel]
          }
        }
      }
    }
    var damaged = 0
    for y in Int(graphic.minY)..<Int(graphic.maxY) {
      for x in Int(graphic.minX)..<Int(graphic.maxX) {
        if pixels[(y * width + x) * 4] != 0 { damaged += 1 }
      }
    }
    if enclosed {
      // A physically reconstructed text region also owns disconnected source
      // marks between its OCR rows. An ordinary paragraph has no such evidence.
      #expect(damaged == Int(graphic.width * graphic.height))
    } else {
      #expect(damaged == 0, "Artwork in an unowned paragraph gap must remain byte-identical")
    }
    for rect in [first, last].map({ $0.insetBy(dx: 8, dy: 5) }) {
      for y in Int(rect.minY)..<Int(rect.maxY) {
        for x in Int(rect.minX)..<Int(rect.maxX) {
          #expect(pixels[(y * width + x) * 4] >= 180)
        }
      }
    }
  }

  @Test
  func aFullyOwnedTileCanSampleBackgroundBeyondItsRasterEdge() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 20,
      height: 20,
      bitsPerComponent: 8,
      bytesPerRow: 80,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 7, y: 7, width: 6, height: 6))
    let box = CGRect(x: 0.45, y: 0.45, width: 0.1, height: 0.1)
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Annotation",
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance, isAnnotation: true)]
    )
    let result = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: try #require(context.makeImage()))
    let png = try #require(result.lines.first?.replacementPatches.first?.restorationPNG)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let tile = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let raster = try #require(CGContext(
      data: nil,
      width: tile.width,
      height: tile.height,
      bitsPerComponent: 8,
      bytesPerRow: tile.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    raster.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
    let pixels = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
    let opaque = (0..<(tile.width * tile.height)).filter { pixels[$0 * 4 + 3] > 0 }
    #expect(!opaque.isEmpty)
    #expect(opaque.allSatisfy { pixels[$0 * 4] >= 240 })
  }

  @Test(arguments: [0.0, 0.72])
  func aBitmapCannotCopyNeighboringInkBackIntoAnErasedGlyph(_ neighborGray: Double) async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 55, y: 25, width: 6, height: 30))
    // A separate source word lies just beyond the owned glyph and its fringe.
    context.setFillColor(CGColor(gray: neighborGray, alpha: 1))
    context.fill(CGRect(x: 63, y: 15, width: 3, height: 50))
    let box = CGRect(x: 0.5, y: 0.25, width: 0.11, height: 0.5)
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.4, y: 0.25, width: 0.3, height: 0.5),
      text: "Erase",
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)],
      surface: .init(
        box: box,
        confidence: 1
      )
    )
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: try #require(context.makeImage()))
    let data = try #require(restored.lines.first?.replacementPatches.first?.restorationPNG)
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let tile = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let raster = try #require(CGContext(
      data: nil,
      width: tile.width,
      height: tile.height,
      bitsPerComponent: 8,
      bytesPerRow: tile.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    raster.draw(tile, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
    let pixels = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
    let repaintedInk = (0..<(tile.width * tile.height)).count { pixels[$0 * 4 + 3] > 0 && pixels[$0 * 4] < 220 }
    #expect(repaintedInk == 0)
  }

  @Test
  func establishedRubyRailRecoversSmallMissedInkButNotConnectedArtwork() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 100,
      bitsPerComponent: 8,
      bytesPerRow: 400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 64, y: 20, width: 4, height: 7))
    context.fill(CGRect(x: 64, y: 70, width: 4, height: 7))
    // An adjacent connected edge is not a pronunciation glyph.
    context.fill(CGRect(x: 60, y: 38, width: 2, height: 24))
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let main = CGRect(x: 0.35, y: 0.1, width: 0.22, height: 0.8)
    let ruby = CGRect(x: 0.6, y: 0.15, width: 0.12, height: 0.15)
    let line = OCRResult.Line(
      boundingBoxNormalized: main.union(ruby),
      text: "漢字",
      isVerticalBlock: true,
      verticalCharScale: 0.22,
      appearance: appearance,
      replacementPatches: [.init(box: ruby, appearance: appearance, isAnnotation: true)]
    )
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: try #require(context.makeImage()))
    let patches = try #require(restored.lines.first).replacementPatches
    #expect(patches.count == 2)
    #expect(patches.allSatisfy { $0.isAnnotation })
  }

  @Test
  func annotationErasesOnlyItsInkAndKeepsAdjacentColoredSurface() async throws {
    let context = try #require(CGContext(
      data: nil,
      width: 100,
      height: 80,
      bitsPerComponent: 8,
      bytesPerRow: 400,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
    context.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 45, height: 80))
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.fill(CGRect(x: 60, y: 30, width: 4, height: 20))
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let box = CGRect(x: 0.4, y: 0.25, width: 0.3, height: 0.5)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "漢字",
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance, isAnnotation: true)]
    )
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: try #require(context.makeImage()))
    let patch = try #require(restored.lines.first?.replacementPatches.first)
    #expect(patch.isAnnotation)
    let png = try #require(patch.restorationPNG)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let raster = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(raster.data).assumingMemoryBound(to: UInt8.self)
    // Non-owned pixels must not repaint the original background or text over
    // another restoration tile. Transparent pixels use premultiplied zero RGB.
    #expect(pixels[3] == 0)
    #expect(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0)
    let renderingBox = try #require(patch.renderingBox)
    let expectedColumns = 45 - Int((renderingBox.minX * 100).rounded())
    raster.setFillColor(CGColor(gray: 1, alpha: 1))
    raster.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    raster.setFillColor(CGColor(red: 1, green: 0.6, blue: 0.4, alpha: 1))
    raster.fill(CGRect(x: 0, y: 0, width: expectedColumns, height: image.height))
    raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let dark = (0..<image.width * image.height).count { pixels[$0 * 4] < 100 }
    let orange = (0..<image.width * image.height).count { pixels[$0 * 4 + 1] < 200 }
    #expect(dark == 0)
    #expect(orange == expectedColumns * image.height)
  }

  @Test(arguments: [false, true])
  func unmodeledInlineColorsAreNotCopiedBackAsBackground(dark: Bool) async throws {
    let width = 220
    let height = 80
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    let background = dark ? OverlayColor.black : .white
    let foreground = dark ? OverlayColor.white : .black
    context.setFillColor(CGColor(gray: dark ? 0 : 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.setFillColor(CGColor(gray: dark ? 1 : 0, alpha: 1))
    context.fill(CGRect(x: 30, y: 30, width: 30, height: 18))
    // Two other colors live inside the same OCR run, without separate style
    // metadata, as occurs in linked Chinese/Japanese prose on real web pages.
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.85, alpha: 1))
    context.fill(CGRect(x: 85, y: 30, width: 35, height: 18))
    context.setFillColor(CGColor(red: 0.85, green: 0.2, blue: 0.15, alpha: 1))
    context.fill(CGRect(x: 145, y: 30, width: 30, height: 18))
    let box = CGRect(x: 20.0 / 220, y: 0.25, width: 170.0 / 220, height: 0.5)
    let appearance = OverlaySourceAppearance(background: background, foreground: foreground, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "Linked multilingual prose",
      appearance: appearance,
      replacementPatches: [.init(box: box, appearance: appearance)],
      // Force raster restoration, which used to preserve the unknown colors.
      surface: .init(box: box, confidence: 1)
    )
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: [line]), image: try #require(context.makeImage()))
    let patch = try #require(restored.lines.first?.replacementPatches.first)
    let png = try #require(patch.restorationPNG)
    let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
    let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let raster = try #require(CGContext(
      data: nil,
      width: image.width,
      height: image.height,
      bitsPerComponent: 8,
      bytesPerRow: image.width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    // Composite over the actual old glyph pixels. Filling an empty background
    // here would let transparent, unerased link glyphs falsely pass the test.
    let original = try #require(context.makeImage())
    let renderingBox = try #require(patch.renderingBox)
    let oldPixels = try #require(original.cropping(to: CGRect(
      x: renderingBox.minX * CGFloat(width),
      y: renderingBox.minY * CGFloat(height),
      width: renderingBox.width * CGFloat(width),
      height: renderingBox.height * CGFloat(height)
    ).integral))
    raster.draw(oldPixels, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    raster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let pixels = try #require(raster.data).assumingMemoryBound(to: UInt8.self)
    let target = dark ? 0 : 255
    let remainingInk = (0..<image.width * image.height).count { index in
      (0..<3).contains { abs(Int(pixels[index * 4 + $0]) - target) > 8 }
    }
    #expect(remainingInk == 0)
  }

  // MARK: Private

  private static let gradientScenarios = [1, 2, 3].flatMap { scale in
    [false, true].flatMap { dark in [0, 1, 2].map { direction in (scale, dark, direction) } }
  }

  private static let borderScenarios = [1, 2, 3].flatMap { scale in
    [false, true].flatMap { dark in
      [false, true].flatMap { curved in
        [false, true].map { textured in (scale, dark, curved, textured) }
      }
    }
  }

  @MainActor
  private static func restoredPixels(
    _ pixels: [UInt8],
    width: Int,
    height: Int,
    line: OCRResult.Line
  ) async throws -> [UInt8] {
    try await restoredPixels(pixels, width: width, height: height, lines: [line])
  }

  @MainActor
  private static func restoredPixels(
    _ pixels: [UInt8],
    width: Int,
    height: Int,
    lines: [OCRResult.Line]
  ) async throws -> [UInt8] {
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let image = try #require(CGImage(
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
    ))
    let restored = await SourceRestorationBuilder.applying(to: .init(lines: lines), image: image)
    let overlays = restored.lines.map { line in
      var overlay = OverlayLine(id: UUID(), source: .init(recognized: line, language: .init(identifier: "en")))
      overlay.source.appearance.foreground.alpha = 0
      overlay.showTranslation("Translated", language: .init(identifier: "ko"))
      return overlay
    }
    let rendered = try #require(CaptureResultImage.render(
      imageData: image.pngData,
      imageSize: CGSize(width: width, height: height),
      lines: overlays
    ))
    let raster = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    raster.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
    let bytes = try #require(raster.data?.assumingMemoryBound(to: UInt8.self))
    return Array(UnsafeBufferPointer(start: bytes, count: width * height * 4))
  }

}
