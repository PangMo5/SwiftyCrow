// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// An unrelated animation must not change the interpretation of identical text
/// pixels. Reuse requires pixel proof plus compatible geometry, language and role.
enum LiveSourceIdentity {
  static func sources(
    _ current: [OverlayLine.Source],
    previous: [OverlayLine],
    verifiedBounds: [UUID: CGRect]
  ) -> [OverlayLine.Source] {
    var available = previous.indices.filter { verifiedBounds[previous[$0].id] != nil && !previous[$0].source.needsReview }
    var output = current.map { candidate in
      let match = available.first { index in
        let old = previous[index].source
        guard
          old.language == candidate.language, old.isProtectedLiteral == candidate.isProtectedLiteral,
          let bounds = verifiedBounds[previous[index].id], bounds.contains(candidate.box)
        else { return false }
        switch (old.layout, candidate.layout) {
        case (.horizontal, .horizontal): break
        case (.vertical(_, let a), .vertical(_, let b)) where a == b: break
        default: return false
        }
        let overlap = old.box.intersection(candidate.box)
        guard !overlap.isNull else { return false }
        let area = overlap.width * overlap.height
        return area / max(0.000001, old.box.width * old.box.height + candidate.box.width * candidate.box.height - area) >= 0.8
      }
      guard let match else { return candidate }
      available.removeAll { $0 == match }
      return previous[match].source
    }
    for index in available {
      let old = previous[index].source
      guard !current.contains(where: { $0.box.intersects(old.box) }) else { continue }
      let insertion = output.firstIndex { $0.box.minY > old.box.maxY } ?? output.endIndex
      output.insert(old, at: insertion)
    }
    return output
  }
}
