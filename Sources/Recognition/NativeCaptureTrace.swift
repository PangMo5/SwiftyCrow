// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

#if DEBUG
import AppKit
import Foundation

/// Explicit opt-in diagnostics for real screen acquisition. Each capture owns
/// an immutable directory; normal builds perform no image serialization or I/O.
enum NativeCaptureTrace {

  // MARK: Internal

  @MainActor
  static func renderInput(imageData: Data, lines: [OverlayLine], size: CGSize) {
    guard let path = ProcessInfo.processInfo.environment["SWIFTYCROW_NATIVE_TRACE_ROOT"], !path.isEmpty else { return }
    do {
      let directory = URL(fileURLWithPath: path).appendingPathComponent("render-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try imageData.write(to: directory.appendingPathComponent("source.png"))
      let placements = OverlayLayoutEngine.placements(for: lines, in: size)
      let protected = OverlayLayoutEngine.protectedSourceFrames(for: lines, placements: placements, in: size, displayScale: 1)
      let records = lines.map { line -> [String: Any] in
        [
          "id": line.id.uuidString,
          "text": line.source.text,
          "preservesSource": line.source.preservesSource,
          "replacesSource": line.shouldReplaceSourcePixels,
          "sourcePixelsAreCurrent": line.sourcePixelsAreCurrent,
          "target": line.translatedText as Any? ?? NSNull(),
          "patches": line.source.replacementPatches.map { box($0.box) },
        ]
      }
      try JSONSerialization.data(
        withJSONObject: ["size": [size.width, size.height], "lines": records, "protectedFrames": protected.map(box)],
        options: [.prettyPrinted, .sortedKeys]
      ).write(to: directory.appendingPathComponent("input.json"))
    } catch {
      Log.ocr.error("Native render trace failed: \(String(describing: error), privacy: .public)")
    }
  }

  static func capture(
    _ image: CGImage,
    language: Language,
    textReady: @Sendable (OCRResult) async -> Void
  ) async throws -> OCRResult? {
    guard
      OCRPipeline.traceObserver == nil,
      let path = ProcessInfo.processInfo.environment["SWIFTYCROW_NATIVE_TRACE_ROOT"], !path.isEmpty
    else { return nil }
    let directory = URL(fileURLWithPath: path).appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.coderInvalidValue) }
    try png.write(to: directory.appendingPathComponent("source.png"))
    let observer: OCRPipeline.TraceObserver = { stage, lines in
      try write(lines, language: language, to: directory.appendingPathComponent(stage + ".json"))
    }
    return try await OCRPipeline.$traceObserver.withValue(observer) {
      let result = try await OCRPipeline.recognize(image, language: language) { result in
        do { try write(result.lines, language: language, to: directory.appendingPathComponent("text-ready.json")) }
        catch { Log.ocr.error("Native capture trace failed: \(String(describing: error), privacy: .public)") }
        await textReady(result)
      }
      try write(result.lines, language: language, to: directory.appendingPathComponent("complete.json"))
      return result
    }
  }

  // MARK: Private

  private static func box(_ value: CGRect) -> [CGFloat] {
    [value.minX, value.minY, value.width, value.height]
  }

  private static func write(_ lines: [OCRResult.Line], language: Language, to url: URL) throws {
    let languages = LanguageDetectionClient.liveValue.resolveRecognizedSources(for: lines, configured: language)
    let sources = lines.indices.map { OverlayLine.Source(recognized: lines[$0], language: languages[$0].localeLanguage) }
    let groups = TranslationGroupContext.associations(in: sources)
    let records = lines.indices.map { index -> [String: Any] in
      let line = lines[index]
      return [
        "text": line.text,
        "box": box(line.boundingBoxNormalized),
        "rows": line.rowCount,
        "language": sources[index].language.maximalIdentifier,
        "context": line.recognitionContextID as Any? ?? NSNull(),
        "confidence": line.recognitionConfidence,
        "needsReview": line.needsReview,
        "preservesSource": line.preservesSource,
        "fontScale": line.appearance.fontSizeScale,
        "weight": line.appearance.fontWeight.rawValue,
        "surface": line.surface.map { box($0.clippingBox ?? $0.box) } ?? [],
        "background": [line.appearance.background.red, line.appearance.background.green, line.appearance.background.blue],
        "tableCell": line.tableCell.map { [$0.table, $0.row, $0.column] } ?? [],
        "topic": groups[index]?.context.topic ?? "",
        "labels": groups[index]?.context.labels ?? [],
      ]
    }
    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: url)
  }
}
#endif
