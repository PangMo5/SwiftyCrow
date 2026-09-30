// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRParagraphLineGrouping

/// Preserves explicit semantic breaks that Vision exposes inside a document
/// paragraph. Visual wraps share a group; lines separated by a transcript
/// newline do not get stitched back into one translation unit.
enum OCRParagraphLineGrouping {

  // MARK: Internal

  /// The smallest enclosing native list item/table cell owns a row. Assign
  /// after crop recovery so alternate observations inherit the same boundary.
  static func container(for box: CGRect, in containers: [CGRect]) -> CGRect? {
    guard box.width > 0, box.height > 0 else { return nil }
    return containers.filter { container in
      let overlap = container.intersection(box)
      return !overlap.isNull && overlap.width * overlap.height >= box.width * box.height * 0.85
    }.min { $0.width * $0.height < $1.width * $1.height }
  }

  static func separators(paragraphTranscript: String, lineTranscripts: [String]) -> [String?] {
    let source = paragraphTranscript
    let indices = source.indices.filter { !source[$0].isWhitespace }
    let characters = indices.map { source[$0] }
    var cursor = 0
    var ends = [Int?]()
    var starts = [Int?]()
    for line in lineTranscripts {
      let text = Array(line.filter { !$0.isWhitespace })
      guard !text.isEmpty, text.count <= characters.count - cursor else { starts.append(nil)
        ends.append(nil)
        continue
      }
      let match = (cursor...(characters.count - text.count)).first { start in
        Array(characters[start..<start + text.count]) == text
      }
      starts.append(match)
      ends.append(match.map { $0 + text.count })
      if let match { cursor = match + text.count }
    }
    return lineTranscripts.indices.map { i in
      guard i + 1 < starts.count, let end = ends[i], let start = starts[i + 1], end > 0, start >= end else { return nil }
      let after = source.index(after: indices[end - 1])
      return source[after..<indices[start]].isEmpty ? "" : " "
    }
  }

  static func segmentIndices(
    paragraphTranscript: String,
    lineTranscripts: [String]
  ) -> [Int] {
    guard !lineTranscripts.isEmpty else { return [] }
    let segments = paragraphTranscript
      .split(whereSeparator: \.isNewline)
      .map { normalized(String($0)) }
      .filter { !$0.isEmpty }
    guard segments.count > 1 else {
      return Array(repeating: 0, count: lineTranscripts.count)
    }

    var segmentIndex = 0
    var consumed = ""
    return lineTranscripts.map { transcript in
      let line = normalized(transcript)
      while
        segmentIndex < segments.count - 1,
        !segments[segmentIndex].hasPrefix(consumed + line)
      {
        segmentIndex += 1
        consumed = ""
      }

      let result = segmentIndex
      consumed += line
      if
        segmentIndex < segments.count - 1,
        consumed.count >= segments[segmentIndex].count
        || !segments[segmentIndex].hasPrefix(consumed)
      {
        segmentIndex += 1
        consumed = ""
      }
      return result
    }
  }

  // MARK: Private

  private static func normalized(_ value: String) -> String {
    value.filter { !$0.isWhitespace && !$0.isNewline }
  }
}
