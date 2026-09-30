// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRTextTokenization

/// Produces style-sized ranges while leaving their geometry to Vision. Words
/// remain intact for Latin scripts; CJK text remains contiguous; punctuation is
/// separate so brackets, links, and emphasized symbols can keep their own style.
enum OCRTextTokenization {

  // MARK: Internal

  static func hasUnspacedBoundary(between first: Character, and second: Character) -> Bool {
    Kind(first) == .cjk && Kind(second) == .cjk
  }

  static func ranges(in text: String) -> [Range<String.Index>] {
    var result = [Range<String.Index>]()
    var start: String.Index?
    var currentKind: Kind?

    func finish(at end: String.Index) {
      if let start, start < end {
        result.append(start ..< end)
      }
      start = nil
      currentKind = nil
    }

    var index = text.startIndex
    while index < text.endIndex {
      let next = text.index(after: index)
      guard let kind = Kind(text[index]) else {
        finish(at: index)
        index = next
        continue
      }
      if currentKind != kind {
        finish(at: index)
        start = index
        currentKind = kind
      }
      index = next
    }
    finish(at: text.endIndex)
    return result
  }

  // MARK: Private

  private enum Kind: Equatable {
    case cjk
    case word
    case punctuation

    // MARK: Lifecycle

    init?(_ character: Character) {
      let scalars = character.unicodeScalars
      guard !scalars.allSatisfy(\.properties.isWhitespace) else { return nil }
      if scalars.contains(where: { Self.isCJK($0) }) {
        self = .cjk
      } else if
        scalars
          .allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "_" })
      {
        self = .word
      } else {
        self = .punctuation
      }
    }

    // MARK: Private

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
      switch scalar.value {
      case 0x3040 ... 0x30FF,
           0x31F0 ... 0x31FF,
           0x3400 ... 0x4DBF,
           0x4E00 ... 0x9FFF,
           0xAC00 ... 0xD7AF,
           0xF900 ... 0xFAFF,
           0x20000 ... 0x2FA1F:
        true
      default:
        false
      }
    }
  }
}
