// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Assign each observed text region to one hypothesis before any paragraph
/// joining or translation. All recognition passes use this same ownership rule.
enum OCRCandidateReconciler {

  // MARK: Internal

  static func adding(_ additional: [OCRResult.Line], to primary: [OCRResult.Line]) -> [OCRResult.Line] {
    let additions = additional.filter { candidate in
      !primary.enumerated().contains { index, existing in
        let box = candidate.boundingBoxNormalized
        let overlap = box.intersection(existing.boundingBoxNormalized)
        return !overlap.isNull && overlap.width * overlap.height >= box.width * box.height * 0.82
          && !supersedes(candidate, at: primary.count, candidate: existing, at: index)
      }
    }
    return canonical(primary + additions).sorted {
      let a = $0.boundingBoxNormalized
      let b = $1.boundingBoxNormalized
      return abs(a.minY - b.minY) <= min(a.height, b.height) * 0.35 ? a.minX < b.minX : a.minY < b.minY
    }
  }

  static func canonical(_ lines: [OCRResult.Line]) -> [OCRResult.Line] {
    lines.indices.filter { index in
      !lines.indices.contains { other in
        other != index && supersedes(lines[other], at: other, candidate: lines[index], at: index)
      }
    }.map { lines[$0] }
  }

  // MARK: Private

  private static func supersedes(_ other: OCRResult.Line, at otherIndex: Int, candidate: OCRResult.Line, at index: Int) -> Bool {
    guard other.isVerticalBlock == candidate.isVerticalBlock else { return false }
    let a = candidate.boundingBoxNormalized.standardized
    let b = other.boundingBoxNormalized.standardized
    let text = normalized(candidate.text)
    let replacement = normalized(other.text)
    guard !a.isEmpty,!b.isEmpty,!text.isEmpty else { return false }
    let overlap = a.intersection(b)
    guard !overlap.isNull else { return false }
    let coverage = overlap.width * overlap.height / (a.width * a.height)
    // A document pass can underestimate the height and misspell the same
    // physical row that a crop reads correctly. Compare row extents before
    // spelling: both hypotheses cannot independently own these glyphs.
    let sameRow = !candidate.isVerticalBlock && candidate.rowCount == 1 && other.rowCount == 1
      && overlap.width >= max(a.width, b.width) * 0.85
      && overlap.height >= min(a.height, b.height) * 0.82
      && min(a.height, b.height) >= max(a.height, b.height) * 0.35
      && abs(a.midY - b.midY) <= max(a.height, b.height) * 0.3
    let sameValue = !candidate.isVerticalBlock && candidate.rowCount == 1 && other.rowCount == 1
      && overlap.width * overlap.height >= min(a.width * a.height, b.width * b.height) * 0.82
      && min(a.width, b.width) >= max(a.width, b.width) * 0.65
      && min(a.height, b.height) >= max(a.height, b.height) * 0.35
      && abs(a.midY - b.midY) <= max(a.height, b.height) * 0.3
    let nativeOwner = other.preservesSource && other.tableCell != nil
    let existingOwner = candidate.preservesSource && candidate.tableCell != nil
    // Recognition confidence describes spelling, not permission to reclassify
    // a structured source value as prose. Keep its original-pixel ownership.
    if sameValue, nativeOwner != existingOwner { return nativeOwner }
    if sameRow, other.recognitionConfidence > candidate.recognitionConfidence + 0.15 { return true }
    if sameRow, candidate.recognitionConfidence > other.recognitionConfidence + 0.15 { return false }
    // A crop may return a prefix or suffix alongside the complete row.
    // Spatial alignment plus the shared edge identifies the same glyphs in
    // Latin, CJK, and RTL scripts; spelling equality alone cannot do this.
    let sharedEdge = min(text.count, replacement.count) >= 6
      && (text.prefix(6) == replacement.prefix(6) || text.suffix(6) == replacement.suffix(6))
    // Cropped ascenders can yield a different spelling with the same saturated
    // confidence. Shared text plus coincident row edges identifies that clipped
    // hypothesis; retain the taller, complete glyph observation.
    if
      sameRow, sharedEdge, text != replacement, a.height < b.height * 0.65,
      other.recognitionConfidence >= 0.8,
      other.recognitionConfidence >= candidate.recognitionConfidence - 0.05 { return true }
    let leadingEdgesAlign = min(abs(a.minX - b.minX), abs(a.maxX - b.maxX)) * max(0.01, candidate.imageAspectRatio)
      <= max(a.height, b.height) * 0.6
    if
      !candidate.isVerticalBlock, candidate.rowCount == 1, other.rowCount == 1,
      coverage >= 0.65, a.width < b.width * 0.75,
      min(a.height, b.height) / max(a.height, b.height) >= 0.65,
      abs(a.midY - b.midY) <= max(a.height, b.height) * 0.3,
      sharedEdge, leadingEdgesAlign,
      replacement.contains(text) || other.recognitionConfidence >= candidate.recognitionConfidence - 0.1 { return true }
    guard coverage >= 0.82 else { return false }
    if replacement.count > text.count, replacement.contains(text) { return true }
    guard replacement == text else { return false }
    let area = a.width * a.height
    let otherArea = b.width * b.height
    if abs(otherArea - area) < 0.000001 { return otherIndex < index }
    return otherArea < area
  }

  private static func normalized(_ text: String) -> String {
    text.precomposedStringWithCanonicalMapping.lowercased().unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
  }
}
