import CoreGraphics
import Foundation

/// A recognized line together with whatever translation is currently known.
/// `translated == nil` means the line is still in flight. `box` is top-left
/// origin, 0–1 normalized to the captured frame.
struct OverlayLine: Equatable, Identifiable, Sendable {
  let id: UUID
  var box: CGRect
  var sourceText: String
  var translated: String?
}
