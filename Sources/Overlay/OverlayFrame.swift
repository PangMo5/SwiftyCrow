// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

struct OverlayFrame: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init(
    x: Double,
    y: Double,
    width: Double,
    height: Double,
    hasSelection: Bool = true,
    selectionKind: SelectionKind = .region
  ) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.hasSelection = hasSelection
    self.selectionKind = selectionKind
  }

  init(rect: CGRect, selectionKind: SelectionKind = .region) {
    self.init(
      x: rect.origin.x,
      y: rect.origin.y,
      width: rect.size.width,
      height: rect.size.height,
      selectionKind: selectionKind
    )
  }

  init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    x = try values.decode(Double.self, forKey: .x)
    y = try values.decode(Double.self, forKey: .y)
    width = try values.decode(Double.self, forKey: .width)
    height = try values.decode(Double.self, forKey: .height)
    // Older saved frames came from the already placed overlay.
    hasSelection = try values.decodeIfPresent(Bool.self, forKey: .hasSelection) ?? true
    // Before window tracking existed, persisted selections were fixed regions.
    selectionKind = try values.decodeIfPresent(SelectionKind.self, forKey: .selectionKind) ?? .region
  }

  // MARK: Internal

  enum SelectionKind: String, Codable, Sendable {
    case region
    case window
  }

  static var `default`: OverlayFrame {
    if let screen = NSScreen.main {
      let size = CGSize(width: 520, height: 280)
      let origin = CGPoint(
        x: screen.frame.midX - size.width / 2,
        y: screen.frame.midY - size.height / 2
      )
      return OverlayFrame(x: origin.x, y: origin.y, width: size.width, height: size.height, hasSelection: false)
    }
    return OverlayFrame(x: 100, y: 100, width: 520, height: 280, hasSelection: false)
  }

  var x: Double
  var y: Double
  var width: Double
  var height: Double
  var hasSelection: Bool
  var selectionKind: SelectionKind

  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

  /// Moving/resizing a panel must never create a selection or change its kind.
  mutating func updateGeometry(_ rect: CGRect) {
    x = rect.origin.x
    y = rect.origin.y
    width = rect.size.width
    height = rect.size.height
  }
}
