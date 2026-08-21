// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import CoreText
import DependenciesMacros
import Foundation
import Vision

// MARK: - OCRClient

@DependencyClient
struct OCRClient {
  var recognizeText: @Sendable (_ image: CGImage, _ language: Language) async throws -> OCRResult
  /// Loads Vision's document-recognition model without a capture waiting on it.
  /// See `VisionWarmUp` for why this has to happen off the critical path.
  var warmUp: @Sendable () async -> Void
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
      let clock = ContinuousClock()
      let started = clock.now
      let observations = try await request.perform(on: image)
      // Always timed: a cold model load and a genuine stall look identical from
      // the UI, and the duration is the only thing that separates them.
      let elapsed = clock.now - started
      if elapsed > .seconds(2) {
        Log.ocr.error("Recognition took \(elapsed.loggedSeconds, privacy: .public)s — model was cold")
      } else {
        Log.ocr.debug("Recognition took \(elapsed.loggedSeconds, privacy: .public)s")
      }

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
    },
    warmUp: { await VisionWarmUp.shared.run() }
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

// MARK: - VisionWarmUp

/// Loads Vision's document-recognition model ahead of any real capture.
///
/// The first `RecognizeDocumentsRequest` after the system's shared model cache
/// goes cold costs tens of seconds — ~40s measured here, against ~0.25s once it's
/// loaded — and the cache goes cold again on its own while the app sits idle.
/// Paying that on the capture the user just asked for is what made Live and
/// Capture look like they had hung: a spinner, then nothing.
///
/// So the load happens in the background instead — at launch, on wake, and while
/// the user is still dragging out a region. Nothing here makes a cold load
/// faster; it moves the cost to a moment when nobody is waiting on it.
private actor VisionWarmUp {

  // MARK: Internal

  static let shared = VisionWarmUp()

  /// Concurrent callers share one load, so a capture that starts mid-load joins
  /// it instead of queueing a second one — and a caller that gives up doesn't
  /// take the load down with it.
  ///
  /// Deliberately not memoized across calls: the shared cache goes cold whenever
  /// the system decides to, and there's no API to ask whether it has. Re-probing
  /// costs ~0.1s while it's still warm, which is far cheaper than being wrong.
  func run() async {
    guard let probe = Self.probe else { return }
    if let inFlight {
      await inFlight.value
      return
    }
    let load = Task<Void, Never> {
      let clock = ContinuousClock()
      let started = clock.now
      var request = RecognizeDocumentsRequest()
      request.textRecognitionOptions.automaticallyDetectLanguage = true
      do {
        _ = try await request.perform(on: probe)
        let elapsed = clock.now - started
        if elapsed > .seconds(2) {
          Log.ocr.log("Warm-up loaded a cold model in \(elapsed.loggedSeconds, privacy: .public)s")
        } else {
          Log.ocr.debug("Warm-up found the model ready (\(elapsed.loggedSeconds, privacy: .public)s)")
        }
      } catch {
        Log.ocr.error("Warm-up failed: \(error.localizedDescription, privacy: .public)")
      }
    }
    inFlight = load
    await load.value
    inFlight = nil
  }

  // MARK: Private

  /// Small, but with real text drawn on it: a blank image lets Vision finish
  /// without ever loading the recognition model, which would warm nothing.
  private static let probe: CGImage? = {
    let width = 256
    let height = 64
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let attributed = NSAttributedString(
      string: "Warm up 123",
      attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 32, nil),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          red: 0,
          green: 0,
          blue: 0,
          alpha: 1
        ),
      ]
    )
    context.textPosition = CGPoint(x: 8, y: 18)
    CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    return context.makeImage()
  }()

  private var inFlight: Task<Void, Never>?
}
