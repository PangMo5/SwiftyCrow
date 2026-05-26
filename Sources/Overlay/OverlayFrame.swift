import AppKit
import Foundation

struct OverlayFrame: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  init(rect: CGRect) {
    self.init(
      x: rect.origin.x,
      y: rect.origin.y,
      width: rect.size.width,
      height: rect.size.height
    )
  }

  // MARK: Internal

  static var `default`: OverlayFrame {
    if let screen = NSScreen.main {
      let size = CGSize(width: 520, height: 280)
      let origin = CGPoint(
        x: screen.frame.midX - size.width / 2,
        y: screen.frame.midY - size.height / 2
      )
      return OverlayFrame(rect: CGRect(origin: origin, size: size))
    }
    return OverlayFrame(x: 100, y: 100, width: 520, height: 280)
  }

  var x: Double
  var y: Double
  var width: Double
  var height: Double

  var rect: CGRect {
    CGRect(x: x, y: y, width: width, height: height)
  }

}
