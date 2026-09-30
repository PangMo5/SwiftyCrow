// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Pixel ownership inferred from recognition geometry, independent of sampled
/// colors/fonts and target-language layout. It never rewrites OCR transcripts.
enum OCRSpatialOwnership {
  struct SamplingRegion: Sendable {
    /// Boundaries use normalized image coordinates, including its aspect ratio.
    /// A sample belongs to this row when a*x + b*y >= c for every boundary.
    struct Boundary: Sendable {
      var a: CGFloat
      var b: CGFloat
      var c: CGFloat
    }

    var boundaries = [Boundary]()

    var isSlanted: Bool {
      boundaries.contains { abs($0.a) > 0.000_001 }
    }

    var bounds: CGRect {
      guard !isSlanted, let range = verticalRange(at: 0.5) else {
        return isSlanted ? CGRect(x: 0, y: 0, width: 1, height: 1) : .null
      }
      return CGRect(x: 0, y: range.lowerBound, width: 1, height: range.upperBound - range.lowerBound)
    }

    func verticalRange(at x: CGFloat) -> ClosedRange<CGFloat>? {
      var lower: CGFloat = 0
      var upper: CGFloat = 1
      for edge in boundaries {
        if abs(edge.b) < 0.000_001 {
          if edge.a * x < edge.c { return nil }
        } else {
          let y = (edge.c - edge.a * x) / edge.b
          if edge.b > 0 { lower = max(lower, y) }
          else { upper = min(upper, y) }
        }
      }
      return lower <= upper ? lower...upper : nil
    }
  }

  /// Partition neighboring baselines in their common physical coordinate frame.
  /// Rotated observations need the same ownership as horizontal ones; skipping
  /// them lets an inflated OCR quad sample the next row as a larger font.
  static func samplingRegion(for line: OCRResult.Line, among lines: [OCRResult.Line]) -> SamplingRegion {
    guard !line.isVerticalBlock else { return SamplingRegion() }
    var result = SamplingRegion()
    let aspect = max(0.01, line.imageAspectRatio)
    for other in lines where !other.isVerticalBlock {
      // Crossing text directions do not establish parallel row ownership.
      guard abs(line.rotationRadians - other.rotationRadians) < .pi / 4 else { continue }
      let firstWeight = max(0.001, line.boundingBoxNormalized.width)
      let secondWeight = max(0.001, other.boundingBoxNormalized.width)
      let angle = (line.rotationRadians * firstWeight + other.rotationRadians * secondWeight)
        / (firstWeight + secondWeight)
      let (box, next) = OCRGeometry.alignedPair(line, other)
      let overlap = min(box.maxX, next.maxX) - max(box.minX, next.minX)
      guard
        overlap > min(box.width, next.width) * 0.4,
        abs(box.midY - next.midY) > min(box.height, next.height) * 0.4
      else { continue }
      let direction: CGFloat = next.midY < box.midY ? 1 : -1
      result.boundaries.append(.init(
        a: -sin(angle) * aspect * direction,
        b: cos(angle) * direction,
        c: (box.midY + next.midY) / 2 * direction
      ))
    }
    return result
  }
}
