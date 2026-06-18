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
  /// Number of source rows `box` spans; >1 for sentences stitched from wrapped
  /// lines, so the renderer wraps the text instead of drawing one giant row.
  var rowCount = 1
  /// True when `box` covers a block of stitched vertical CJK columns, so the
  /// renderer lays the translation out vertically (top-to-bottom, right-to-left).
  var isVerticalBlock = false
  /// Source character size for a vertical block (a column's width, 0–1
  /// normalized), so the renderer can match the original font scale.
  var verticalCharScale: CGFloat = 0
}
