// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Synchronization

/// The ordered capture-analysis pipeline. Recognition hypotheses are reconciled
/// before layout; paragraph joining happens once after visual boundaries are known.
enum OCRPipeline {

  // MARK: Internal

  typealias TraceObserver = @Sendable (String, [OCRResult.Line]) throws -> Void

  /// Capture-local diagnostics; ordinary captures perform no serialization or I/O.
  @TaskLocal static var traceObserver: TraceObserver? = nil

  static func recognize(
    _ image: CGImage,
    language: Language,
    textReady: @Sendable (OCRResult) async -> Void = { _ in }
  ) async throws -> OCRResult {
    let clock = ContinuousClock()
    let started = clock.now
    var timings = [String: Double]()
    func logStage(_ stage: String, since start: ContinuousClock.Instant) {
      let elapsed = clock.now - start
      timings[stage] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
      if elapsed >= .milliseconds(500) {
        Log.ocr.log("\(stage, privacy: .public) completed in \(elapsed.loggedSeconds, privacy: .public)s")
      } else {
        Log.ocr.debug("\(stage, privacy: .public) completed in \(elapsed.loggedSeconds, privacy: .public)s")
      }
    }
    try await OCRPreparation.shared.beginRecognition()
    logStage("Recognition preparation wait", since: started)
    let coverageStarted = clock.now
    let detected = try await VisionTextRecognizer.detectedText(in: image)
    logStage("Text coverage detection", since: coverageStarted)
    let regionStarted = clock.now
    let inputs = VisionTextRecognizer.documentInputs(in: image, detectedText: detected)
    logStage("Document region selection", since: regionStarted)
    var prepared = [(image: CGImage, bounds: CGRect, result: OCRResult, restorationComplete: Bool)]()
    let canvas = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    let observer = traceObserver
    for (index, input) in inputs.enumerated() {
      try Task.checkCancellation()
      let region = input.bounds
      guard let localImage = region == canvas ? image : image.cropping(to: region) else {
        throw CocoaError(.coderInvalidValue)
      }
      let localInput = OCRDocumentRegion.Input(
        bounds: CGRect(origin: .zero, size: region.size),
        ownership: input.ownership.map { $0.offsetBy(dx: -region.minX, dy: -region.minY) }
      )
      let localDetectionStarted = clock.now
      let localDetected = region == canvas ? detected : try await VisionTextRecognizer.detectedText(in: localImage)
      let ownedDetected = OCRDocumentRegion.detections(
        in: input,
        imageSize: canvas.size,
        global: detected,
        local: localDetected
      )
      if region != canvas { logStage("Local text coverage detection \(index)", since: localDetectionStarted) }
      let localObserver: TraceObserver? = observer.map { observer in
        { @Sendable stage, lines in
          let prefix = inputs.count > 1 ? "input-\(index)-" : ""
          try observer(prefix + stage, lines)
        }
      }
      let result = try await $traceObserver.withValue(localObserver) {
        try await analyze(localImage, language: language, detected: ownedDetected, input: localInput)
      }
      for (stage, duration) in result.stageDurations { timings[stage, default: 0] += duration }
      prepared.append((localImage, region, result, false))
    }
    /// Each content plane has its own recognition/style context. Compose only
    /// after that context has been resolved, so unrelated neighboring pages do
    /// not change language hints, raster budgets or normalized layout geometry.
    func combined(_ results: [OCRResult]) -> OCRResult {
      var document = VisionTextRecognizer.Document(lines: [], containers: [])
      for (index, result) in results.enumerated() {
        let local = VisionTextRecognizer.Document(
          lines: result.lines,
          containers: [],
          tableCells: result.lines.compactMap(\.tableCell)
        )
        var mapped = OCRDocumentRegion.remap(
          local,
          crop: prepared[index].bounds,
          imageSize: canvas.size
        )
        mapped.lines = mapped.lines.map { line in
          var line = line
          line.recognitionContextID = index
          let bounds = prepared[index].bounds
          line.recognitionContextBounds = CGRect(
            x: bounds.minX / canvas.width,
            y: bounds.minY / canvas.height,
            width: bounds.width / canvas.width,
            height: bounds.height / canvas.height
          )
          return line
        }
        document = VisionTextRecognizer.combining(document, mapped)
      }
      return OCRResult(lines: document.lines)
    }
    // Literal pixels need final artwork ownership before their translation
    // request starts. Resolve only those inputs early and reuse the same tiles;
    // ordinary inputs retain overlap between translation and restoration.
    let literalOwnershipStarted = clock.now
    var resolvedLiteralOwnership = false
    for index in prepared.indices where OCRInlineSourceFragments.requiresResolvedOwnership(prepared[index].result) {
      try Task.checkCancellation()
      let input = prepared[index]
      prepared[index].result = try await OCRInlineSourceFragments.resolving(input.result, image: input.image)
      prepared[index].restorationComplete = true
      resolvedLiteralOwnership = true
      let prefix = inputs.count > 1 ? "input-\(index)-" : ""
      try traceObserver?(prefix + "source-fragments", prepared[index].result.lines)
    }
    if resolvedLiteralOwnership { logStage("Literal ownership and restoration", since: literalOwnershipStarted) }
    try Task.checkCancellation()
    await textReady(combined(prepared.map(\.result)))
    let restorationStarted = clock.now
    var restoredInputs = [OCRResult]()
    for input in prepared {
      try Task.checkCancellation()
      restoredInputs.append(input.restorationComplete ? input.result : await SourceRestorationBuilder.applying(
        to: input.result,
        image: input.image
      ))
    }
    var restored = combined(restoredInputs)
    try traceObserver?("restored", restored.lines)
    logStage("Source restoration", since: restorationStarted)
    try Task.checkCancellation()
    logStage("Complete OCR pipeline", since: started)
    restored.stageDurations = timings
    restored.documentRegions = inputs.map(\.bounds)
    restored.documentOwnershipRegions = inputs.map(\.ownership)
    return restored
  }

  // MARK: Private

  private final class ParagraphTraceBuffer: Sendable {
    let rows = Mutex<[OCRResult.Line]>([])
  }

  /// All geometry and image-dependent analysis stays in one physical input.
  /// The full-frame remainder uses the same pipeline with disjoint ownership.
  private static func analyze(
    _ image: CGImage,
    language: Language,
    detected: [CGRect],
    input: OCRDocumentRegion.Input
  ) async throws -> OCRResult {
    let clock = ContinuousClock()
    var timings = [String: Double]()
    func logStage(_ stage: String, since start: ContinuousClock.Instant) {
      let elapsed = clock.now - start
      timings[stage] = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }
    let recognitionStarted = clock.now
    var document = try await VisionTextRecognizer.document(in: image, language: language, inputs: [input])
    try traceObserver?("native", document.lines)
    Log.ocr.log("Document structure: \(document.tableCells.count, privacy: .public) native table cells")
    logStage("Document recognition", since: recognitionStarted)
    let tableStarted = clock.now
    document = try await OCRTableRecovery.refine(document, image: image, language: language)
    try traceObserver?("tables", document.lines)
    logStage("Structured table reading", since: tableStarted)
    var lines = OCRCandidateReconciler.canonical(OCRTableStructure.classifyingSymbols(.init(lines: document.lines)).lines)
    try traceObserver?("classified", lines)

    let edgeStarted = clock.now
    lines = try await OCRTextEdgeRecovery.recover(lines, image: image, language: language)
    try traceObserver?("edges", lines)
    logStage("Text edge recovery", since: edgeStarted)
    let repeatedRowsStarted = clock.now
    lines = try await OCRTextEdgeRecovery.recoverRows(lines, image: image, language: language) { crop, hint, height in
      try await VisionTextRecognizer.additionalText(
        in: image,
        language: hint,
        crop: crop,
        minimumGlyphHeight: height,
        // Missing rows may mix prose and mathematical/code glyphs. Preserve
        // their observed characters instead of linguistically repairing them;
        // the recognizer retains its shared 1800-pixel input bound.
        preferredScale: 3,
        usesLanguageCorrection: false
      )
    }
    try traceObserver?("repeated-rows", lines)
    logStage("Repeated row recovery", since: repeatedRowsStarted)
    // Coverage uses this input's coordinates and ownership. The remainder
    // input still covers text outside every detached content plane.
    let uncovered = OCRCoverage.uncovered(
      detected,
      by: lines.flatMap(OCRCoverage.evidenceBoxes)
    )
    if let crop = OCRCoverage.cropBounds(for: uncovered, imageSize: CGSize(width: image.width, height: image.height)) {
      let supplementalStarted = clock.now
      let supplemental = try await VisionTextRecognizer.additionalText(
        in: image,
        language: language,
        crop: crop,
        minimumGlyphHeight: (uncovered.map(\.height).min() ?? 0) *
          CGFloat(image.height)
      )
      let previousCount = lines.count
      lines = OCRCandidateReconciler.adding(supplemental, to: lines)
      try traceObserver?("coverage", lines)
      logStage("Uncovered text recognition", since: supplementalStarted)
      Log.ocr.debug("Recognized \(lines.count - previousCount, privacy: .public) additional lines in uncovered text regions")
    }
    let gapRecoveryStarted = clock.now
    let gapRecovered = try await OCRCoverage.recoveringUncoveredRows(detected, recognized: lines, image: image) { crop in
      try await VisionTextRecognizer.additionalText(
        in: image,
        language: language,
        crop: crop,
        minimumGlyphHeight: max(1, crop.height - 6),
        preferredScale: 2
      )
    }
    lines = OCRCandidateReconciler.adding(gapRecovered, to: lines)
    try traceObserver?("gaps", lines)
    logStage("Uncovered mixed-line recovery", since: gapRecoveryStarted)
    try Task.checkCancellation()
    let conflictStarted = clock.now
    lines = try await OCRConflictRecovery.recover(lines, image: image, language: language)
    try traceObserver?("conflicts", lines)
    logStage("Overlapping text recovery", since: conflictStarted)
    let lineRefinementStarted = clock.now
    lines = try await OCRLineRefiner.refine(lines, in: image, language: language)
    try traceObserver?("lines", lines)
    logStage("Line refinement", since: lineRefinementStarted)
    let inlineStarted = clock.now
    lines = try await OCRInlineScriptRecovery.recover(lines, image: image)
    try traceObserver?("scripts", lines)
    logStage("Inline script recovery", since: inlineStarted)
    let wrapStarted = clock.now
    lines = try await OCRSoftWrapRefiner.refine(lines, image: image)
    try traceObserver?("wraps", lines)
    logStage("Visual wrap refinement", since: wrapStarted)
    let balloonRefinementStarted = clock.now
    lines = try await OCRBalloonRefiner.refine(lines, in: image, language: language)
    try traceObserver?("regions", lines)
    logStage("Text region refinement", since: balloonRefinementStarted)
    let rubyStarted = clock.now
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
    logStage("Ruby correction", since: rubyStarted)
    try traceObserver?("ruby", correctedLines)
    let appearanceStarted = clock.now
    // Crop/refinement implementations may construct new rows. Stamp the
    // original image geometry once at the boundary before spatial reasoning;
    // normalized x and y distances are not interchangeable on wide captures.
    let sourceLines = correctedLines.filter { line in
      OCRDocumentRegion.owner(
        of: line.boundingBoxNormalized,
        in: [input],
        imageSize: CGSize(width: image.width, height: image.height)
      ) == 0
    }.map { line in
      var line = line
      line.imageAspectRatio = CGFloat(image.width) / CGFloat(image.height)
      line.tableCell = line.tableCell ?? OCRTableCell.containing(line.boundingBoxNormalized, in: document.tableCells)
      line.recognitionContainer = line.recognitionContainer ?? line.tableCell?.box
        ?? OCRParagraphLineGrouping.container(for: line.boundingBoxNormalized, in: document.containers)
      return line
    }
    let preparedRows = traceObserver == nil ? nil : ParagraphTraceBuffer()
    let didPrepare: (@Sendable ([OCRResult.Line]) -> Void)? =
      if let preparedRows { { @Sendable rows in
        preparedRows.rows.withLock { $0 = rows } } } else { nil }
    let appearanceInput = OCRVisualStructure.classifying(OCRResult(lines: sourceLines).removingNestedDuplicates())
    try traceObserver?("appearance-input", appearanceInput.lines)
    let styled = await OverlaySourceAppearanceAnalyzer.applyingAppearances(
      to: appearanceInput,
      from: image,
      tableCells: document.tableCells,
      didPrepareParagraphs: didPrepare
    )
    if let preparedRows { try traceObserver?("paragraph-input", preparedRows.rows.withLock { $0 }) }
    let glyphStarted = clock.now
    let glyphCorrected = try await OCRInlineGlyphRecovery.recover(styled, image: image, language: language)
    logStage("Inline optical glyph recovery", since: glyphStarted)
    let result = OCRTableStructure.protectingInlineSymbols(glyphCorrected)
    try traceObserver?("appearance", result.lines)
    try Task.checkCancellation()
    logStage("Appearance and paragraph analysis", since: appearanceStarted)
    let reviewStarted = clock.now
    let reviewed = await OCRQualityAssessment.markingUncertainText(in: result, language: language)
    logStage("Recognition quality assessment", since: reviewStarted)
    try Task.checkCancellation()
    var analyzed = reviewed
    analyzed.stageDurations = timings
    return analyzed
  }

}
