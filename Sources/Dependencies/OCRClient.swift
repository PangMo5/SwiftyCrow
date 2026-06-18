import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation
import Vision

// MARK: - OCRClient

@DependencyClient
struct OCRClient {
  var recognizeText: @Sendable (_ image: CGImage, _ language: Language) async throws -> OCRResult
}

// MARK: DependencyKey

extension OCRClient: DependencyKey {
  static let liveValue = OCRClient(
    recognizeText: { image, language in
      var request = RecognizeDocumentsRequest()
      if language.isAuto {
        request.textRecognitionOptions.automaticallyDetectLanguage = true
      } else {
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: language.code)]
      }
      let observations = try await request.perform(on: image)

      // Each paragraph is already grouped in reading order by Vision's document
      // layout analysis — it separates titles, ruby (furigana), and body, orders
      // vertical CJK columns right-to-left, and reports the text direction — so we
      // map each paragraph to one line/block at its own location.
      let lines: [OCRResult.Line] = observations.flatMap(\.document.paragraphs).compactMap { paragraph in
        let transcript = paragraph.transcript.trimmed
        guard !transcript.isEmpty else { return nil }
        let cg = paragraph.boundingRegion.boundingBox.cgRect
        let box = CGRect(x: cg.minX, y: 1 - cg.maxY, width: cg.width, height: cg.height)

        // A paragraph is vertical when most of its lines read top-to-bottom.
        let verticalLineCount = paragraph.lines.filter { $0.textDirection == .topToBottom }.count
        let isVertical = !paragraph.lines.isEmpty && verticalLineCount * 2 >= paragraph.lines.count

        // For a vertical block each line is a column whose width tracks the
        // character size — average it so the renderer keeps the font scale.
        let charScale = isVertical
          ? paragraph.lines.map { $0.boundingRegion.boundingBox.cgRect.width }.reduce(0, +) / CGFloat(max(paragraph.lines.count, 1))
          : 0
        return OCRResult.Line(
          boundingBoxNormalized: box,
          text: transcript,
          rowCount: max(1, paragraph.lines.count),
          isVerticalBlock: isVertical,
          verticalCharScale: charScale
        )
      }
      return OCRResult(lines: lines)
    }
  )
}

extension DependencyValues {
  var ocr: OCRClient {
    get { self[OCRClient.self] }
    set { self[OCRClient.self] = newValue }
  }
}

extension StringProtocol {
  fileprivate var trimmed: String {
    trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
