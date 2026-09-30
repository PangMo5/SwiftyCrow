// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Accelerate
import Foundation

/// Reconstructs only owned mask pixels from verified material boundaries.
/// A weighted graph Laplacian avoids carrying a noisy donor across an entire
/// row/column. Retained strokes and unmasked nonmaterial remain outside the
/// domain. Components without material evidence are explicitly unresolved.
enum BackgroundReconstruction {
  typealias Color = SIMD3<Float>

  @discardableResult
  static func fill(
    width: Int,
    height: Int,
    mask: [Bool],
    barriers: [Bool]?,
    allowsExteriorSamples: Bool = false,
    sample: (Int, Int) -> Color?,
    write: (Int, Color?) -> Void
  ) -> Int {
    precondition(width > 0 && height > 0 && mask.count == width * height)
    precondition(mask.count <= Int(Int32.max))
    precondition(barriers == nil || barriers!.count == mask.count)
    var material = [SIMD4<Float>](repeating: .zero, count: mask.count)
    var indices = [Int32](repeating: -1, count: mask.count)
    var pixels = [Int]()
    for i in mask.indices where barriers?[i] != true {
      if mask[i] {
        indices[i] = Int32(pixels.count)
        pixels.append(i)
      } else if let color = sample(i % width, i / width) {
        material[i] = SIMD4(color.x, color.y, color.z, 1)
      }
    }
    let count = pixels.count
    var adjacent = [SIMD4<Int32>](repeating: SIMD4(repeating: -1), count: count)
    var diagonal = [Double](repeating: 0, count: count)
    var right = [SIMD3<Double>](repeating: .zero, count: count)
    var minimum = [Color](repeating: Color(repeating: .infinity), count: count)
    var maximum = [Color](repeating: Color(repeating: -.infinity), count: count)
    let directions = [(-1, 0), (1, 0), (0, -1), (0, 1)]
    for (node, i) in pixels.enumerated() {
      let x = i % width
      let y = i / width
      for (side, direction) in directions.enumerated() {
        let nx = x + direction.0
        let ny = y + direction.1
        var color: Color?
        let weight = 1.0
        if nx >= 0, nx < width, ny >= 0, ny < height {
          let next = ny * width + nx
          if barriers?[next] == true { continue }
          if indices[next] >= 0 { adjacent[node][side] = indices[next] }
          else if material[next].w != 0 {
            color = Color(material[next].x, material[next].y, material[next].z)
          } else {
            // A rejected, unmasked source pixel is not a missing background
            // pixel. Do not diffuse through unrelated foreground content.
            continue
          }
        } else {
          // Rejected exterior pixels may be a boundary or unrelated content.
          // Never jump across them to find a more convenient material donor.
          guard allowsExteriorSamples, let donor = sample(nx, ny) else { continue }
          color = donor
        }
        diagonal[node] += weight
        if let color {
          right[node] += SIMD3(Double(color.x), Double(color.y), Double(color.z)) * weight
          for channel in 0..<3 {
            minimum[node][channel] = min(minimum[node][channel], color[channel])
            maximum[node][channel] = max(maximum[node][channel], color[channel])
          }
        }
      }
    }

    // Classify connected domains before solving. A constant boundary has an
    // exact constant solution; a domain without a boundary has no evidence.
    var result = [SIMD4<Float>](repeating: .zero, count: count)
    var visited = [Bool](repeating: false, count: count)
    var unknown = [Int]()
    for seed in 0..<count where !visited[seed] {
      var component = [seed]
      visited[seed] = true
      var cursor = 0
      var lower = Color(repeating: .infinity)
      var upper = Color(repeating: -.infinity)
      while cursor < component.count {
        let node = component[cursor]
        cursor += 1
        for channel in 0..<3 {
          lower[channel] = min(lower[channel], minimum[node][channel])
          upper[channel] = max(upper[channel], maximum[node][channel])
        }
        for side in 0..<4 where adjacent[node][side] >= 0 {
          let next = Int(adjacent[node][side])
          if !visited[next] { visited[next] = true
            component.append(next)
          }
        }
      }
      guard lower.x.isFinite else { continue }
      if lower == upper {
        for node in component { result[node] = SIMD4(lower.x, lower.y, lower.z, 1) }
      } else { unknown += component }
    }

    if !unknown.isEmpty {
      let size = unknown.count
      precondition(size <= Int(Int32.max))
      var equation = [Int32](repeating: -1, count: count)
      for (row, node) in unknown.enumerated() { equation[node] = Int32(row) }
      var rows = [Int32]()
      var columns = [Int32]()
      var coefficients = [Double]()
      rows.reserveCapacity(size * 5)
      columns.reserveCapacity(size * 5)
      coefficients.reserveCapacity(size * 5)
      var rhs = [Double](repeating: 0, count: size * 3)
      var solution = rhs
      for (row, node) in unknown.enumerated() {
        rows.append(Int32(row))
        columns.append(Int32(row))
        coefficients.append(diagonal[node])
        for side in 0..<4 where adjacent[node][side] >= 0 {
          let column = equation[Int(adjacent[node][side])]
          precondition(column >= 0)
          rows.append(Int32(row))
          columns.append(column)
          coefficients.append(-1)
        }
        for channel in 0..<3 { rhs[channel * size + row] = right[node][channel] }
      }
      let matrix = SparseConvertFromCoordinate(
        Int32(size),
        Int32(size),
        coefficients.count,
        1,
        SparseAttributes_t(),
        rows,
        columns,
        coefficients
      )
      defer { SparseCleanup(matrix) }
      var options = SparseCGOptions()
      options.maxIterations = Int32(min(size, max(100, 4 * (width + height))))
      options.atol = 0.00000001
      options.rtol = 0.0000000001
      let status = rhs.withUnsafeMutableBufferPointer { b in
        solution.withUnsafeMutableBufferPointer { x in
          SparseSolve(
            SparseConjugateGradient(options),
            matrix,
            DenseMatrix_Double(
              rowCount: Int32(size),
              columnCount: 3,
              columnStride: Int32(size),
              attributes: SparseAttributes_t(),
              data: b.baseAddress!
            ),
            DenseMatrix_Double(
              rowCount: Int32(size),
              columnCount: 3,
              columnStride: Int32(size),
              attributes: SparseAttributes_t(),
              data: x.baseAddress!
            )
          )
        }
      }
      // Failure is not permission to invent material or copy old source ink.
      // Leave failed components unresolved so the caller can expose review.
      if status == SparseIterativeConverged {
        for (row, node) in unknown.enumerated() {
          let color = Color(Float(solution[row]), Float(solution[size + row]), Float(solution[2 * size + row]))
          if color.x.isFinite, color.y.isFinite, color.z.isFinite {
            result[node] = SIMD4(color.x, color.y, color.z, 1)
          }
        }
      }
    }
    var field = material
    for (node, pixel) in pixels.enumerated() { field[pixel] = result[node] }
    BackgroundTexture.apply(width: width, height: height, mask: mask, material: material, field: &field)
    var unresolved = 0
    for i in mask.indices where mask[i] {
      if field[i].w != 0 {
        let color = field[i]
        write(i, Color(color.x, color.y, color.z))
      } else { write(i, nil)
        unresolved += 1
      }
    }
    return unresolved
  }
}
