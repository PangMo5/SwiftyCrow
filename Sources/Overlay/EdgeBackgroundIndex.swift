// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Exact-color connectivity to the capture edge. A matching pixel has a proven
/// path to the page background and cannot belong to a closed text surface.
/// Built once at analysis resolution instead of flood-filling the same page
/// separately for every recognized line.
struct EdgeBackgroundIndex: Sendable {

  // MARK: Lifecycle

  init?(pixels: [UInt8], width: Int, height: Int) {
    guard width > 0, height > 0, pixels.count == width * height * 4 else { return nil }
    var edges = [Int]()
    for x in 0 ..< width { edges.append(x)
      edges.append((height - 1) * width + x)
    }
    for y in 0 ..< height { edges.append(y * width)
      edges.append(y * width + width - 1)
    }
    func packed(_ index: Int) -> UInt32 {
      let offset = index * 4
      return UInt32(pixels[offset]) << 16 | UInt32(pixels[offset + 1]) << 8 | UInt32(pixels[offset + 2])
    }
    var histogram = [UInt32: Int]()
    for index in edges where pixels[index * 4 + 3] > 127 { histogram[packed(index), default: 0] += 1 }
    guard let dominant = histogram.max(by: { $0.value < $1.value }), dominant.value * 5 >= edges.count else { return nil }
    let value = dominant.key
    color = OverlayColor(
      red: CGFloat((value >> 16) & 255) / 255,
      green: CGFloat((value >> 8) & 255) / 255,
      blue: CGFloat(value & 255) / 255,
      alpha: 1
    )
    var visited = [Bool](repeating: false, count: width * height)
    var queue = [Int]()
    queue.reserveCapacity(width * height)
    func enqueue(_ index: Int) {
      guard !visited[index], pixels[index * 4 + 3] > 127, packed(index) == value else { return }
      visited[index] = true
      queue.append(index)
    }
    for index in edges { enqueue(index) }
    var cursor = 0
    while cursor < queue.count {
      let index = queue[cursor]
      cursor += 1
      let x = index % width
      let y = index / width
      if x > 0 { enqueue(index - 1) }
      if x + 1 < width { enqueue(index + 1) }
      if y > 0 { enqueue(index - width) }
      if y + 1 < height { enqueue(index + width) }
    }
    connected = visited
  }

  // MARK: Internal

  let color: OverlayColor
  let connected: [Bool]

}
