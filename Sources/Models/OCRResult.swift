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
    /// together. The renderer fills the whole box with the translation as a
    /// wrapped paragraph instead of treating it as one horizontal row.
    var isVerticalBlock = false
  }

  var lines: [Line]

  var joinedText: String {
    lines.map(\.text).joined(separator: "\n")
  }
}
