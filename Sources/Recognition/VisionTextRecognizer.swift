// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Vision

// MARK: - VisionTextRecognizer

/// Vision-only I/O. Both full-document and recovery observations map through
/// source-image coordinates; downstream stages do not call recognition APIs.
enum VisionTextRecognizer {

  // MARK: Internal

  enum ComputePolicy: String, Sendable { case automatic, cpu, gpu }

  struct Document {
    var lines: [OCRResult.Line]
    var containers: [CGRect]
    var tableCells = [OCRTableCell]()
  }

  struct TextCandidate: Sendable {
    var text: String
    var confidence: Float
  }

  /// Diagnostic selection for the public main compute stage only. Vision's
  /// nested text-recognition work can still use other hardware. The production
  /// default remains automatic; this is not a guarantee of CPU-only execution.
  @TaskLocal static var computePolicy = ComputePolicy.automatic

  static func configure(_ request: inout some VisionRequest) throws {
    guard computePolicy != .automatic else { return }
    let policy = computePolicy
    guard
      let device = request.supportedComputeStageDevices[.main]?.first(where: {
        switch $0 {
        case .cpu: policy == .cpu
        case .gpu: policy == .gpu
        default: false
        }
      })
    else {
      throw NSError(
        domain: "SwiftyCrow.VisionCompute",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Unsupported Vision compute device: \(policy.rawValue)"]
      )
    }
    request.setComputeDevice(device, for: .main)
  }

  static func documentInputs(in image: CGImage, detectedText: [CGRect]) -> [OCRDocumentRegion.Input] {
    let size = CGSize(width: image.width, height: image.height)
    guard OCRDocumentRegion.needsCropping(imageSize: size, detectedText: detectedText) else {
      Log.ocr.log("Document input: full image; projected glyph resolution needs no cropping")
      let canvas = CGRect(origin: .zero, size: size)
      return [.init(bounds: canvas, ownership: [canvas])]
    }
    let inputs = OCRDocumentRegion.inputs(
      imageSize: size,
      detectedText: detectedText,
      surfaceBounds: OCRDocumentRegion.surfaceBounds(in: image)
    )
    Log.ocr.log("Document inputs: \(String(describing: inputs), privacy: .public)")
    return inputs
  }

  static func document(in image: CGImage, language: Language, inputs: [OCRDocumentRegion.Input]) async throws -> Document {
    guard !inputs.isEmpty else { throw CocoaError(.coderInvalidValue) }
    let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    var result = Document(lines: [], containers: [])
    for (index, input) in inputs.enumerated() {
      try Task.checkCancellation()
      let region = input.bounds
      guard canvas.contains(region), !region.isEmpty else { throw CocoaError(.coderInvalidValue) }
      var observed = try await document(in: image, language: language, crop: region == canvas ? nil : region)
      observed.lines = OCRObservationRows.split(observed.lines).filter {
        OCRDocumentRegion.owner(of: $0.boundingBoxNormalized, in: inputs, imageSize: canvas.size) == index
      }.map { source in
        var line = source
        line.tableCell = line.tableCell ?? OCRTableCell.containing(line.boundingBoxNormalized, in: observed.tableCells)
        line.recognitionContainer = line.tableCell?.box
          ?? OCRParagraphLineGrouping.container(for: line.boundingBoxNormalized, in: observed.containers)
        return line
      }
      result = combining(result, observed)
    }
    return result
  }

  /// Native IDs are local to each request. Source coordinates and structure
  /// survive composition, while distinct documents cannot share paragraph/table IDs.
  static func combining(_ first: Document, _ second: Document) -> Document {
    let groupOffset = (first.lines.compactMap(\.recognitionGroupID).max() ?? -1) + 1
    let tableOffset = (first.tableCells.map(\.table).max() ?? -1) + 1
    return Document(lines: first.lines + second.lines.map { source in
      var line = source
      line.recognitionGroupID = line.recognitionGroupID.map { $0 + groupOffset }
      if var cell = line.tableCell {
        cell.table += tableOffset
        line.tableCell = cell
      }
      return line
    }, containers: first.containers + second.containers, tableCells: first.tableCells + second.tableCells.map { source in
      var cell = source
      cell.table += tableOffset
      return cell
    })
  }

  static func document(
    in image: CGImage,
    language: Language,
    crop: CGRect? = nil,
    usesLanguageCorrection: Bool? = nil
  ) async throws -> Document {
    if let crop {
      guard let cropped = image.cropping(to: crop) else { throw CocoaError(.coderInvalidValue) }
      return OCRDocumentRegion.remap(
        try await document(in: cropped, language: language, usesLanguageCorrection: usesLanguageCorrection),
        crop: crop,
        imageSize: CGSize(width: image.width, height: image.height)
      )
    }
    var request = RecognizeDocumentsRequest()
    if let usesLanguageCorrection { request.textRecognitionOptions.useLanguageCorrection = usesLanguageCorrection }
    if language.isAuto {
      request.textRecognitionOptions.automaticallyDetectLanguage = true
    } else {
      request.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: language.code)]
    }
    try configure(&request)
    let observations = try await request.perform(on: image)
    try Task.checkCancellation()

    // Vision's paragraph grouping is semantic, not typographic. A large title
    // and a smaller subtitle can therefore arrive as one paragraph even
    // though they need different font scale, color, and translation frames.
    // Start from Vision's line geometry and conservatively stitch only lines
    // with matching scale/alignment below.
    let paragraphs = observations.flatMap(\.document.paragraphs)
    var nextRecognitionGroupID = 0
    let containers = observations.flatMap { observation in
      let document = observation.document
      let items = document.lists.flatMap(\.items).map { $0.content.boundingRegion.boundingBox.cgRect }
      let cells = document.tables.flatMap(\.rows).flatMap { $0 }.map { $0.content.boundingRegion.boundingBox.cgRect }
      return (items + cells).map(Self.topLeftBox)
    }
    var tableMembership = [UUID: OCRTableCell]()
    let tableCells = observations.flatMap(\.document.tables).enumerated().flatMap { tableIndex, table in
      table.rows.flatMap { row in
        row.map { cell in
          let ownership = OCRTableCell(
            table: tableIndex,
            row: cell.rowRange.lowerBound,
            column: cell.columnRange.lowerBound,
            box: topLeftBox(cell.content.boundingRegion.boundingBox.cgRect),
            rowSpan: cell.rowRange.count,
            columnSpan: cell.columnRange.count
          )
          for line in cell.content.text.lines { tableMembership[line.uuid] = ownership }
          return ownership
        }
      }
    }
    let lines = paragraphs.flatMap { paragraph in
      let alignment = paragraph.textAlignment?.overlayTextAlignment
      let paragraphWords = paragraph.words?.compactMap { observation -> RecognizedWord? in
        guard
          let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines),
          !text.isEmpty
        else {
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
          !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
          return nil
        }
        return (
          observation: observation,
          candidate: candidate,
          transcript: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      let segmentIndices = OCRParagraphLineGrouping.segmentIndices(
        paragraphTranscript: paragraph.transcript,
        lineTranscripts: recognizedLines.map(\.transcript)
      )
      let separators = OCRParagraphLineGrouping.separators(
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
          declaredVertical: observation.textDirection == .topToBottom,
          bounds: box
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
          recognitionConfidence: recognizedLine.candidate.confidence,
          isVerticalBlock: isVertical,
          verticalCharScale: isVertical
            ? OCRGeometry.verticalCharacterScale(text: transcript, bounds: box, imageSize: imageSize)
            : 0,
          horizontalGlyphScale: rotation == 0 ? horizontalGlyphScale : orientedHeight,
          recognitionGroupID: groupBase + segmentIndices[lineIndex],
          followingSeparator: separators[lineIndex],
          replacementPatches: patches,
          styleRuns: Self.styleRuns(in: transcript, words: words),
          spacingAnchors: Self.spacingAnchors(in: recognizedLine.candidate, map: { $0 }),
          alignment: alignment,
          tableCell: tableMembership[observation.uuid],
          recognitionLanguages: observation.recognitionLanguages.map(\.minimalIdentifier),
          continuesToNextLine: observation.shouldWrapToNextLine
        )
      }
      guard mapped.isEmpty else { return mapped }

      let transcript = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
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
    return Document(lines: lines, containers: containers, tableCells: tableCells)
  }

  static func detectedText(in image: CGImage) async throws -> [CGRect] {
    var request = DetectTextRectanglesRequest()
    try configure(&request)
    return try await request.perform(on: image)
      .filter { $0.confidence >= 0.5 }.map { topLeftBox($0.boundingBox.cgRect) }
  }

  static func additionalText(
    in image: CGImage,
    language: Language,
    crop: CGRect,
    minimumGlyphHeight: CGFloat,
    preferredScale: CGFloat = 1,
    usesLanguageCorrection: Bool = true
  ) async throws -> [OCRResult.Line] {
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = usesLanguageCorrection
    if language.isAuto {
      request.automaticallyDetectsLanguage = true
    } else {
      request.recognitionLanguages = [language.localeLanguage]
    }
    let cropped = try recognitionImage(
      in: image,
      crop: crop,
      minimumGlyphHeight: minimumGlyphHeight,
      preferredScale: preferredScale
    )
    let region = CGRect(
      x: crop.minX / CGFloat(image.width),
      y: crop.minY / CGFloat(image.height),
      width: crop.width / CGFloat(image.width),
      height: crop.height / CGFloat(image.height)
    )
    func mapBox(_ box: CGRect) -> CGRect {
      CGRect(
        x: region.minX + box.minX * region.width,
        y: region.minY + box.minY * region.height,
        width: box.width * region.width,
        height: box.height * region.height
      )
    }
    try configure(&request)
    return try await request.perform(on: cropped).compactMap { observation in
      guard
        let candidate = observation.topCandidates(1).first,
        candidate.confidence >= 0.25,
        !candidate.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else { return nil }
      let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
      let box = mapBox(topLeftBox(observation.boundingRegion.boundingBox.cgRect))
      let words = geometricWords(in: candidate).map { RecognizedWord(text: $0.text, box: mapBox($0.box)) }
      let wordBoxes = words.map(\.box)
      let size = crop.size
      let topLeft = observation.topLeft.cgPoint
      let topRight = observation.topRight.cgPoint
      let bottomLeft = observation.bottomLeft.cgPoint
      let vertical = OCRGeometry.isVertical(
        text: text,
        topLeft: topLeft,
        topRight: topRight,
        imageSize: size,
        declaredVertical: observation.textDirection == .topToBottom,
        bounds: CGRect(
          x: 0,
          y: 0,
          width: box.width * CGFloat(image.width) / size.width,
          height: box.height * CGFloat(image.height) / size.height
        )
      )
      let dx = (topRight.x - topLeft.x) * size.width
      let dy = -(topRight.y - topLeft.y) * size.height
      let angle = vertical ? 0 : atan2(dy, dx)
      let rotation = abs(angle) > 0.025 ? angle : 0
      let orientedWidth = hypot(dx, dy) / CGFloat(image.width)
      let orientedHeight = hypot((bottomLeft.x - topLeft.x) * size.width, (bottomLeft.y - topLeft.y) * size.height) /
        CGFloat(image.height)
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        rotationRadians: rotation,
        orientedBox: rotation == 0
          ? nil
          : CGRect(
            x: box.midX - orientedWidth / 2,
            y: box.midY - orientedHeight / 2,
            width: orientedWidth,
            height: orientedHeight
          ),
        imageAspectRatio: CGFloat(image.width) / CGFloat(image.height),
        recognitionConfidence: candidate.confidence,
        isVerticalBlock: vertical,
        verticalCharScale: vertical
          ? OCRGeometry.verticalCharacterScale(
            text: text,
            bounds: box,
            imageSize: CGSize(width: image.width, height: image.height)
          )
          : 0,
        horizontalGlyphScale: vertical ? 0 : (rotation == 0 ? median(wordBoxes.map(\.height)) ?? box.height : orientedHeight),
        replacementPatches: (wordBoxes.isEmpty ? [box] : wordBoxes).map {
          OverlaySourcePatch(box: $0)
        },
        styleRuns: styleRuns(in: text, words: words),
        spacingAnchors: spacingAnchors(in: candidate, map: mapBox),
        recognitionLanguages: observation.recognitionLanguages.map(\.minimalIdentifier),
        continuesToNextLine: observation.shouldWrapToNextLine
      )
    }
  }

  /// Retain native alternatives so source pixels can disambiguate a small
  /// styled word. No custom vocabulary or replacement strings are supplied.
  static func inlineCandidates(in image: CGImage, crop: CGRect, language: Language) async throws -> [TextCandidate] {
    let input = try recognitionImage(in: image, crop: crop, minimumGlyphHeight: crop.height, preferredScale: 3)
    var request = RecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    if language.isAuto { request.automaticallyDetectsLanguage = true }
    else { request.recognitionLanguages = [language.localeLanguage] }
    try configure(&request)
    let observations = try await request.perform(on: input)
    try Task.checkCancellation()
    guard observations.count == 1 else { return [] }
    return observations[0].topCandidates(5).map { .init(text: $0.string, confidence: $0.confidence) }
  }

  // MARK: Private

  private struct RecognizedWord {
    var text: String
    var box: CGRect
  }

  private static func recognitionImage(
    in image: CGImage,
    crop: CGRect,
    minimumGlyphHeight: CGFloat,
    preferredScale: CGFloat
  ) throws -> CGImage {
    let baseSize = OCRCoverage.recognitionSize(crop: crop.size, minimumGlyphHeight: minimumGlyphHeight)
    let scale = max(1, min(preferredScale, 1800 / max(baseSize.width, baseSize.height)))
    let inputSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    guard
      let originalCrop = image.cropping(to: crop), let context = CGContext(
        data: nil,
        width: Int(inputSize.width),
        height: Int(inputSize.height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw CocoaError(.coderInvalidValue) }
    context.interpolationQuality = .high
    context.draw(originalCrop, in: CGRect(origin: .zero, size: inputSize))
    guard let cropped = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
    return cropped
  }

  private static func topLeftBox(_ box: CGRect) -> CGRect {
    CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
  }

  private static func median(_ values: [CGFloat]) -> CGFloat? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  private static func styleRuns(
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

  private static func geometricWords(in candidate: RecognizedText) -> [RecognizedWord] {
    OCRTextTokenization.ranges(in: candidate.string).compactMap { range in
      guard let observation = candidate.boundingBox(for: range) else { return nil }
      return RecognizedWord(
        text: String(candidate.string[range]),
        box: topLeftBox(observation.boundingBox.cgRect)
      )
    }
  }

  private static func spacingAnchors(in candidate: RecognizedText, map: (CGRect) -> CGRect) -> [OCRTextAnchor] {
    let text = candidate.string
    guard
      text.count <= 80, zip(text, text.dropFirst()).contains(where: { OCRTextTokenization.hasUnspacedBoundary(
        between: $0,
        and: $1
      ) })
    else { return [] }
    return text.indices.compactMap { start in
      let range = start..<text.index(after: start)
      guard !text[start].isWhitespace, let observation = candidate.boundingBox(for: range) else { return nil }
      return OCRTextAnchor(range: NSRange(range, in: text), box: map(topLeftBox(observation.boundingBox.cgRect)))
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
