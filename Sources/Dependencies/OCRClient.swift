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

        return OCRResult(lines: mergeWrappedLines(lines, language: language))

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
