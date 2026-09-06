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
      // A capture that starts while the proactive probe is loading the model
      // joins that work instead of issuing a second cold Vision request.
      await VisionWarmUp.shared.waitForInFlight()
      try Task.checkCancellation()
      var request = RecognizeDocumentsRequest()
      if language.isAuto {
        request.textRecognitionOptions.automaticallyDetectLanguage = true
      } else {
        request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: language.code)]
      }
      let clock = ContinuousClock()
      let started = clock.now
      let observations = try await request.perform(on: image)
      try Task.checkCancellation()
      // Always timed: a cold model load and a genuine stall look identical from
      // the UI, and the duration is the only thing that separates them.
      let elapsed = clock.now - started
      if elapsed > .seconds(2) {
        Log.ocr.error("Recognition took \(elapsed.loggedSeconds, privacy: .public)s — model was cold")
      } else {
        Log.ocr.debug("Recognition took \(elapsed.loggedSeconds, privacy: .public)s")
      }

      // Vision's paragraph grouping is semantic, not typographic. A large title
      // and a smaller subtitle can therefore arrive as one paragraph even
      // though they need different font scale, color, and translation frames.
      // Start from Vision's line geometry and conservatively stitch only lines
      // with matching scale/alignment below.
      let postProcessingStarted = clock.now
      let paragraphs = observations.flatMap(\.document.paragraphs)
      var nextRecognitionGroupID = 0
      var lines = paragraphs.flatMap { paragraph in
        let alignment = paragraph.textAlignment?.overlayTextAlignment
        let paragraphWords = paragraph.words?.compactMap { observation -> RecognizedWord? in
          guard let text = observation.topCandidates(1).first?.string.trimmed, !text.isEmpty else {
            return nil
          }
          return RecognizedWord(
            text: text,
            box: Self.topLeftBox(observation.boundingRegion.boundingBox.cgRect)
          )
        } ?? []
        let recognizedLines = paragraph.lines.compactMap { observation -> (
          observation: RecognizedTextObservation,
          candidate: RecognizedText,
          transcript: String
        )? in
          guard
            let candidate = observation.topCandidates(1).first,
            !candidate.string.trimmed.isEmpty
          else {
            return nil
          }
          return (
            observation: observation,
            candidate: candidate,
            transcript: candidate.string.trimmed
          )
        }
        let segmentIndices = OCRParagraphLineGrouping.segmentIndices(
          paragraphTranscript: paragraph.transcript,
          lineTranscripts: recognizedLines.map(\.transcript)
        )
        let groupBase = nextRecognitionGroupID
        nextRecognitionGroupID += max(1, (segmentIndices.max() ?? 0) + 1)
        let mapped = recognizedLines.enumerated().map { lineIndex, recognizedLine -> OCRResult.Line in
          let observation = recognizedLine.observation
          let transcript = recognizedLine.transcript
          let box = Self.topLeftBox(observation.boundingRegion.boundingBox.cgRect)
          let imageSize = CGSize(width: image.width, height: image.height)
          let topLeft = observation.topLeft.cgPoint
          let topRight = observation.topRight.cgPoint
          let bottomLeft = observation.bottomLeft.cgPoint
          let isVertical = OCRGeometry.isVertical(
            text: transcript,
            topLeft: topLeft,
            topRight: topRight,
            imageSize: imageSize,
            declaredVertical: observation.textDirection == .topToBottom
          )
          let dx = (topRight.x - topLeft.x) * imageSize.width
          let dy = -(topRight.y - topLeft.y) * imageSize.height
          let angle = isVertical ? 0 : atan2(dy, dx)
          let rotation = abs(angle) > 0.025 ? angle : 0
          let orientedHeight = hypot(
            (bottomLeft.x - topLeft.x) * imageSize.width,
            (bottomLeft.y - topLeft.y) * imageSize.height
          ) /
            imageSize.height
          let orientedWidth = hypot(dx, dy) / imageSize.width
          let orientedBox = CGRect(
            x: box.midX - orientedWidth / 2,
            y: box.midY - orientedHeight / 2,
            width: orientedWidth,
            height: orientedHeight
          )
          let documentWords = paragraphWords.filter { word in
            let intersection = box.intersection(word.box)
            return !intersection.isNull
              && intersection.width * intersection.height
              / max(0.000_001, word.box.width * word.box.height) >= 0.72
          }
          // Document paragraphs do not always expose `words` (notably dense
          // Japanese educational pages). The line candidate still provides
          // Apple's exact range geometry, so use it to retain punctuation,
          // mixed colors, and inline styles instead of flattening the line.
          let geometricWords = Self.geometricWords(in: recognizedLine.candidate)
          let words = geometricWords.isEmpty ? documentWords : geometricWords
          let wordBoxes = words.map(\.box)
          let patches = (wordBoxes.isEmpty ? [box] : wordBoxes).map {
            OverlaySourcePatch(box: $0)
          }
          let horizontalGlyphScale = isVertical
            ? 0
            : Self.median(wordBoxes.map(\.height)) ?? box.height
          return OCRResult.Line(
            boundingBoxNormalized: box,
            text: transcript,
            rotationRadians: rotation,
            orientedBox: rotation == 0 ? nil : orientedBox,
            imageAspectRatio: imageSize.width / imageSize.height,
            isVerticalBlock: isVertical,
            verticalCharScale: isVertical ? box.width : 0,
            horizontalGlyphScale: rotation == 0 ? horizontalGlyphScale : orientedHeight,
            recognitionGroupID: groupBase + segmentIndices[lineIndex],
            replacementPatches: patches,
            styleRuns: Self.styleRuns(in: transcript, words: words),
            alignment: alignment
          )
        }
        guard mapped.isEmpty else { return mapped }

        let transcript = paragraph.transcript.trimmed
        guard !transcript.isEmpty else { return [] }
        let box = Self.topLeftBox(paragraph.boundingRegion.boundingBox.cgRect)
        return [
          OCRResult.Line(
            boundingBoxNormalized: box,
            text: transcript,
            rowCount: 1,
            recognitionGroupID: groupBase,
            replacementPatches: [OverlaySourcePatch(box: box)],
            alignment: alignment
          )
        ]
      }
      if Self.shouldRunSupplementalRecognition(for: lines, language: language) {
        do {
          let supplementalStarted = clock.now
          let supplemental = try await Self.supplementalLines(in: image, language: language)
          let previousCount = lines.count
          lines = OCRSupplementalMerger.addingUncovered(supplemental, to: lines)
          Log.ocr.debug(
            "Supplemental recognition added \(lines.count - previousCount, privacy: .public) lines in \((clock.now - supplementalStarted).loggedSeconds, privacy: .public)s"
          )
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          // Document recognition remains a complete result on its own. Surface
          // the supplemental failure, but do not turn a successful capture into
          // an error merely because the recall pass was unavailable.
          Log.ocr.error(
            "Supplemental recognition failed: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      try Task.checkCancellation()
      lines = try await OCRLineRefiner.refine(lines, in: image, language: language)
      lines = try await OCRBalloonRefiner.refine(lines, in: image, language: language)
      let correctedLines: [OCRResult.Line]
      let languageCode = language.localeLanguage.languageCode?.identifier
      if language.isAuto || languageCode == "ja" {
        do {
          correctedLines = try await JapaneseRubyOCRCorrector.correcting(lines, in: image)
        } catch is CancellationError {
          throw CancellationError()
        } catch {
          Log.ocr.error(
            "Base-glyph OCR failed: \(error.localizedDescription, privacy: .public)"
          )
          correctedLines = lines
        }
      } else {
        correctedLines = lines
      }
      try Task.checkCancellation()
      let result = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
        to: OCRResult(lines: correctedLines).removingNestedDuplicates(),
        from: image
      ).coalescingParagraphFragments()
      try Task.checkCancellation()
      let postProcessingElapsed = clock.now - postProcessingStarted
      Log.ocr.debug(
        "Post-processing produced \(result.lines.count, privacy: .public) lines in \(postProcessingElapsed.loggedSeconds, privacy: .public)s"
      )
      let restored = SourceRestorationBuilder.applying(to: result, image: image)
      try Task.checkCancellation()
      return await OCRQualityAssessment.markingUncertainText(in: restored)
    },
    warmUp: { await VisionWarmUp.shared.run() }
  )
}

// MARK: - OCRParagraphLineGrouping

/// Preserves explicit semantic breaks that Vision exposes inside a document
/// paragraph. Visual wraps share a group; lines separated by a transcript
/// newline do not get stitched back into one translation unit.
enum OCRParagraphLineGrouping {

  // MARK: Internal

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

extension OCRClient {
  fileprivate struct RecognizedWord {
    var text: String
    var box: CGRect
  }

  fileprivate static func topLeftBox(_ box: CGRect) -> CGRect {
    CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
  }

  fileprivate static func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  fileprivate static func styleRuns(
    in transcript: String,
    words: [RecognizedWord]
  ) -> [OverlaySourceStyleRun] {
    guard !transcript.isEmpty, !words.isEmpty else { return [] }
    let source = transcript as NSString
    var cursor = 0
    var runs = [OverlaySourceStyleRun]()
    for word in words {
      guard cursor < source.length else { break }
      let searchRange = NSRange(location: cursor, length: source.length - cursor)
      var range = source.range(of: word.text, options: [], range: searchRange)
      if range.location == NSNotFound {
        range = source.range(of: word.text, options: .caseInsensitive, range: searchRange)
      }
      guard range.location != NSNotFound else { continue }
      runs.append(OverlaySourceStyleRun(range: range, box: word.box))
      cursor = range.location + range.length
    }
    return runs
  }

  fileprivate static func geometricWords(in candidate: RecognizedText) -> [RecognizedWord] {
    OCRTextTokenization.ranges(in: candidate.string).compactMap { range in
      guard let observation = candidate.boundingBox(for: range) else { return nil }
      return RecognizedWord(
        text: String(candidate.string[range]),
        box: topLeftBox(observation.boundingBox.cgRect)
      )
    }
  }

  fileprivate static func supplementalLines(
    in image: CGImage,
    language: Language
  ) async throws -> [OCRResult.Line] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if language.isAuto {
      request.automaticallyDetectsLanguage = true
    } else {
      request.recognitionLanguages = [language.localeLanguage]
    }
    return try await request.perform(on: image).compactMap { observation in
      guard
        let candidate = observation.topCandidates(1).first,
        candidate.confidence >= 0.25,
        !candidate.string.trimmed.isEmpty
      else { return nil }
      let text = candidate.string.trimmed
      let box = topLeftBox(observation.boundingRegion.boundingBox.cgRect)
      let words = geometricWords(in: candidate)
      let wordBoxes = words.map(\.box)
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        horizontalGlyphScale: median(wordBoxes.map(\.height)) ?? box.height,
        replacementPatches: (wordBoxes.isEmpty ? [box] : wordBoxes).map {
          OverlaySourcePatch(box: $0)
        },
        styleRuns: styleRuns(in: text, words: words),
        alignment: inferredSupplementalAlignment(for: box)
      )
    }
  }

  fileprivate static func shouldRunSupplementalRecognition(
    for lines: [OCRResult.Line],
    language: Language
  ) -> Bool {
    guard !lines.contains(where: \.isVerticalBlock) else { return false }
    let languageCode = language.localeLanguage.languageCode?.identifier
    if !language.isAuto, languageCode == "ja" { return false }
    if language.isAuto, lines.map(\.text).joined().unicodeScalars.contains(where: isJapaneseScalar) {
      return false
    }
    return true
  }

  fileprivate static func inferredSupplementalAlignment(for box: CGRect) -> OverlayTextAlignment {
    box.width >= 0.35 && abs(box.midX - 0.5) <= 0.06 ? .center : .leading
  }

  fileprivate static func isJapaneseScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040 ... 0x30FF,
         0x31F0 ... 0x31FF:
      true
    default:
      false
    }
  }
}

// MARK: - OCRSupplementalMerger

enum OCRSupplementalMerger {

  // MARK: Internal

  /// Adds only text rows that document recognition omitted. RecognizeText is a
  /// high-recall companion pass; overlapping document rows remain canonical so
  /// paragraph membership, style, and alignment are not destabilized.
  static func addingUncovered(
    _ supplemental: [OCRResult.Line],
    to primary: [OCRResult.Line]
  ) -> [OCRResult.Line] {
    let additions = supplemental.filter { candidate in
      !primary.contains { covers(candidate, primary: $0) }
    }
    return (primary + additions).sorted { lhs, rhs in
      let lhsBox = lhs.boundingBoxNormalized.standardized
      let rhsBox = rhs.boundingBoxNormalized.standardized
      if abs(lhsBox.minY - rhsBox.minY) <= min(lhsBox.height, rhsBox.height) * 0.35 {
        return lhsBox.minX < rhsBox.minX
      }
      return lhsBox.minY < rhsBox.minY
    }
  }

  // MARK: Private

  private static func covers(_ candidate: OCRResult.Line, primary: OCRResult.Line) -> Bool {
    let candidateBox = candidate.boundingBoxNormalized.standardized
    let primaryBox = primary.boundingBoxNormalized.standardized
    let intersection = candidateBox.intersection(primaryBox)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    let intersectionArea = intersection.width * intersection.height
    let candidateCoverage = intersectionArea / max(0.000_001, candidateBox.width * candidateBox.height)
    if candidateCoverage >= 0.58 { return true }

    let candidateText = normalized(candidate.text)
    let primaryText = normalized(primary.text)
    guard
      !candidateText.isEmpty,
      candidateText == primaryText || candidateText.contains(primaryText) || primaryText.contains(candidateText)
    else { return false }
    return hypot(candidateBox.midX - primaryBox.midX, candidateBox.midY - primaryBox.midY)
      <= max(candidateBox.height, primaryBox.height) * 1.5
  }

  private static func normalized(_ text: String) -> String {
    text.lowercased().unicodeScalars
      .filter { CharacterSet.alphanumerics.contains($0) }
      .map(String.init)
      .joined()
  }
}

// MARK: - OCRTextTokenization

/// Produces style-sized ranges while leaving their geometry to Vision. Words
/// remain intact for Latin scripts; CJK text remains contiguous; punctuation is
/// separate so brackets, links, and emphasized symbols can keep their own style.
enum OCRTextTokenization {

  // MARK: Internal

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
      } else if scalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == "_" }) {
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

extension DocumentObservation.Container.Text.Alignment {
  fileprivate var overlayTextAlignment: OverlayTextAlignment {
    switch self {
    case .center: .center
    case .leading: .leading
    case .trailing: .trailing
    @unknown default: .center
    }
  }
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
        var supplemental = RecognizeTextRequest()
        supplemental.recognitionLevel = .accurate
        supplemental.automaticallyDetectsLanguage = true
        _ = try await supplemental.perform(on: probe)
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

  func waitForInFlight() async {
    if let inFlight {
      await inFlight.value
    }
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
