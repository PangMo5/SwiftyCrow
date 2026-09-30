// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Transfers locally detrended material samples into a reconstructed surface.
/// The smooth field carries illumination; observed patches carry texture. No
/// random colour is generated, and neither protected nor unresolved pixels are
/// eligible for synthesis. All work and storage are bounded by the tile size.
enum BackgroundTexture {

  // MARK: Internal

  typealias Color = SIMD3<Float>

  static func apply(width: Int, height: Int, mask: [Bool], material: [SIMD4<Float>], field: inout [SIMD4<Float>]) {
    let radius = 4
    let side = radius * 2 + 1
    let distances = [1, 2, radius]
    let directions = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    guard width >= side, height >= side else { return }
    var texturedSamples = 0
    for y in radius..<height - radius {
      for x in radius..<width - radius {
        let i = y * width + x
        guard material[i].w != 0 else { continue }
        for distance in distances {
          guard
            material[i - distance].w != 0, material[i + distance].w != 0,
            material[i - distance * width].w != 0, material[i + distance * width].w != 0
          else { continue }
          let residual = material[i] - (material[i - distance] + material[i + distance] +
            material[i - distance * width] + material[i + distance * width]) / 4
          if magnitude(residual) > 0.75 {
            texturedSamples += 1
            break
          }
        }
      }
    }
    guard texturedSamples >= 8 else { return }

    // Labels include verified material and resolved holes, but not rejected
    // source pixels. Neither the low-pass filter nor exemplar selection may
    // cross a protected boundary to borrow another surface's texture.
    var labels = [Int](repeating: -1, count: mask.count)
    var domains = [[Int]]()
    for seed in field.indices where field[seed].w != 0 && labels[seed] < 0 {
      let label = domains.count
      var pixels = [seed]
      labels[seed] = label
      var cursor = 0
      while cursor < pixels.count {
        let i = pixels[cursor]
        cursor += 1
        let x = i % width
        let y = i / width
        for (dx, dy) in directions {
          let nx = x + dx
          let ny = y + dy
          guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
          let next = ny * width + nx
          if field[next].w != 0, labels[next] < 0 {
            labels[next] = label
            pixels.append(next)
          }
        }
      }
      domains.append(pixels)
    }

    // Test complete observed patches before allocating colour moments or
    // fitting planes. Flat/quantized material often has a few edge samples,
    // which must not make every otherwise smooth surface pay for synthesis.
    let countStride = width + 1
    var validCounts = [Int](repeating: 0, count: countStride * (height + 1))
    for y in 0..<height {
      var row = 0
      for x in 0..<width {
        if material[y * width + x].w != 0 { row += 1 }
        let i = (y + 1) * countStride + x + 1
        validCounts[i] = validCounts[i - countStride] + row
      }
    }
    func completePatch(x: Int, y: Int, radius: Int) -> Bool {
      guard x >= radius, x < width - radius, y >= radius, y < height - radius else { return false }
      let side = radius * 2 + 1
      let a = (y - radius) * countStride + x - radius
      let b = a + side
      let c = a + side * countStride
      let d = c + side
      return validCounts[d] - validCounts[b] - validCounts[c] + validCounts[a] == side * side
    }
    var centers = [[Int]](repeating: [], count: domains.count)
    var residuals = [[Float]](repeating: [], count: domains.count)
    var frequency = [Frequency](repeating: Frequency(), count: domains.count)
    for y in radius..<height - radius {
      for x in radius..<width - radius {
        let i = y * width + x
        let label = labels[i]
        guard label >= 0, material[i].w != 0 else { continue }
        guard completePatch(x: x, y: y, radius: radius) else { continue }
        centers[label].append(i)
        var magnitude: Float = 0
        for distance in distances {
          let laplacian = material[i] - (material[i - distance] + material[i + distance] +
            material[i - distance * width] + material[i + distance * width]) / 4
          magnitude = max(magnitude, Self.magnitude(laplacian))
          let value = SIMD3(Double(laplacian.x), Double(laplacian.y), Double(laplacian.z))
          if distance == 1 { frequency[label].fine += value
            frequency[label].energy.x += (value * value).sum()
          }
          if distance == radius { frequency[label].coarse += value
            frequency[label].energy.y += (value * value).sum()
          }
        }
        residuals[label].append(magnitude)
      }
    }

    // Enlarge support when the observed grain has a longer correlation
    // length. Squared second differences give the fourth-root scale estimate.
    var radii = [Int](repeating: radius, count: domains.count)
    var enabled = [Bool](repeating: false, count: domains.count)
    for label in domains.indices where centers[label].count >= 8 {
      guard domains[label].contains(where: { mask[$0] }) else { continue }
      residuals[label].sort()
      guard residuals[label][residuals[label].count / 2] > 0.75 else { continue }
      let count = Double(centers[label].count)
      let fineMean = frequency[label].fine / count
      let coarseMean = frequency[label].coarse / count
      let fine = max(0, frequency[label].energy.x / count - (fineMean * fineMean).sum())
      let coarse = max(0, frequency[label].energy.y / count - (coarseMean * coarseMean).sum())
      if fine > 0 {
        radii[label] = min(8, max(radius, Int((Double(radius) * pow(coarse / fine, 0.25)).rounded())))
      }
      if radii[label] > radius {
        centers[label] = centers[label].filter { completePatch(x: $0 % width, y: $0 / width, radius: radii[label]) }
      }
      enabled[label] = centers[label].count >= 8
    }
    guard enabled.contains(true) else { return }

    // Prefix moments make a plane fit constant work per candidate instead of
    // rereading every pixel of overlapping patches. Double avoids cancellation
    // when subtracting moments near the far edge of a large tile.
    let stride = width + 1
    let prefixCount = stride * (height + 1)
    var sums = [SIMD4<Double>](repeating: .zero, count: prefixCount)
    var horizontal = [SIMD3<Double>](repeating: .zero, count: prefixCount)
    var vertical = horizontal
    for y in 0..<height {
      var row = SIMD4<Double>.zero
      var rowX = SIMD3<Double>.zero
      var rowY = SIMD3<Double>.zero
      for x in 0..<width {
        let value = material[y * width + x]
        let color = SIMD3(Double(value.x), Double(value.y), Double(value.z))
        row += SIMD4(color.x, color.y, color.z, Double(value.w))
        rowX += color * Double(x)
        rowY += color * Double(y)
        let i = (y + 1) * stride + x + 1
        sums[i] = sums[i - stride] + row
        horizontal[i] = horizontal[i - stride] + rowX
        vertical[i] = vertical[i - stride] + rowY
      }
    }
    func patch(x: Int, y: Int, radius: Int) -> Patch? {
      guard x >= radius, x < width - radius, y >= radius, y < height - radius else { return nil }
      let side = radius * 2 + 1
      let area = Double(side * side)
      let moment = Double(side * radius * (radius + 1) * (2 * radius + 1)) / 3
      let a = (y - radius) * stride + x - radius
      let b = a + side
      let c = a + side * stride
      let d = c + side
      let total = sums[d] - sums[b] - sums[c] + sums[a]
      guard total.w == area else { return nil }
      let color = SIMD3(total.x, total.y, total.z)
      let dx = (horizontal[d] - horizontal[b] - horizontal[c] + horizontal[a] - color * Double(x)) / moment
      let dy = (vertical[d] - vertical[b] - vertical[c] + vertical[a] - color * Double(y)) / moment
      let mean = color / area
      return Patch(
        index: y * width + x,
        mean: Color(Float(mean.x), Float(mean.y), Float(mean.z)),
        horizontal: Color(Float(dx.x), Float(dx.y), Float(dx.z)),
        vertical: Color(Float(dy.x), Float(dy.y), Float(dy.z))
      )
    }
    var catalogs = [[Patch]](repeating: [], count: domains.count)
    for label in domains.indices where enabled[label] {
      catalogs[label] = centers[label].compactMap { patch(x: $0 % width, y: $0 / width, radius: radii[label]) }
    }

    // A shared index maps each surface into compact scratch storage. Sparse
    // domains do not allocate or scan the entire tile once per surface.
    var positions = [Int](repeating: -1, count: mask.count)
    for pixels in domains {
      for (position, pixel) in pixels.enumerated() { positions[pixel] = position }
    }
    for label in domains.indices where enabled[label] {
      let patches = catalogs[label]
      synthesize(
        width: width,
        height: height,
        mask: mask,
        material: material,
        field: &field,
        labels: labels,
        positions: positions,
        label: label,
        pixels: domains[label],
        patches: patches,
        radius: radii[label]
      )
    }
  }

  // MARK: Private

  private struct Patch {
    var index: Int
    var mean: Color
    var horizontal: Color
    var vertical: Color
  }

  private struct Frequency {
    var fine = SIMD3<Double>.zero
    var coarse = SIMD3<Double>.zero
    var energy = SIMD2<Double>.zero
  }

  private static func magnitude(_ value: SIMD4<Float>) -> Float {
    sqrt((value.x * value.x + value.y * value.y + value.z * value.z) / 3)
  }

  private static func synthesize(
    width: Int,
    height: Int,
    mask: [Bool],
    material: [SIMD4<Float>],
    field: inout [SIMD4<Float>],
    labels: [Int],
    positions: [Int],
    label: Int,
    pixels: [Int],
    patches: [Patch],
    radius: Int
  ) {
    let blockSide = radius * 2 - 1
    let columns = (width + blockSide - 1) / blockSide
    var lookup = [Int](repeating: -1, count: pixels.count)
    for (index, patch) in patches.enumerated() { lookup[positions[patch.index]] = index }
    var selected = [Int: Int]()
    var activeBlocks = Set<Int>()
    for i in pixels where mask[i] { activeBlocks.insert((i / width / blockSide) * columns + i % width / blockSide) }
    var filled = [Bool](repeating: false, count: pixels.count)
    var minimum = Color(repeating: .infinity)
    var maximum = Color(repeating: -.infinity)
    for i in pixels where material[i].w != 0 {
      for channel in 0..<3 {
        minimum[channel] = min(minimum[channel], material[i][channel])
        maximum[channel] = max(maximum[channel], material[i][channel])
      }
    }
    let weights: [Float] = [1, 4, 6, 4, 1]
    var temporary = [SIMD4<Float>](repeating: .zero, count: pixels.count)
    var base = temporary
    for i in pixels {
      let x = i % width
      for dx in -2..<3 where x + dx >= 0 && x + dx < width && labels[i + dx] == label {
        if dx == -2, labels[i - 1] != label { continue }
        if dx == 2, labels[i + 1] != label { continue }
        temporary[positions[i]] += field[i + dx] * weights[dx + 2]
      }
    }
    for i in pixels {
      let y = i / width
      for dy in -2..<3 where y + dy >= 0 && y + dy < height && labels[i + dy * width] == label {
        if dy == -2, labels[i - width] != label { continue }
        if dy == 2, labels[i + width] != label { continue }
        base[positions[i]] += temporary[positions[i + dy * width]] * weights[dy + 2]
      }
      base[positions[i]] /= base[positions[i]].w
    }
    func residual(_ patch: Patch, _ dx: Int, _ dy: Int) -> Color {
      let value = material[patch.index + dy * width + dx]
      return Color(value.x, value.y, value.z) - patch.mean - patch.horizontal * Float(dx) - patch.vertical * Float(dy)
    }
    for block in activeBlocks.sorted() {
      let by = block / columns
      let bx = block % columns
      let x = bx * blockSide + radius - 1
      let y = by * blockSide + radius - 1
      var targets = [(Int, Int, Int)]()
      var samples = [(Int, Int, Color, Color)]()
      for dy in -radius..<(radius + 1) where y + dy >= 0 && y + dy < height {
        for dx in -radius..<(radius + 1) where x + dx >= 0 && x + dx < width {
          let i = (y + dy) * width + x + dx
          guard labels[i] == label else { continue }
          if abs(dx) < radius, abs(dy) < radius, mask[i] { targets.append((i, dx, dy)) }
          if !mask[i] || filled[positions[i]] {
            samples.append((
              dx,
              dy,
              Color(base[positions[i]].x, base[positions[i]].y, base[positions[i]].z),
              Color(field[i].x, field[i].y, field[i].z)
            ))
          }
        }
      }
      guard !targets.isEmpty else { continue }
      var candidates = [Int]()
      for (nx, ny) in [(bx - 1, by), (bx, by - 1)] where nx >= 0 && ny >= 0 {
        guard let previous = selected[ny * columns + nx] else { continue }
        let donor = patches[previous].index
        let donorX = donor % width + (bx - nx) * blockSide
        let donorY = donor / width + (by - ny) * blockSide
        if donorX >= 0, donorX < width, donorY >= 0, donorY < height {
          let pixel = donorY * width + donorX
          if labels[pixel] == label {
            let candidate = lookup[positions[pixel]]
            if candidate >= 0 { candidates.append(candidate) }
          }
        }
      }
      // Stable candidate sampling gives reproducible images without a
      // process-seeded Hasher or an exhaustive pixel-by-patch search.
      var random = UInt64(block + 1) &* 0x9E37_79B9_7F4A_7C15
      for _ in 0..<8 {
        random ^= random >> 12
        random ^= random << 25
        random ^= random >> 27
        candidates.append(Int((random &* 0x2545_F491_4F6C_DD1D) % UInt64(patches.count)))
      }
      var best = candidates[0]
      var bestScore = Float.infinity
      let anchor = positions[targets[0].0]
      let targetMean = Color(base[anchor].x, base[anchor].y, base[anchor].z)
      for candidate in candidates {
        let patch = patches[candidate]
        let meanError = patch.mean - targetMean
        var score = (meanError * meanError).sum() * 0.1
        for (dx, dy, low, actual) in samples {
          let error = low + residual(patch, dx, dy) - actual
          score += (error * error).sum()
        }
        if score < bestScore { best = candidate
          bestScore = score
        }
      }
      selected[block] = best
      for (i, dx, dy) in targets {
        let low = Color(base[positions[i]].x, base[positions[i]].y, base[positions[i]].z)
        var value = low + residual(patches[best], dx, dy)
        // Transferring a residual to different illumination can overshoot.
        // Preserve the observed material gamut rather than introducing a
        // new highlight/shadow that can resemble the erased glyph contour.
        for channel in 0..<3 { value[channel] = min(maximum[channel], max(minimum[channel], value[channel])) }
        field[i] = SIMD4(value.x, value.y, value.z, 1)
        filled[positions[i]] = true
      }
    }
  }
}
