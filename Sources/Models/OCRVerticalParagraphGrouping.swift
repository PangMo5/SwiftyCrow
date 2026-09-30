// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// An established native paragraph supplies column pitch and its continuation
/// edge. Separate OCR paragraph IDs may then join that same physical flow,
/// but only across a pixel-verified corridor and without paragraph indentation.
enum OCRVerticalParagraphGrouping {
  struct Region {
    var box: CGRect
    var background: OverlayColor
  }

  struct Link: Hashable {
    init(_ a: Int, _ b: Int) {
      first = min(a, b)
      second = max(a, b)
    }

    let first: Int
    let second: Int

  }

  static func bounds(_ line: OCRResult.Line) -> CGRect {
    let box = (line.orientedBox ?? line.boundingBoxNormalized).standardized
    guard line.verticalCharScale.isFinite, line.verticalCharScale > 0 else { return box }
    let width = min(box.width, line.verticalCharScale * CGFloat(max(1, line.rowCount)))
    return CGRect(x: box.midX - width / 2, y: box.minY, width: width, height: box.height)
  }

  static func links(
    in lines: [OCRResult.Line],
    compatible: (OCRResult.Line, OCRResult.Line) -> Bool,
    clearExpansion: ((Region, Region) -> Bool)?
  ) -> Set<Link> {
    guard let clearExpansion else { return [] }
    let candidates = lines.indices.filter {
      let line = lines[$0]
      return line.isVerticalBlock && line.rowCount == 1 && !line.preservesSource
        && !line.preventsJoining && !line.isReconstructedTextRegion && line.text.count >= 4
        && abs(line.rotationRadians) < 0.025 && line.verticalCharScale > 0
    }
    let nativeGroups = Dictionary(grouping: candidates.filter { lines[$0].recognitionGroupID != nil }) {
      lines[$0].recognitionGroupID!
    }
    var links = Set<Link>()
    for (group, indices) in nativeGroups where indices.count >= 3 {
      let reference = lines[indices[0]]
      guard
        indices.allSatisfy({
          lines[$0].recognitionContainer == reference.recognitionContainer && compatible(reference, lines[$0])
        })
      else { continue }
      let leftToRight = OverlayTextFlowResolver.scriptEvidence(in: indices.map { lines[$0].text }.joined())
        .dominantScript == "Mong"
      let ordered = indices.sorted { leftToRight
        ? bounds(lines[$0]).midX < bounds(lines[$1]).midX
        : bounds(lines[$0]).midX > bounds(lines[$1]).midX
      }
      let boxes = ordered.map { bounds(lines[$0]) }
      let advances = zip(boxes, boxes.dropFirst()).map { abs($0.midX - $1.midX) }.sorted()
      guard
        let smallest = advances.first, let largest = advances.last, smallest > 0,
        largest <= smallest * 1.25
      else { continue }
      let advance = advances[advances.count / 2]
      let widths = boxes.map(\.width).sorted()
      guard
        advance >= widths[widths.count / 2] * 0.9,
        advance <= widths[widths.count / 2] * 2
      else { continue }
      let glyphHeight = indices.map { lines[$0].verticalCharScale * lines[$0].imageAspectRatio }.sorted()[indices.count / 2]
      let top = boxes.map(\.minY).min()!
      let anchorEdge = boxes.last!.midX
      let eligible = candidates.filter { index in
        let line = lines[index]
        guard line.recognitionContainer == reference.recognitionContainer, compatible(reference, line) else { return false }
        if line.recognitionGroupID == group { return true }
        // Measured containers remain independent. Enclosed speech balloons
        // have their own joining path; a paper paragraph cannot absorb one.
        guard line.surface == nil, reference.surface == nil else { return false }
        let box = bounds(line)
        let step = (box.midX - anchorEdge) * (leftToRight ? 1 : -1) / advance
        return step >= 0.5 && abs(step - step.rounded()) <= 0.25
          && abs(box.minY - top) <= glyphHeight * 0.65 && box.height >= glyphHeight * 4
      }.sorted { leftToRight
        ? bounds(lines[$0]).midX < bounds(lines[$1]).midX
        : bounds(lines[$0]).midX > bounds(lines[$1]).midX
      }
      // Begin with the native paragraph's existing layout envelope. Each
      // extension must certify all newly occupied space, including the area
      // beneath a short final column, before it becomes part of that envelope.
      var region = Region(
        box: indices.dropFirst().reduce(reference.boundingBoxNormalized) { $0.union(lines[$1].boundingBoxNormalized) },
        background: reference.appearance.background
      )
      var previous = ordered.last!
      for next in eligible where lines[next].recognitionGroupID != group {
        let first = bounds(lines[previous])
        let second = bounds(lines[next])
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        let extensionRegion = Region(box: lines[next].boundingBoxNormalized, background: lines[next].appearance.background)
        guard
          abs(abs(first.midX - second.midX) - advance) <= advance * 0.25,
          overlap >= min(first.height, second.height) * 0.7,
          clearExpansion(region, extensionRegion)
        else { break }
        links.insert(Link(previous, next))
        region.box = region.box.union(extensionRegion.box)
        previous = next
      }
    }
    return links
  }

  static func clearExpansion(
    from existing: Region,
    to extensionRegion: Region,
    width: Int,
    height: Int,
    sample: (Int, Int) -> OverlayColor?
  ) -> Bool {
    let canvas = CGRect(x: 0, y: 0, width: width, height: height)
    let owned = [existing.box, extensionRegion.box].map {
      CGRect(
        x: $0.minX * CGFloat(width),
        y: $0.minY * CGFloat(height),
        width: $0.width * CGFloat(width),
        height: $0.height * CGFloat(height)
      ).integral.intersection(canvas)
    }.sorted { $0.minX < $1.minX }
    guard owned.allSatisfy({ !$0.isNull && !$0.isEmpty }) else { return false }
    let envelope = owned[0].union(owned[1])
    func clear(_ start: Int, _ end: Int, _ y: Int) -> Bool {
      guard end > start else { return true }
      return (start..<end).allSatisfy { x in
        guard let color = sample(x, y) else { return false }
        return color.distance(to: existing.background) <= 0.06 && color.distance(to: extensionRegion.background) <= 0.06
      }
    }
    for y in Int(envelope.minY)..<Int(envelope.maxY) {
      var cursor = Int(envelope.minX)
      for region in owned where CGFloat(y) >= region.minY && CGFloat(y) < region.maxY {
        guard clear(cursor, Int(region.minX), y) else { return false }
        cursor = max(cursor, Int(region.maxX))
      }
      guard clear(cursor, Int(envelope.maxX), y) else { return false }
    }
    return true
  }
}
