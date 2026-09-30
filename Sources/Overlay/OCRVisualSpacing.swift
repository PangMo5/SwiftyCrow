// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Vision's range boxes can distribute whitespace across neighboring words.
/// Recover visible gaps before treating compact controls as one paragraph.
enum OCRVisualSpacing {

  // MARK: Internal

  static func refining(
    _ result: OCRResult,
    width: Int,
    height: Int,
    sample: (Int, Int) -> OverlayColor?
  ) -> OCRResult {
    let lines = result.lines.flatMap { line -> [OCRResult.Line] in
      guard
        !line.preservesSource, !line.isVerticalBlock, line.rowCount == 1,
        abs(line.rotationRadians) < 0.025, line.text.count <= 80,
        line.text.last.map({ !".!?。！？".contains($0) }) == true,
        !OCRTextSemantics.isCode(line.text), !OCRTextSemantics.isIdentifier(line.text),
        line.styleRuns.allSatisfy({ distance($0.appearance.background, line.appearance.background) < 0.08 })
      else { return [line] }
      let box = line.boundingBoxNormalized
      let peers = result.lines.count { other in
        let peer = other.boundingBoxNormalized
        return abs(peer.midY - box.midY) < min(peer.height, box.height) * 0.45
          && min(peer.height, box.height) / max(peer.height, box.height) >= 0.6
      }
      let hasControlSeparator = line.text.contains("›") || line.text.contains("»")
      let lexicalPrefix = String(line.text.prefix(while: { !$0.isWhitespace }))
      let prefix = line.styleRuns.first.map { $0.range.location == 0 && $0.range.length == 1 } == true
        ? String(line.text.prefix(1))
        : lexicalPrefix
      let possibleIcon = prefix.count == 1 && !["•", "·", "●", "▪", "◦", "-", "*", "+"].contains(prefix)
        && line.text.dropFirst(prefix.count).contains(where: \.isLetter)
      guard peers >= 3 || hasControlSeparator || possibleIcon || !line.spacingAnchors.isEmpty || line.styleRuns.count >= 3
      else { return [line] }
      let pixelBox = CGRect(
        x: box.minX * CGFloat(width),
        y: box.minY * CGFloat(height),
        width: box.width * CGFloat(width),
        height: box.height * CGFloat(height)
      )
      .integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
      guard !pixelBox.isNull, pixelBox.width > 1, pixelBox.height > 2 else { return [line] }
      let threshold = max(0.06, distance(line.appearance.foreground, line.appearance.background) * 0.3)
      var columns = [Int]()
      var minY = Int.max
      var maxY = Int.min
      for x in Int(pixelBox.minX)..<Int(pixelBox.maxX) {
        var count = 0
        for y in Int(pixelBox.minY)..<Int(pixelBox.maxY) {
          guard let color = sample(x, y), distance(color, line.appearance.background) >= threshold else { continue }
          count += 1
          minY = min(minY, y)
          maxY = max(maxY, y)
        }
        if count >= 2 { columns.append(x) }
      }
      guard let first = columns.first, let last = columns.last, maxY >= minY else { return [line] }
      let inkHeight = CGFloat(maxY - minY + 1)
      // Ink height alone is not a whitespace metric: in a widely tracked or
      // monospaced face an ordinary space can exceed the lowercase x-height.
      // Word advances provide a second, font-relative boundary without making
      // prose in a monospace font a special kind of content.
      let advances = line.styleRuns.compactMap { run -> CGFloat? in
        guard run.range.length >= 3 else { return nil }
        return run.box.width * CGFloat(width) / CGFloat(run.range.length)
      }.sorted()
      let advance = advances.isEmpty ? 0 : advances[advances.count / 2]
      let minimumGap = max(3, inkHeight * 0.85, advance * 1.8)
      var gaps = zip(columns, columns.dropFirst()).filter { CGFloat($1 - $0 - 1) >= minimumGap }
      var accessoryBoundary: Int?
      let prefixEnd = line.styleRuns.first(where: { $0.range.location == 0 && NSMaxRange($0.range) == prefix.utf16.count })?.box
        .maxX
      let labelStart = line.styleRuns.first(where: { $0.range.location >= prefix.utf16.count })?.box.minX
      let expectedBoundary = (prefixEnd ?? box.minX) * CGFloat(width) / 2 + (labelStart ?? box.minX) * CGFloat(width) / 2
      let iconGap = zip(columns, columns.dropFirst()).filter { $1 - $0 > 3 }.min {
        abs(CGFloat($0.0 + $0.1) / 2 - expectedBoundary) < abs(CGFloat($1.0 + $1.1) / 2 - expectedBoundary)
      }
      if possibleIcon, let gap = iconGap {
        let occupied = (Int(pixelBox.minY)..<Int(pixelBox.maxY)).filter { y in
          (first...gap.0).contains { x in
            sample(x, y).map { distance($0, line.appearance.background) >= threshold } ?? false
          }
        }
        if let top = occupied.first, let bottom = occupied.last {
          let height = CGFloat(bottom - top + 1)
          let glyphWidth = CGFloat(gap.0 - first + 1)
          func marked(_ x: Int, _ y: Int) -> Bool {
            sample(x, y).map { distance($0, line.appearance.background) >= threshold } ?? false
          }
          let centerX = (first + gap.0) / 2
          let centerY = (top + bottom) / 2
          let hollow = !(max(first, centerX - 2)...min(gap.0, centerX + 2)).contains { x in
            (max(top, centerY - 2)...min(bottom, centerY + 2)).contains { marked(x, $0) }
          }
          let enclosing = (top...bottom).contains { marked(first, $0) }
            && (top...bottom).contains { marked(gap.0, $0) }
            && (first...gap.0).contains { marked($0, top) }
            && (first...gap.0).contains { marked($0, bottom) }
          let repeatedControls = result.lines.count { other in
            abs(other.boundingBoxNormalized.minX - box.minX) * line.imageAspectRatio <= box.height * 0.75
              && abs(other.boundingBoxNormalized.midY - box.midY) <= box.height * 8
              && other.text.split(whereSeparator: \.isWhitespace).count <= 4
          } >= 3
          let outlinedControl = hollow && enclosing && repeatedControls
            && glyphWidth >= height * 0.8 && glyphWidth <= height * 1.3
          if
            height <= inkHeight * 0.7 || outlinedControl, glyphWidth >= height * 0.8, glyphWidth <= height * 2,
            CGFloat(gap.1 - gap.0 - 1) >= height * (outlinedControl ? 0.25 : 0.5)
          {
            if !gaps.contains(where: { $0.0 == gap.0 }) { gaps.append(gap) }
            accessoryBoundary = prefix.utf16.count
          }
        }
      }
      let text = line.text as NSString
      var spaces = whitespace.matches(in: line.text, range: NSRange(location: 0, length: text.length)).map(\.range)
      if let boundary = accessoryBoundary, !spaces.contains(where: { $0.location == boundary }) {
        spaces.append(NSRange(location: boundary, length: 0))
      }
      for (a, b) in zip(line.text.indices, line.text.indices.dropFirst()) where
        OCRTextTokenization.hasUnspacedBoundary(between: line.text[a], and: line.text[b])
      {
        spaces.append(NSRange(location: NSRange(line.text.startIndex..<b, in: line.text).length, length: 0))
      }
      let anchors = line.spacingAnchors.isEmpty
        ? line.styleRuns.map { OCRTextAnchor(range: $0.range, box: $0.box) }
        : line.spacingAnchors
      let reversed = (anchors.first?.box.midX ?? 0) > (anchors.last?.box.midX ?? 1)
      var cuts = [(range: NSRange, x: CGFloat)]()
      for (left, right) in gaps {
        let center = CGFloat(left + right) / 2
        let match = spaces.compactMap { space -> (NSRange, CGFloat)? in
          guard
            let before = anchors.last(where: { NSMaxRange($0.range) <= space.location }),
            let after = anchors.first(where: { $0.range.location >= NSMaxRange(space) })
          else { return nil }
          let expected = (reversed ? before.box.minX + after.box.maxX : before.box.maxX + after.box.minX) * CGFloat(width) / 2
          return (space, abs(expected - center))
        }.min(by: { $0.1 < $1.1 })
        if let match, match.1 <= inkHeight * 1.5, !cuts.contains(where: { $0.range == match.0 }) {
          cuts.append((match.0, center))
        }
      }
      cuts.sort { $0.range.location < $1.range.location }
      guard !cuts.isEmpty || peers >= 3 || hasControlSeparator else { return [line] }
      // Both coordinate and transcript order must agree; otherwise do not split.
      guard zip(cuts, cuts.dropFirst()).allSatisfy({ reversed ? $0.x > $1.x : $0.x < $1.x }) else { return [line] }
      let starts = [0] + cuts.map { NSMaxRange($0.range) }
      let ends = cuts.map(\.range.location) + [text.length]
      let edges = [CGFloat(first) - 1] + cuts.map(\.x).sorted() + [CGFloat(last) + 2]
      let fragments = starts.indices.compactMap { index -> OCRResult.Line? in
        let range = NSRange(location: starts[index], length: ends[index] - starts[index])
        var fragment = line
        fragment.text = text.substring(with: range)
        let physicalIndex = reversed ? starts.count - index - 1 : index
        let occupied = columns.filter { CGFloat($0) >= edges[physicalIndex] && CGFloat($0) < edges[physicalIndex + 1] }
        guard let start = occupied.first, let end = occupied.last else { return nil }
        let refined = CGRect(
          x: CGFloat(start - 1) / CGFloat(width),
          y: box.minY,
          width: CGFloat(end - start + 3) / CGFloat(width),
          height: box.height
        )
        fragment.boundingBoxNormalized = refined
        fragment.orientedBox = nil
        fragment.spacingAnchors = []
        fragment.styleRuns = line.styleRuns.compactMap { run in
          let intersection = NSIntersectionRange(run.range, range)
          guard intersection.length > 0 else { return nil }
          var run = run
          run.range = NSRange(location: intersection.location - range.location, length: intersection.length)
          run.box = run.box.intersection(refined)
          return run.box.isNull ? nil : run
        }
        // A partial intersection still carries the parent's measurement. Only
        // wholly retained runs can establish this fragment's own typography.
        if starts.count > 1 {
          fragment.adoptFragmentAppearance(from: line.styleRuns.compactMap { original in
            guard
              original.range.length > 0,
              NSIntersectionRange(original.range, range).length == original.range.length
            else { return nil }
            var run = original
            run.range.location -= range.location
            return run
          })
        }
        fragment.replacementPatches = [.init(
          box: refined,
          appearance: fragment.appearance,
          clippingBox: line.replacementPatches.compactMap(\.clippingBox).first
        )]
        // A visible control boundary must survive every later coalescing pass.
        fragment.preventsJoining = line.preventsJoining || !cuts.isEmpty
        if let accessoryBoundary, range.location == 0, NSMaxRange(range) == accessoryBoundary {
          fragment.preservesSource = true
        }
        if !cuts.isEmpty { fragment.surface = nil
          fragment.alignment = .leading
        }
        return fragment
      }
      return fragments.count == starts.count ? fragments : [line]
    }
    return OCRResult(lines: lines)
  }

  // MARK: Private

  private static let whitespace = try! NSRegularExpression(pattern: #"\s+"#)

  private static func distance(_ a: OverlayColor, _ b: OverlayColor) -> CGFloat {
    max(abs(a.red - b.red), abs(a.green - b.green), abs(a.blue - b.blue))
  }
}
