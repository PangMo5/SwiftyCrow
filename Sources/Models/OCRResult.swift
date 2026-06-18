import Foundation

struct OCRResult: Equatable, Sendable {
  /// A single recognized line with its position on the captured frame.
  struct Line: Equatable, Sendable, Hashable {
    /// Top-left origin, 0–1 normalized to the captured frame.
    var boundingBoxNormalized: CGRect
    var text: String
    /// How many source rows this line spans. >1 after wrapped lines are
    /// stitched into one sentence, so the renderer can size the font to a
    /// single row and wrap the text instead of stretching it.
    var rowCount = 1
    /// True when this is a block of vertical (top-to-bottom) CJK columns stitched
    /// together. The renderer lays the translation out vertically over the box.
    var isVerticalBlock = false
    /// For a vertical block, the source character size (a column's width, 0–1
    /// normalized) — lets the renderer match the original font scale so titles
    /// stay large and annotations small, preserving the page's text hierarchy.
    var verticalCharScale: CGFloat = 0
  }

  var lines: [Line]

  var joinedText: String {
    lines.map(\.text).joined(separator: "\n")
  }
}
