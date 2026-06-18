import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation
import Vision

// MARK: - OCRClient

@DependencyClient
struct OCRClient {
  var recognizeText: @Sendable (_ image: CGImage, _ language: Language, _ mode: OCRMode) async throws -> OCRResult
}

// MARK: DependencyKey

extension OCRClient: DependencyKey {
  static let liveValue = OCRClient(
    recognizeText: { image, language, mode in
      switch mode {
      case .text:
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if language.isAuto {
          request.automaticallyDetectsLanguage = true
        } else {
          request.recognitionLanguages = [Locale.Language(identifier: language.code)]
        }
        let observations = try await request.perform(on: image)

        let lines: [OCRResult.Line] = observations.compactMap { observation in
          guard let text = observation.topCandidates(1).first?.string else { return nil }
          let cg = observation.boundingBox.cgRect
          let topLeftRect = CGRect(
            x: cg.minX,
            y: 1 - cg.maxY,
            width: cg.width,
            height: cg.height
          )
          return OCRResult.Line(boundingBoxNormalized: topLeftRect, text: text)
        }

        return OCRResult(lines: arrangeLines(lines, language: language))

      case .document:
        var request = RecognizeDocumentsRequest()
        if language.isAuto {
          request.textRecognitionOptions.automaticallyDetectLanguage = true
        } else {
          request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: language.code)]
        }
        let observations = try await request.perform(on: image)
        let paragraphs = observations.flatMap(\.document.paragraphs)
        let count = max(paragraphs.count, 1)
        let lines: [OCRResult.Line] = paragraphs.enumerated().map { index, paragraph in
          let lineHeight = 1.0 / CGFloat(count)
          return OCRResult.Line(
            boundingBoxNormalized: CGRect(
              x: 0,
              y: CGFloat(index) * lineHeight,
              width: 1,
              height: lineHeight
            ),
            text: paragraph.transcript
          )
        }
        return OCRResult(lines: lines)
      }
    }
  )
}

extension DependencyValues {
  var ocr: OCRClient {
    get { self[OCRClient.self] }
    set { self[OCRClient.self] = newValue }
  }
}

// MARK: - Line arrangement

/// Vision returns vertical (top-to-bottom) CJK text as one tall, narrow box per
/// column. Group those columns — right-to-left, the way vertical CJK reads —
/// into a single block so the passage is translated as a whole and the overlay
/// draws one paragraph over it, instead of cramming a giant font into each
/// narrow column. Horizontal lines go through the usual wrapped-line stitching.
private func arrangeLines(_ lines: [OCRResult.Line], language: Language) -> [OCRResult.Line] {
  let vertical = lines.filter { $0.boundingBoxNormalized.isVerticalColumn }
  let horizontal = lines.filter { !$0.boundingBoxNormalized.isVerticalColumn }
  let blocks = groupVerticalColumns(vertical, omitsSpaces: language.omitsWordSpaces)
  let stitched = mergeWrappedLines(horizontal, language: language)
  return blocks + stitched
}

/// Stitch tall, narrow vertical columns into blocks. Columns that sit side by
/// side and overlap along the reading axis belong to the same block; their text
/// joins in right-to-left reading order and `box` becomes the union, marked as a
/// vertical block so the renderer fills it as a paragraph.
private func groupVerticalColumns(_ columns: [OCRResult.Line], omitsSpaces: Bool) -> [OCRResult.Line] {
  let trimmed = columns
    .map { OCRResult.Line(boundingBoxNormalized: $0.boundingBoxNormalized, text: $0.text.trimmed) }
    .filter { !$0.text.isEmpty }
  guard !trimmed.isEmpty else { return [] }

  // Vertical CJK reads right-to-left across columns.
  let sorted = trimmed.sorted { $0.boundingBoxNormalized.midX > $1.boundingBoxNormalized.midX }

  var blocks = [[OCRResult.Line]]()
  for column in sorted {
    if let prev = blocks.last?.last,
       adjacentColumns(prev.boundingBoxNormalized, column.boundingBoxNormalized) {
      blocks[blocks.count - 1].append(column)
    } else {
      blocks.append([column])
    }
  }

  return blocks.map { group in
    let text = group.dropFirst().reduce(group[0].text) { joinFragments($0, $1.text, omitsSpaces: omitsSpaces) }
    let box = group.dropFirst().reduce(group[0].boundingBoxNormalized) { $0.union($1.boundingBoxNormalized) }
    return OCRResult.Line(boundingBoxNormalized: box, text: text, isVerticalBlock: true)
  }
}

/// Two vertical columns belong to the same block when they sit side by side
/// (close horizontally) and overlap along the reading (vertical) axis.
private func adjacentColumns(_ a: CGRect, _ b: CGRect) -> Bool {
  let overlapY = min(a.maxY, b.maxY) - max(a.minY, b.minY)
  guard overlapY > min(a.height, b.height) * 0.3 else { return false }
  return abs(a.midX - b.midX) < max(a.width, b.width) * 3
}

extension CGRect {
  /// A tall, narrow box — Vision's shape for a single column of vertical CJK
  /// text. Horizontal lines are always wider than tall, so they never match.
  fileprivate var isVerticalColumn: Bool {
    width > 0 && height > width * 1.5
  }
}

// MARK: - Line merging

/// Vision returns text line-by-line, so a sentence wrapped across several
/// lines arrives as separate boxes. Stitch consecutive lines that look like
/// the same sentence back together (trimmed, one box) so translation gets the
/// whole sentence and the overlay draws one chip over it.
private func mergeWrappedLines(_ lines: [OCRResult.Line], language: Language) -> [OCRResult.Line] {
  let trimmed = lines
    .map { OCRResult.Line(boundingBoxNormalized: $0.boundingBoxNormalized, text: $0.text.trimmed, rowCount: $0.rowCount) }
    .filter { !$0.text.isEmpty }
  guard trimmed.count > 1 else { return trimmed }

  let omitsSpaces = language.omitsWordSpaces
  let sorted = trimmed.sorted { $0.boundingBoxNormalized.minY < $1.boundingBoxNormalized.minY }

  var merged = [OCRResult.Line]()
  // Adjacency is judged against the previous single row, not the growing
  // union box — otherwise a tall merged box pulls in far-below lines.
  var lastRowBox = CGRect.null
  for line in sorted {
    if var last = merged.last, continuesSentence(prevText: last.text, prevRow: lastRowBox, next: line.boundingBoxNormalized) {
      last.text = joinFragments(last.text, line.text, omitsSpaces: omitsSpaces)
      last.boundingBoxNormalized = last.boundingBoxNormalized.union(line.boundingBoxNormalized)
      last.rowCount += line.rowCount
      merged[merged.count - 1] = last
    } else {
      merged.append(line)
    }
    lastRowBox = line.boundingBoxNormalized
  }
  return merged
}

/// Whether `next` reads as a wrapped continuation of the sentence: the text so
/// far doesn't end a sentence, and `next` sits on the row directly below the
/// previous row in the same column.
private func continuesSentence(prevText: String, prevRow p: CGRect, next n: CGRect) -> Bool {
  guard !endsSentence(prevText) else { return false }

  // next must be the immediately following row — a small gap relative to the
  // row height — not the same row and not a far-away block.
  let gap = n.minY - p.maxY
  let rowHeight = max(p.height, n.height)
  guard gap > -rowHeight * 0.5, gap < rowHeight * 0.7 else { return false }

  // and share a horizontal column, so we don't merge side-by-side columns.
  let overlapX = min(p.maxX, n.maxX) - max(p.minX, n.minX)
  return overlapX > min(p.width, n.width) * 0.3
}

private func endsSentence(_ text: String) -> Bool {
  guard let last = text.last else { return true }
  return ".!?\u{2026}\u{3002}\u{FF01}\u{FF1F}".contains(last)
}

private func joinFragments(_ a: String, _ b: String, omitsSpaces: Bool) -> String {
  if a.hasSuffix("-") { return String(a.dropLast()) + b } // hyphenated word break
  if omitsSpaces { return a + b }
  return a + " " + b
}

extension StringProtocol {
  fileprivate var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
