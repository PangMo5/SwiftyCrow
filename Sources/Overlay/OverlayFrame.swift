// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation

struct OverlayFrame: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init(x: Double, y: Double, width: Double, height: Double, hasSelection: Bool = true) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
    self.hasSelection = hasSelection
  }

  init(rect: CGRect) {
    self.init(
      x: rect.origin.x,
      y: rect.origin.y,
      width: rect.size.width,
      height: rect.size.height
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
  }

  // MARK: Internal

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

  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

}
