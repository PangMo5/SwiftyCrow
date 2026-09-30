// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Masked background reconstruction")
struct BackgroundReconstructionTests {

  // MARK: Internal

  @Test
  func rejectedExteriorPixelsCannotBeSkippedToBorrowAnotherMaterial() {
    var colors = [SIMD3<Float>]()
    let unresolved = BackgroundReconstruction.fill(
      width: 3,
      height: 1,
      mask: [true, true, false],
      barriers: nil,
      allowsExteriorSamples: true
    ) { x, y in
      if x == 2, y == 0 { return SIMD3(repeating: 180) }
      if x < -1, y == 0 { return SIMD3(240, 100, 100) }
      return nil
    } write: { _, value in if let value { colors.append(value) } }
    #expect(unresolved == 0)
    #expect(colors.count == 2)
    #expect(colors.allSatisfy { $0 == SIMD3(repeating: 180) })
  }

  @Test
  func aShortProtectedLineCannotBeJumpedByTheTextureFilter() {
    let width = 80
    let height = 80
    let mask = (0..<width * height).map { i in (24..<40).contains(i % width) && (16..<64).contains(i / width) }
    let source = (0..<width * height).map { i -> SIMD4<Float> in
      let x = i % width
      let y = i / width
      if x == 40, (8..<72).contains(y) { return .zero }
      let value: Float = (x < 40 ? 180 : 40) + Self.grain(x: x, y: y, scale: 1)
      return SIMD4(value, value, value, 1)
    }
    let material = source.enumerated().map { mask[$0.offset] ? SIMD4<Float>.zero : $0.element }
    var field = source.enumerated().map { mask[$0.offset] ? SIMD4<Float>(180, 180, 180, 1) : $0.element }
    // Both sides are connected around the line's ends, so a component label
    // alone cannot authorize jumping over its missing middle sample.
    BackgroundTexture.apply(width: width, height: height, mask: mask, material: material, field: &field)
    let mean = (24..<56).reduce(Float.zero) { $0 + field[$1 * width + 39].x } / 32
    #expect((175...185).contains(mean), "The other surface tinted the boundary: \(mean)")
    #expect(source.indices.filter { !mask[$0] }.allSatisfy { source[$0] == field[$0] })
  }

  @Test(arguments: [1, 2, 3], [false, true])
  func stochasticMaterialRetainsGrainAndIllumination(scale: Int, chromatic: Bool) {
    let width = 120
    let height = 96
    let mask = (0..<width * height).map { i in
      (40..<80).contains(i % width) && (32..<64).contains(i / width)
    }
    func surface(_ x: Int, _ y: Int) -> SIMD3<Float> {
      let noise = Self.grain(x: x, y: y, scale: scale)
      return SIMD3(170 + Float(x) * 0.1 + noise, 185 + Float(y) * 0.08 + (chromatic ? -noise : noise), 200 + (chromatic
          ? 0
          : noise))
    }
    var result = (0..<width * height).map { surface($0 % width, $0 / width) }
    let unresolved = BackgroundReconstruction.fill(
      width: width,
      height: height,
      mask: mask,
      barriers: nil,
      allowsExteriorSamples: false,
      sample: surface
    ) { i, value in
      if let value { result[i] = value }
    }
    #expect(unresolved == 0)
    var expected = [Double]()
    var actual = [Double]()
    var expectedEdges = 0.0
    var actualEdges = 0.0
    // Interior statistics exclude the observed boundary. Random texture under
    // a glyph is unknowable; its distribution, not its phase, must survive.
    for y in 36..<60 {
      for x in 44..<76 {
        let i = y * width + x
        expected.append(Double(surface(x, y).x - 170 - Float(x) * 0.1))
        actual.append(Double(result[i].x - 170 - Float(x) * 0.1))
        for neighbor in [i - 1, i - width] {
          expectedEdges += pow(Double(surface(x, y).x - surface(neighbor % width, neighbor / width).x), 2)
          actualEdges += pow(Double(result[i].x - result[neighbor].x), 2)
        }
      }
    }
    func statistics(_ values: [Double]) -> (Double, Double) {
      let mean = values.reduce(0, +) / Double(values.count)
      let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
      return (mean, variance)
    }
    let (expectedMean, expectedVariance) = statistics(expected)
    let (actualMean, actualVariance) = statistics(actual)
    let varianceRatio = actualVariance / expectedVariance
    let edgeRatio = actualEdges / expectedEdges
    #expect(abs(actualMean - expectedMean) < 1.5, "Material mean error: \(actualMean - expectedMean)")
    #expect((0.5...1.6).contains(varianceRatio), "Texture variance ratio: \(varianceRatio)")
    #expect((0.5...1.6).contains(edgeRatio), "Texture edge energy ratio: \(edgeRatio)")
  }

  @Test
  func textureCannotModifyRetainedOrUnresolvedPixels() {
    let width = 64
    let height = 48
    let mask = (0..<width * height).map { i in (20..<44).contains(i % width) && (16..<32).contains(i / width) }
    let original = (0..<width * height).map { i -> SIMD4<Float> in
      let value = 190 + Self.grain(x: i % width, y: i / width, scale: 1)
      return SIMD4(value, value, value, 1)
    }
    let material = original.enumerated().map { mask[$0.offset] ? SIMD4<Float>.zero : $0.element }
    var field = original.enumerated().map { mask[$0.offset] ? SIMD4<Float>(190, 190, 190, 1) : $0.element }
    let unresolved = 24 * width + 32
    field[unresolved] = .zero
    var repeated = field
    BackgroundTexture.apply(width: width, height: height, mask: mask, material: material, field: &field)
    BackgroundTexture.apply(width: width, height: height, mask: mask, material: material, field: &repeated)
    #expect(field == repeated)
    #expect(field[unresolved] == .zero)
    #expect(original.indices.filter { !mask[$0] }.allSatisfy { field[$0] == original[$0] })
    #expect(original.indices.contains { mask[$0] && field[$0].w != 0 && field[$0].x != 190 })
  }

  @Test
  func separateSurfacesCannotExchangeTexture() {
    let width = 129
    let height = 48
    let mask = (0..<width * height).map { i in
      ((20..<44).contains(i % width) || (84..<108).contains(i % width)) && (16..<32).contains(i / width)
    }
    func restore(right: Float) -> [SIMD4<Float>] {
      let original = (0..<width * height).map { i -> SIMD4<Float> in
        let x = i % width
        guard x != 64 else { return .zero }
        let base: Float = x < 64 ? 180 : right
        let noise = Self.grain(x: x, y: i / width, scale: 1) * (x < 64 ? 1 : right / 100)
        return SIMD4(base + noise, base + noise, base + noise, 1)
      }
      let material = original.enumerated().map { mask[$0.offset] ? SIMD4<Float>.zero : $0.element }
      var field = original.enumerated().map { i, value in
        mask[i] ? SIMD4<Float>(repeating: i % width < 64 ? 180 : right) : value
      }
      for i in field.indices where mask[i] { field[i].w = 1 }
      BackgroundTexture.apply(width: width, height: height, mask: mask, material: material, field: &field)
      return field
    }
    let dark = restore(right: 30)
    let light = restore(right: 230)
    #expect(dark.indices.filter { $0 % width < 64 }.allSatisfy { dark[$0] == light[$0] })
    #expect(dark.indices.filter { $0 % width == 64 }.allSatisfy { dark[$0] == .zero && light[$0] == .zero })
  }

  @Test(arguments: [1, 2, 3])
  func curvedIlluminationDoesNotBecomeAxisAlignedBands(scale: Int) {
    let width = 80 * scale
    let height = 50 * scale
    let mask = (0..<width * height).map { index in
      let x = index % width
      let y = index / width
      return x >= 24 * scale && x < 56 * scale && y >= 18 * scale && y < 32 * scale
    }
    func field(_ x: Int, _ y: Int) -> SIMD3<Float> {
      let x = Float(x) / Float(scale) - 40
      let y = Float(y) / Float(scale) - 25
      // Each channel is harmonic on this grid. Unequal horizontal/vertical
      // brackets must not invent a different surface inside the missing area.
      return SIMD3(180 + 0.04 * (x * x - y * y), 170 + 0.03 * x * y, 200 - 0.025 * (x * x - y * y))
    }
    var maximum: Float = 0
    let unresolved = BackgroundReconstruction.fill(
      width: width,
      height: height,
      mask: mask,
      barriers: nil,
      allowsExteriorSamples: false,
      sample: field
    ) { index, color in
      guard let color else { Issue.record("Expected a bounded material solution")
        return
      }
      let expected = field(index % width, index / width)
      maximum = max(maximum, abs(color.x - expected.x), abs(color.y - expected.y), abs(color.z - expected.z))
    }
    #expect(unresolved == 0)
    #expect(maximum < 0.03, "Curved illumination maximum channel error: \(maximum)")
  }

  @Test
  func aBoundarySpeckDiffusesWithoutAHorizontalStripe() {
    let columns = 24
    let rows = 14
    let impulseRow = 7
    let width = columns + 2
    let height = rows + 2
    let mask = (0..<width * height).map { i in
      let x = i % width
      let y = i / width
      return x > 0 && x <= columns && y > 0 && y <= rows
    }
    var maximum = 0.0
    let unresolved = BackgroundReconstruction.fill(
      width: width,
      height: height,
      mask: mask,
      barriers: nil,
      allowsExteriorSamples: false
    ) { x, y in
      SIMD3<Float>(repeating: x == 0 && y == impulseRow ? 240 : 200)
    } write: { i, color in
      guard let color else { Issue.record("Expected a bounded material solution")
        return
      }
      let x = Double(i % width)
      let y = Double(i / width)
      // Independent sine-series solution of the discrete Dirichlet problem.
      // A single boundary pixel has two-dimensional influence, not a row ray.
      let expected = 200 + (1...rows).reduce(0.0) { sum, mode in
        let angle = Double(mode) * .pi / Double(rows + 1)
        let decay = acosh(2 - cos(angle))
        let amplitude = 80.0 / Double(rows + 1)
        let vertical = sin(angle * Double(impulseRow)) * sin(angle * y)
        let horizontal = sinh(decay * (Double(columns + 1) - x)) / sinh(decay * Double(columns + 1))
        return sum + amplitude * vertical * horizontal
      }
      maximum = max(maximum, abs(Double(color.x) - expected))
    }
    #expect(unresolved == 0)
    #expect(maximum < 0.01, "Boundary response maximum error: \(maximum)")
  }

  @Test
  func unmaskedNonmaterialDoesNotJoinTwoSurfaces() {
    let mask = [false, false, true, true, false, false, false]
    var colors = [SIMD3<Float>]()
    let unresolved = BackgroundReconstruction
      .fill(width: 7, height: 1, mask: mask, barriers: nil, allowsExteriorSamples: false) { x, _ in
        if x == 4 { return nil }
        return x < 4 ? SIMD3(180, 180, 180) : SIMD3(240, 100, 100)
      } write: { _, value in
        if let value { colors.append(value) }
      }
    #expect(unresolved == 0)
    #expect(colors.count == 2)
    #expect(colors.allSatisfy { $0 == SIMD3(180, 180, 180) })
  }

  @Test
  func samplesAcrossAProtectedBoundaryCannotTintTheOtherMaterial() {
    let width = 9
    let mask = [false, false, true, true, false, false, false, false, false]
    let barriers = [false, false, false, false, true, false, false, false, false]
    var result = [Int: SIMD3<Float>]()
    let unresolved = BackgroundReconstruction
      .fill(width: width, height: 1, mask: mask, barriers: barriers, allowsExteriorSamples: false) { x, _ in
        x < 4 ? SIMD3(180, 180, 180) : SIMD3(240, 100, 100)
      } write: { index, color in
        result[index] = color
      }
    #expect(unresolved == 0)
    #expect(result.keys.sorted() == [2, 3])
    #expect(result.values.allSatisfy { $0 == SIMD3(180, 180, 180) })
  }

  @Test
  func unavailableMaterialIsExplicitAndNeverInventedFromMaskedInk() {
    var unresolvedIndices = [Int]()
    let unresolved = BackgroundReconstruction.fill(
      width: 3,
      height: 2,
      mask: [true, true, false, false, true, false],
      barriers: nil,
      allowsExteriorSamples: true,
      sample: { _, _ in nil }
    ) { index, color in
      #expect(color == nil)
      unresolvedIndices.append(index)
    }
    #expect(unresolved == 3)
    #expect(unresolvedIndices.sorted() == [0, 1, 4])
  }

  @Test
  func aFullyMaskedTileCanUseVerifiedExteriorSamples() {
    var colors = [SIMD3<Float>]()
    let unresolved = BackgroundReconstruction.fill(
      width: 3,
      height: 3,
      mask: [Bool](repeating: true, count: 9),
      barriers: nil,
      allowsExteriorSamples: true
    ) { x, y in
      guard x < 0 || x >= 3 || y < 0 || y >= 3 else { return nil }
      return SIMD3(200 + Float(x) * 2, 190 + Float(y) * 3, 180)
    } write: { index, color in
      if let color {
        #expect(abs(color.x - (200 + Float(index % 3) * 2)) < 0.001)
        #expect(abs(color.y - (190 + Float(index / 3) * 3)) < 0.001)
        colors.append(color)
      }
    }
    #expect(unresolved == 0)
    #expect(colors.count == 9)
  }

  // MARK: Private

  private static func grain(x: Int, y: Int, scale: Int) -> Float {
    func noise(_ x: Int, _ y: Int) -> Float {
      var seed = UInt32(x + 1) &* 374_761_393 &+ UInt32(y + 1) &* 668_265_263
      seed = (seed ^ (seed >> 13)) &* 1_274_126_177
      seed ^= seed >> 16
      return Float(seed & 65535) / 65535 * 16 - 8
    }
    let sx = x / scale
    let sy = y / scale
    let fx = Float(x % scale) / Float(scale)
    let fy = Float(y % scale) / Float(scale)
    let upper = noise(sx, sy) * (1 - fx) + noise(sx + 1, sy) * fx
    let lower = noise(sx, sy + 1) * (1 - fx) + noise(sx + 1, sy + 1) * fx
    return upper * (1 - fy) + lower * fy
  }

}
