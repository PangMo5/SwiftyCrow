import Foundation

struct OCRResult: Equatable, Sendable {
  /// A single recognized line with its position on the captured frame.
  struct Line: Equatable, Sendable, Hashable {
    /// Top-left origin, 0–1 normalized to the captured frame.
    var boundingBoxNormalized: CGRect
    var text: String
  }

  var lines: [Line]

  /// Most frequent language Vision actually used to read the captured frame.
  /// Populated when the request runs with auto language detection.
  var detectedLanguage: Locale.Language?

  var joinedText: String {
    lines.map(\.text).joined(separator: "\n")
  }
}
