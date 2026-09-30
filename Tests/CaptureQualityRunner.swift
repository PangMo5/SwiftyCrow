// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Accessibility
import ComposableArchitecture
import Foundation
import ImageIO
@testable import SwiftyCrow

// MARK: - CaptureQualityReport

struct CaptureQualityReport {
  var missingText: [String]
  var layoutIssues: [String]
  var protectedPixelChanges: Int
  var translationError: String?

  var issues: [String] {
    missingText.map { "Missing source text: \($0)" } + layoutIssues
      + (protectedPixelChanges == 0 ? [] : ["Protected graphic pixels changed"])
      + (translationError.map { [$0] } ?? [])
  }
}

// MARK: - CaptureQualityRunner

@MainActor
final class CaptureQualityRunner {

  // MARK: Internal

  func run(_ item: CaptureQualityCase, root: URL, output: URL) async throws -> CaptureQualityReport {
    guard
      (item.protectedRectangles ?? []).allSatisfy({ region in
        region.count == 4 && region.allSatisfy(\.isFinite) && region[0] >= 0 && region[1] >= 0
          && region[2] > 0 && region[3] > 0 && region[0] + region[2] <= 1 && region[1] + region[3] <= 1
      }),
      (item.textAvoidanceRegions ?? []).allSatisfy({ region in
        region.count == 4 && region.allSatisfy(\.isFinite) && region[2] > 0 && region[3] > 0
      })
    else { throw CocoaError(.coderInvalidValue) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    // A failed rerun must not inherit an earlier successful metrics/image file.
    for suffix in ["ocr.json", "translation.json", "result.png", "metrics.json", "failure.json"] {
      let artifact = output.appendingPathComponent("\(item.id)-\(suffix)")
      if FileManager.default.fileExists(atPath: artifact.path) { try FileManager.default.removeItem(at: artifact) }
    }
    let index = item.id
    let started = ContinuousClock.now
    let data = try Data(contentsOf: root.appendingPathComponent(item.source))
    let source = try required(CGImageSourceCreateWithData(data as CFData, nil))
    let image = try required(CGImageSourceCreateImageAtIndex(source, 0, nil))
    let size = CGSize(width: image.width, height: image.height)
    let prefersHorizontal = AccessibilitySettings.prefersHorizontalTextLayout
    func renderedPNG(_ data: Data, _ lines: [OverlayLine]) throws -> Data {
      try required(CaptureResultImage.render(
        imageData: data,
        imageSize: size,
        lines: lines,
        prefersHorizontalTextLayout: prefersHorizontal
      )?.pngData)
    }
    let language = item.sourceLanguage ?? Language.autoCode
    let traceDirectory = ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_TRACE"] == "1"
      ? output.appendingPathComponent("\(index)-trace-\(UUID().uuidString)")
      : nil
    if let traceDirectory { try FileManager.default.createDirectory(at: traceDirectory, withIntermediateDirectories: true) }
    let reuse = ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_REUSE_OCR"] == "1"
    let cached = reuse && traceDirectory == nil ? recognitionCache.lookup(data: data, language: language) : nil
    let recognition = LockIsolated<OCRResult?>(nil)
    let state = withDependencies { $0.defaultFileStorage = .inMemory } operation: {
      RegionCaptureFeature.State(target: .region(CGRect(origin: .zero, size: size)))
    }
    state.$settings.withLock {
      $0.languages.source = Language(code: item.sourceLanguage ?? Language.autoCode)
      $0.languages.target = Language(code: item.targetLanguage ?? "ko")
      $0.translation.strategy = item.translationStrategy ?? .lowLatency
    }
    let store = Store(initialState: state) { RegionCaptureFeature() } withDependencies: {
      $0.languageDetection = .liveValue
      $0.translation = .liveValue
      $0.uuid = .incrementing
      // The fixture replaces only screen acquisition. Preview encoding,
      // recognition, concurrent translation/restoration and reducer delivery
      // now follow the actual user-action path instead of injecting final OCR.
      $0.screenCapture.captureImage = { _, _, _ in image }
      $0.ocr.recognizeCapture = { image, language, textReady in
        let result: OCRResult
        if let cached {
          await textReady(cached)
          result = cached
        } else {
          let observer: OCRPipeline.TraceObserver? =
            if let directory = traceDirectory {
              { @Sendable stage, lines in
                try Self.writeTrace(lines, to: directory.appendingPathComponent("\(stage).json"))
              }
            } else { nil }
          result = try await OCRPipeline.$traceObserver.withValue(observer) {
            try await OCRClient.liveValue.recognizeCapture(image, language, textReady)
          }
        }
        recognition.setValue(result)
        return result
      }
    }
    await store.send(.task).finish()
    guard let ocr = recognition.value else {
      throw NSError(domain: "CaptureQuality", code: 1, userInfo: [
        NSLocalizedDescriptionKey: store.state.lastError ?? "Capture completed without a recognition result"
      ])
    }
    if reuse, cached == nil { recognitionCache.store(ocr, data: data, language: language) }
    if let traceDirectory, !FileManager.default.fileExists(atPath: traceDirectory.appendingPathComponent("restored.json").path) {
      throw CocoaError(.fileReadNoSuchFile)
    }
    let missingText = CaptureQualityMetrics.missingSourceText(
      ocr.joinedText,
      requiredText: item.requiredText ?? [],
      requiredWords: item.requiredWords ?? [],
      language: item.originalLanguage ?? "en"
    )
    // Isolate app-owned image analysis from Vision's asynchronous model
    // compilation when collecting a CPU sample for a specific capture.
    if let count = ProcessInfo.processInfo.environment["SWIFTYCROW_QUALITY_APPEARANCE_REPEATS"].flatMap(Int.init) {
      try Data().write(to: output.appendingPathComponent("appearance-ready"))
      for _ in 0 ..< max(0, min(count, 10)) {
        _ = await OverlaySourceAppearanceAnalyzer.applyingAppearances(to: ocr, from: image)
      }
    }
    try write(ocr.lines.map { line in
      [
        "text": line.text,
        "confidence": line.recognitionConfidence,
        "box": box(line.boundingBoxNormalized),
        "group": line.recognitionGroupID ?? -1,
        "recognitionContainer": line.recognitionContainer.map(box) ?? [],
        "recognitionLanguages": line.recognitionLanguages,
        "recognitionContext": line.recognitionContextID ?? -1,
        "recognitionContextBounds": line.recognitionContextBounds.map(box) ?? [],
        "continuesToNextLine": line.continuesToNextLine as Any? ?? NSNull(),
        "tableCell": line.tableCell.map { [$0.table, $0.row, $0.column] } ?? [],
        "tableCellBox": line.tableCell.map { box($0.box) } ?? [],
        "rows": line.rowCount,
        "alignment": line.alignment.map { String(describing: $0) } ?? "unspecified",
        "vertical": line.isVerticalBlock,
        "glyphScale": line.verticalCharScale,
        "reconstructed": line.isReconstructedTextRegion,
        "preventsJoining": line.preventsJoining,
        "preservesSource": line.preservesSource,
        "needsReview": line.needsReview,
        "fontScale": line.appearance.fontSizeScale,
        "rotation": line.rotationRadians,
        "orientedBox": line.orientedBox.map(box) ?? [],
        "background": [line.appearance.background.red, line.appearance.background.green, line.appearance.background.blue],
        "weight": line.appearance.fontWeight.rawValue,
        "glyph": line.horizontalGlyphScale,
        "ink": line.horizontalInkScale,
        "surface": line.surface.map { box($0.box) } ?? [],
        "surfaceClippingBox": line.surface?.clippingBox.map(box) ?? [],
        "surfaceConfidence": line.surface?.confidence ?? 0,
        "textFlowRegions": line.textFlowRegions.map(box),
        "layoutExclusions": line.layoutExclusions.map(box),
        "runs": line.styleRuns.map { [
          "range": [$0.range.location, $0.range.length],
          "box": box($0.box),
          "inkBox": $0.inkBox.map(box) ?? [],
          "sourceFragment": $0.sourceFragment.map { [
            Double($0.width),
            Double($0.height),
            Double($0.descent),
            Double($0.referenceFontSize),
          ] } ?? [],
          "fontScale": $0.appearance.fontSizeScale,
          "design": String(describing: $0.appearance.fontDesign),
          "weight": $0.appearance.fontWeight.rawValue,
          "background": [$0.appearance.background.red, $0.appearance.background.green, $0.appearance.background.blue],
          "foreground": [$0.appearance.foreground.red, $0.appearance.foreground.green, $0.appearance.foreground.blue],
        ] },
        "patches": line.replacementPatches.map { box($0.box) },
        "patchDetails": line.replacementPatches.map(Self.patchRecord),
      ] as [String: Any]
    }, to: output.appendingPathComponent("\(index)-ocr.json"))
    let final = store.state
    let placements = OverlayLayoutEngine.placements(
      for: final.overlayLines,
      in: size,
      prefersHorizontalTextLayout: prefersHorizontal
    )
    let missingPlacements = final.overlayLines.filter { line in
      line.shouldReplaceSourcePixels && !placements.contains(where: { $0.id == line.id })
    }.map { "No complete collision-free text placement: \($0.source.text)" }
    let missingFragments = final.overlayLines.filter { line in
      line.source.styleRuns.contains(where: { $0.sourceFragment != nil })
        &&
        (line
          .isUnavailable ||
          (line.translatedText != nil && line.translatedText != line.source.text && !line.shouldReplaceSourcePixels))
    }.map { "Required source-fragment mapping unavailable: \($0.source.text)" }
    var layoutIssues = missingPlacements + missingFragments
      + CaptureQualityMetrics.sourceFragmentIssues(lines: final.overlayLines, expected: item.requiredSourceFragments ?? [])
      + (item.requiredTranslatedText ?? [])
      .compactMap { required -> String? in
        final.overlayLines.contains(where: {
          $0.source.text.localizedCaseInsensitiveContains(required) && $0.translatedText != nil && !$0.isUnavailable
        }) ? nil : "Required prose was not translated: \(required)"
      } + CaptureQualityMetrics.paragraphIssues(
        texts: ocr.lines.map(\.text),
        expected: item.requiredParagraphs ?? []
      ) + CaptureQualityMetrics.styleIssues(lines: final.overlayLines, expected: item.requiredStyles ?? [])
      + CaptureQualityMetrics.alignmentIssues(placements, expected: item.requiredAlignments ?? [])
      + CaptureQualityMetrics.fontScaleIssues(placements, canvas: size, expected: item.requiredFontScales ?? [])
      + CaptureQualityMetrics.lineCountIssues(placements, expected: item.requiredLineCounts ?? [])
      + CaptureQualityMetrics.translationIssues(final.overlayLines, expected: item.requiredTranslations ?? [])
      + CaptureQualityMetrics.literalIssues(lines: final.overlayLines, expected: item.requiredLiteralText ?? [])
      + CaptureQualityMetrics.proseIssues(lines: final.overlayLines, expected: item.requiredProseText ?? [])
      + CaptureQualityMetrics.foreignRegionIssues(placements, canvas: size, regions: (item.textAvoidanceRegions ?? []).map {
        CGRect(x: $0[0] * size.width, y: $0[1] * size.height, width: $0[2] * size.width, height: $0[3] * size.height)
      })
      + CaptureQualityMetrics.layoutIssues(
        placements,
        canvas: size,
        minimumFontRatio: item.minimumFontRatio ?? 0.35
      )
    try write(final.overlayLines.map { line in
      let placement = placements.first { $0.id == line.id }
      return [
        "source": line.source.text,
        "protectedRequest": TranslationLiteralPlan(line.source.attributedTextForTranslation())?.requestText ?? "",
        "target": line.displayedText,
        "language": line.source.language.maximalIdentifier,
        "unavailable": line.isUnavailable,
        "preserved": line.translatedText == nil,
        "font": placement?.fontSize ?? 0,
        "rowAlignment": line.source.rowAlignment.map { String(describing: $0) } ?? "unspecified",
        "rowAlignmentEvidence": String(describing: line.source.rowAlignmentEvidence),
        "sourceAlignment": line.source.alignment.map { String(describing: $0) } ?? "unspecified",
        "alignment": placement.map { String(describing: $0.alignment) } ?? "none",
        "styleRuns": line.displayedStyleRuns.map { [
          "range": [$0.range.location, $0.range.length],
          "background": [$0.appearance.background.red, $0.appearance.background.green, $0.appearance.background.blue],
          "foreground": [$0.appearance.foreground.red, $0.appearance.foreground.green, $0.appearance.foreground.blue],
          "weight": $0.appearance.fontWeight.rawValue,
        ] },
        "frame": placement.map { box($0.frame) } ?? [],
        "rotation": placement?.rotationRadians ?? 0,
        "verticalWrapping": placement.map { String(describing: $0.verticalWrapping) } ?? "none",
        "visualFrame": placement.map { box($0.visualFrame) } ?? [],
        "textFlowRegions": placement.map { $0.textFlowRegions.map(box) } ?? [],
        "layoutExclusions": line.source.layoutExclusions.map(box),
      ] as [String: Any]
    }, to: output.appendingPathComponent("\(index)-translation.json"))
    let translatedAt = ContinuousClock.now
    let png = try renderedPNG(data, final.overlayLines)
    let renderedAt = ContinuousClock.now
    if let maximum = item.maximumReviewLines {
      let count = ocr.lines.count(where: \.needsReview)
      if maximum < 0 || count > maximum {
        layoutIssues.append("Review-required source lines \(count) exceed \(maximum)")
      }
    }
    let renderedSource = try required(CGImageSourceCreateWithData(png as CFData, nil))
    let rendered = try required(CGImageSourceCreateImageAtIndex(renderedSource, 0, nil))
    let protectedRects = (item.protectedRectangles ?? []).filter { $0.count == 4 }.map { CGRect(
      x: $0[0],
      y: $0[1],
      width: $0[2],
      height: $0[3]
    ) }
    let protectedChanges = CaptureQualityMetrics.protectedPixelChanges(
      original: image,
      rendered: rendered,
      rectangles: protectedRects
    )
    try png.write(to: output.appendingPathComponent("\(index)-result.png"))
    let backgroundExpectations = item.requiredRestoredBackgrounds ?? []
    let restorationOnlyPNG = traceDirectory != nil || !backgroundExpectations.isEmpty
      ? try renderedPNG(data, final.overlayLines.map(CaptureQualityMetrics.hidingTargetInk))
      : nil
    if !backgroundExpectations.isEmpty, let restorationOnlyPNG {
      let source = try required(CGImageSourceCreateWithData(restorationOnlyPNG as CFData, nil))
      let image = try required(CGImageSourceCreateImageAtIndex(source, 0, nil))
      layoutIssues += CaptureQualityMetrics.restoredBackgroundIssues(image, expected: backgroundExpectations)
    }
    if let traceDirectory {
      try restorationOnlyPNG?.write(to: traceDirectory.appendingPathComponent("restoration-only.png"))
      let clear = try required(CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      ))
      clear.clear(CGRect(origin: .zero, size: size))
      let transparent = try required(clear.makeImage()?.pngData)
      let targetOnly = final.overlayLines.map { source in
        var line = source
        line.source.replacementPatches = []
        return line
      }
      try renderedPNG(transparent, targetOnly)
        .write(to: traceDirectory.appendingPathComponent("target-only.png"))
      let unconstrained = targetOnly.map { source in
        var line = source
        line.source.layoutExclusions = []
        return line
      }
      try renderedPNG(transparent, unconstrained)
        .write(to: traceDirectory.appendingPathComponent("unconstrained-target-only.png"))
      for (lineIndex, line) in final.overlayLines.enumerated() {
        for (patchIndex, patch) in line.source.replacementPatches.enumerated() {
          if let tile = patch.restorationPNG {
            try tile.write(to: traceDirectory.appendingPathComponent("line-\(lineIndex)-patch-\(patchIndex).png"))
          }
        }
      }
    }
    try write([
      "ocrReused": cached != nil,
      "prefersHorizontalTextLayout": prefersHorizontal,
      "traceDirectory": traceDirectory?.lastPathComponent ?? "",
      "ocrSeconds": ocr.stageDurations["Complete OCR pipeline"] ?? 0,
      "actionLatency": final.latency,
      "sourceAcquisition": "fixture",
      "translationStrategy": (item.translationStrategy ?? .lowLatency).rawValue,
      "pipelineSeconds": seconds(started.duration(to: translatedAt)),
      "renderSeconds": seconds(translatedAt.duration(to: renderedAt)),
      "stages": ocr.stageDurations,
      "documentRegions": ocr.documentRegions.map { [$0.minX, $0.minY, $0.width, $0.height] },
      "documentOwnershipRegions": ocr.documentOwnershipRegions.map { $0.map { [$0.minX, $0.minY, $0.width, $0.height] } },
      "error": final.lastError ?? "",
      "layoutIssues": layoutIssues,
      "missingText": missingText,
      "reviewLineCount": ocr.lines.count(where: \.needsReview),
      "protectedPixelChanges": protectedChanges,
    ], to: output.appendingPathComponent("\(index)-metrics.json"))
    return CaptureQualityReport(
      missingText: missingText,
      layoutIssues: layoutIssues,
      protectedPixelChanges: protectedChanges,
      translationError: final.lastError
    )
  }

  // MARK: Private

  private var recognitionCache = CaptureQualityRecognitionCache()

  private nonisolated static func writeTrace(_ lines: [OCRResult.Line], to url: URL) throws {
    func rect(_ value: CGRect) -> [CGFloat] {
      [value.minX, value.minY, value.width, value.height]
    }
    let records: [[String: Any]] = lines.map { line in
      [
        "text": line.text,
        "box": rect(line.boundingBoxNormalized),
        "rows": line.rowCount,
        "group": line.recognitionGroupID ?? -1,
        "container": line.recognitionContainer.map(rect) ?? [],
        "surface": line.surface.map { rect($0.box) } ?? [],
        "aspect": line.imageAspectRatio,
        "glyph": line.horizontalGlyphScale,
        "ink": line.horizontalInkScale,
        "preventsJoining": line.preventsJoining,
        "reconstructed": line.isReconstructedTextRegion,
        "rotation": line.rotationRadians,
        "orientedBox": line.orientedBox.map(rect) ?? [],
        "layoutExclusions": line.layoutExclusions.map(rect),
        "cell": line.tableCell.map { [$0.table, $0.row, $0.column] } ?? [],
        "cellBox": line.tableCell.map { rect($0.box) } ?? [],
        "confidence": line.recognitionConfidence,
        "preserved": line.preservesSource,
        "needsReview": line.needsReview,
        "vertical": line.isVerticalBlock,
        "languages": line.recognitionLanguages,
        "wraps": line.continuesToNextLine as Any? ?? NSNull(),
        "fontScale": line.appearance.fontSizeScale,
        "weight": line.appearance.fontWeight.rawValue,
        "foregroundConfidence": line.appearance.foregroundConfidence,
        "backgroundConfidence": line.appearance.confidence,
        "background": [line.appearance.background.red, line.appearance.background.green, line.appearance.background.blue],
        "foreground": [line.appearance.foreground.red, line.appearance.foreground.green, line.appearance.foreground.blue],
        "styles": line.styleRuns.map { ["range": [$0.range.location, $0.range.length], "box": rect($0.box)] as [String: Any] },
        "patches": line.replacementPatches.map(Self.patchRecord),
      ]
    }
    try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
  }

  private nonisolated static func patchRecord(_ patch: OverlaySourcePatch) -> [String: Any] {
    func values(_ rect: CGRect) -> [Double] {
      [rect.minX, rect.minY, rect.width, rect.height]
    }
    return [
      "box": values(patch.renderingBox ?? patch.box),
      "observedBox": values(patch.box),
      "clip": patch.clippingBox.map(values) ?? [],
      "bitmapBytes": patch.restorationPNG?.count ?? 0,
      "annotation": patch.isAnnotation,
      "erasesSurface": patch.erasesDistinctSurface,
    ]
  }

  private func required<T>(_ value: T?) throws -> T {
    guard let value else { throw CocoaError(.coderInvalidValue) }
    return value
  }

  private func seconds(_ value: Duration) -> Double {
    Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18
  }

  private func box(_ rect: CGRect) -> [Double] {
    [rect.minX, rect.minY, rect.width, rect.height]
  }

  private func write(_ value: Any, to url: URL) throws {
    try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: url)
  }
}
