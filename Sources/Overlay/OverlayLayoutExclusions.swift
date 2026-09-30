// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Finds a rectangular text area without painting retained source content.
/// Coordinate compression keeps the cost tied to contour complexity, not the
/// capture's pixel count. Weighted histogram rows retain physical dimensions.
enum OverlayLayoutExclusions {
  static func largestRectangle(
    in frame: CGRect,
    excluding obstacles: [CGRect],
    allowed: [CGRect] = [],
    alignment: OverlayTextAlignment
  ) -> CGRect? {
    guard !frame.isEmpty, !frame.isNull else { return nil }
    let blocked = obstacles.map { $0.intersection(frame) }.filter { !$0.isNull && !$0.isEmpty }
    let permitted = allowed.map { $0.intersection(frame) }.filter { !$0.isNull && !$0.isEmpty }
    if blocked.isEmpty, allowed.isEmpty { return frame }
    if !allowed.isEmpty, permitted.isEmpty { return nil }
    func unique(_ values: [CGFloat]) -> [CGFloat] {
      values.sorted().reduce(into: []) { result, value in
        if result.last.map({ value - $0 > 0.000_001 }) ?? true { result.append(value) }
      }
    }
    let rectangles = blocked + permitted
    let xs = unique([frame.minX, frame.maxX] + rectangles.flatMap { [$0.minX, $0.maxX] })
    let ys = unique([frame.minY, frame.maxY] + rectangles.flatMap { [$0.minY, $0.maxY] })
    guard xs.count >= 2, ys.count >= 2 else { return nil }
    let columns = xs.count
    func coverage(_ rectangles: [CGRect]) -> [Int] {
      var difference = [Int](repeating: 0, count: columns * ys.count)
      for rect in rectangles {
        let left = xs.firstIndex { abs($0 - rect.minX) <= 0.000_001 }!
        let right = xs.firstIndex { abs($0 - rect.maxX) <= 0.000_001 }!
        let top = ys.firstIndex { abs($0 - rect.minY) <= 0.000_001 }!
        let bottom = ys.firstIndex { abs($0 - rect.maxY) <= 0.000_001 }!
        difference[top * columns + left] += 1
        difference[top * columns + right] -= 1
        difference[bottom * columns + left] -= 1
        difference[bottom * columns + right] += 1
      }
      for row in ys.indices {
        for column in xs.indices {
          let index = row * columns + column
          if row > 0 { difference[index] += difference[index - columns] }
          if column > 0 { difference[index] += difference[index - 1] }
          if row > 0, column > 0 { difference[index] -= difference[index - columns - 1] }
        }
      }
      return difference
    }
    let occupied = coverage(blocked)
    let available = allowed.isEmpty ? nil : coverage(permitted)
    var heights = [CGFloat](repeating: 0, count: columns - 1)
    var best: CGRect?
    var bestArea: CGFloat = 0
    var bestDistance = CGFloat.greatestFiniteMagnitude
    func consider(_ rect: CGRect) {
      let area = rect.width * rect.height
      guard area > 0.000_001 else { return }
      let dx: CGFloat =
        switch alignment {
        case .leading: rect.minX - frame.minX
        case .center: rect.midX - frame.midX
        case .trailing: rect.maxX - frame.maxX
        }
      let dy = rect.midY - frame.midY
      let distance = dx * dx + dy * dy
      if area > bestArea + 0.000_001 || (abs(area - bestArea) <= 0.000_001 && distance < bestDistance - 0.000_001) {
        best = rect
        bestArea = area
        bestDistance = distance
      }
    }
    for row in 0..<(ys.count - 1) {
      let advance = ys[row + 1] - ys[row]
      for column in heights.indices {
        let index = row * columns + column
        heights[column] = occupied[index] == 0 && (available.map { $0[index] > 0 } ?? true)
          ? heights[column] + advance
          : 0
      }
      var stack = [(start: Int, height: CGFloat)]()
      for column in 0...heights.count {
        let height = column < heights.count ? heights[column] : 0
        var start = column
        while let last = stack.last, last.height > height {
          stack.removeLast()
          consider(CGRect(
            x: xs[last.start],
            y: ys[row + 1] - last.height,
            width: xs[column] - xs[last.start],
            height: last.height
          ))
          start = last.start
        }
        if height > 0, stack.last?.height != height { stack.append((start, height)) }
      }
    }
    return best
  }
}
