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

        let detected = observations
          .flatMap(\.recognitionLanguages)
          .reduce(into: [Locale.Language: Int]()) { counts, lang in
            counts[lang, default: 0] += 1
          }
          .max(by: { $0.value < $1.value })?
          .key

        return OCRResult(lines: lines, detectedLanguage: detected)

      case .document:
        var request = RecognizeDocumentsRequest()
        if !language.isAuto {
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
        return OCRResult(lines: lines, detectedLanguage: nil)
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
