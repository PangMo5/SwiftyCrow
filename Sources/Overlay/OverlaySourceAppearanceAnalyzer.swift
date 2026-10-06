// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - OverlaySourceAppearanceAnalyzer

enum OverlaySourceAppearanceAnalyzer {

  // MARK: Internal

  /// Preserve enough samples per source glyph even when a large window has
  /// generous empty margins. A fixed whole-image cap erased small-font evidence.
  /// The lower quartile resists isolated tiny OCR noise; allocation stays bounded.
  static func appearanceRasterLongestSide(for result: OCRResult, imageSize: CGSize) -> Int {
    OCRGeometry.analysisRasterLongestSide(for: result.lines.filter {
      !$0.preservesSource && !OCRTextSemantics.isIdentifier($0.text) && !OCRTextSemantics.isCode($0.text)
        && $0.text.contains(where: \.isLetter)
    }, imageSize: imageSize)
  }

  static func applyingAppearances(
    to result: OCRResult,
    from image: CGImage,
    tableCells: [OCRTableCell] = [],
    didPrepareParagraphs: (@Sendable ([OCRResult.Line]) -> Void)? = nil
  ) async -> OCRResult {
    let styleRaster = PixelRaster(image: image, longestSide: appearanceRasterLongestSide(
      for: result,
      imageSize: CGSize(width: image.width, height: image.height)
    ))
    let surfaceRaster = PixelRaster(image: image, longestSide: 384)
    let styled = OCRResult(lines: await CaptureAnalysisExecutor.map(result.lines) { line in
      // Literal pixels will not be replaced. Sampling every word and flood
      // filling their surfaces adds work without contributing to the result.
      if line.preservesSource || OCRTextSemantics.isIdentifier(line.text) || OCRTextSemantics.isCode(line.text) {
        return line
      }
      var line = line
      let originalBox = line.boundingBoxNormalized
      let originalBackground = styleRaster.flatMap {
        sampledSurroundingBackground(around: originalBox, raster: $0)
      }
      let ruleBand = styleRaster.flatMap { raster in
        originalBackground.map { horizontalRuleSamplingBand(around: line, background: $0, raster: raster) }
      } ?? CGRect(x: 0, y: 0, width: 1, height: 1)
      let ownership = OCRSpatialOwnership.samplingRegion(for: line, among: result.lines)
      let samplingBand = ownership.bounds.intersection(ruleBand)
      let samplingRaster = styleRaster.map { raster in
        ownership.isSlanted ? PixelRaster(raster: raster, ownership: ownership) : raster
      }
      // A divider extends beyond the text and is not owned by any of its
      // words. Bound both measurement and erasure before later style splitting
      // creates fresh patches from the range geometry.
      if ruleBand.height < 1 {
        line.boundingBoxNormalized = line.boundingBoxNormalized.intersection(ruleBand)
        line.styleRuns = line.styleRuns.map { run in
          var run = run
          run.box = run.box.intersection(ruleBand)
          return run
        }.filter { !$0.box.isNull && !$0.box.isEmpty }
        line.replacementPatches = line.replacementPatches.map { patch in
          var patch = patch
          patch.box = patch.box.intersection(ruleBand)
          return patch
        }.filter { !$0.box.isNull && !$0.box.isEmpty }
      }
      if let samplingRaster, let background = originalBackground {
        line = SourceArtworkIsolation.refine(
          line,
          width: samplingRaster.width,
          height: samplingRaster.height,
          background: background,
          sample: { x, y in samplingRaster.color(at: y * samplingRaster.width + x) }
        )
      }
      let lineAppearance = samplingRaster.map {
        appearance(around: line.boundingBoxNormalized, raster: $0, within: samplingBand)
      } ?? .fallback
      let surroundingBackground = (line.boundingBoxNormalized == originalBox ? originalBackground : nil) ?? samplingRaster
        .flatMap {
          sampledSurroundingBackground(around: line.boundingBoxNormalized, raster: $0)
        } ?? lineAppearance.background
      if let samplingRaster, !line.isVerticalBlock, !line.spacingAnchors.isEmpty {
        line.styleRuns = splitChromaticRuns(
          line.styleRuns,
          anchors: line.spacingAnchors,
          raster: samplingRaster,
          band: samplingBand
        )
      }
      if let samplingRaster, !line.isVerticalBlock {
        line.styleRuns = separatingChromaticReferences(line, raster: samplingRaster, band: samplingBand)
      }
      let observedRuns = line.styleRuns
      var sampledRuns = [(box: CGRect, appearance: OverlaySourceAppearance)]()
      line.styleRuns = observedRuns.map { run in
        var run = run
        if let samplingRaster {
          // Vision can give punctuation and its word the same indivisible
          // rectangle. Calibrate against all text observed in that rectangle,
          // never against a digit that incorrectly owns the whole word's ink.
          if let sample = sampledRuns.first(where: { sameBox($0.box, run.box) }) {
            run.appearance = sample.appearance
          } else {
            let sharedRange = observedRuns.filter { sameBox($0.box, run.box) }
              .reduce(run.range) { NSUnionRange($0, $1.range) }
            run.appearance = appearance(
              around: run.box,
              raster: samplingRaster,
              text: text(in: sharedRange, source: line.text),
              within: samplingBand
            )
            sampledRuns.append((run.box, run.appearance))
          }
          if line.isVerticalBlock || abs(line.rotationRadians) > 0.04 {
            run.appearance.isItalic = false
          }
          run.appearance.fontDesign = fontDesign(
            for: text(in: run.range, source: line.text),
            appearance: run.appearance,
            surroundingBackground: surroundingBackground
          )
          if
            !line.isVerticalBlock, let ink = observedInkBox(
              run.box,
              appearance: run.appearance,
              raster: samplingRaster,
              within: samplingBand
            )
          {
            run.inkBox = ink
          }
        }
        return run
      }
      let sourceLength = (line.text as NSString).length
      let distinctStyleRuns = line.styleRuns.filter { run in
        let isPartialStyle = run.range.location > 0 || NSMaxRange(run.range) < sourceLength
        return isPartialStyle
          && run.appearance.background.distance(to: surroundingBackground) >= 0.025
      }
      // Vision tokenizes punctuation separately, so a standalone pill such as
      // `On-device` arrives as three partial runs even though the compact
      // surface belongs to the whole line. Only erase a styled surface when
      // the distinct runs leave other visible source text outside them.
      let inlineStyleRuns = coversVisibleSource(distinctStyleRuns, in: line.text)
        ? []
        : distinctStyleRuns
      let patches = line.replacementPatches.isEmpty
        ? [OverlaySourcePatch(box: line.boundingBoxNormalized)]
        : line.replacementPatches
      line.replacementPatches = patches.map { patch in
        var patch = patch
        if let styleRun = line.styleRuns.first(where: { sameBox($0.box, patch.box) }) {
          patch.appearance = styleRun.appearance
          if inlineStyleRuns.contains(where: { sameBox($0.box, styleRun.box) }) {
            // Inline code and badges carry their own source background. Erase
            // that old compact surface back to the parent container; the
            // mapped target style redraws the chip at the translated token's
            // new position. Keeping the source surface produced empty pills.
            patch.appearance.background = surroundingBackground
            patch.erasesDistinctSurface = true
          }
        } else if let samplingRaster {
          patch.appearance = appearance(around: patch.box, raster: samplingRaster, within: samplingBand)
        }
        return patch
      }
      if let samplingRaster, !inlineStyleRuns.isEmpty {
        line.replacementPatches.append(contentsOf: inlineSurfaceErasers(
          for: inlineStyleRuns,
          parentBackground: surroundingBackground,
          raster: samplingRaster
        ))
      }
      let appearanceSamples: [WeightedAppearance]
      if line.styleRuns.isEmpty {
        appearanceSamples = line.replacementPatches.map {
          WeightedAppearance(appearance: $0.appearance)
        }
      } else {
        let textLength = (line.text as NSString).length
        let coveredLength = min(
          textLength,
          line.styleRuns.reduce(0) { $0 + max(0, $1.range.length) }
        )
        var samples = line.styleRuns.map {
          WeightedAppearance(
            appearance: $0.appearance,
            weight: CGFloat(max(1, $0.range.length))
          )
        }
        if coveredLength < textLength {
          samples.append(WeightedAppearance(
            appearance: lineAppearance,
            weight: CGFloat(textLength - coveredLength)
          ))
        }
        appearanceSamples = samples
      }
      let neutralSamples = appearanceSamples.filter {
        $0.appearance.fontSizeScale > 0
          && !$0.appearance.isUnderlined && !isChromatic($0.appearance.foreground)
          && $0.appearance.background.distance(to: surroundingBackground) < 0.06
      }
      // A long URL must not turn the surrounding sentence into a blue link.
      // The neutral prose supplies the base; mapped spans retain link styling.
      let hasInlineLink = appearanceSamples.contains { $0.appearance.isUnderlined || isChromatic($0.appearance.foreground) }
      line.appearance = combinedAppearance(
        hasInlineLink && !neutralSamples.isEmpty ? neutralSamples : appearanceSamples,
        fallback: lineAppearance
      )
      if line.isVerticalBlock, line.verticalCharScale > 0 {
        // A vertical word's total height is not its font size. Calibrate from
        // one physical glyph width before comparing neighboring columns.
        let scale = line.verticalCharScale * CGFloat(image.width) / CGFloat(image.height)
        line.appearance.fontSizeScale = scale
        line.styleRuns = line.styleRuns.map { run in
          var run = run
          run.appearance.fontSizeScale = scale
          return run
        }
      }
      if
        !line.replacementPatches.contains(where: { $0.erasesDistinctSurface || $0.isAnnotation }),
        shouldConsolidatePatches(
          line.replacementPatches,
          into: lineAppearance,
          isVertical: line.isVerticalBlock
        )
      {
        // A flat line is cleaner as one restoration surface: punctuation and
        // anti-aliased word edges cannot leak through. Keep word patches only
        // when they reveal multiple backgrounds, such as text inside a button
        // whose surrounding ring crosses the control border.
        line.replacementPatches = [
          OverlaySourcePatch(box: line.boundingBoxNormalized, appearance: lineAppearance)
        ]
      }
      if
        !line.isVerticalBlock,
        let samplingRaster,
        Self.isChromatic(line.appearance.foreground),
        Self.isLightNeutral(line.appearance.background)
      {
        var restorationAppearance = lineAppearance
        restorationAppearance.background = surroundingBackground
        let patch = OverlaySourcePatch(
          box: line.boundingBoxNormalized,
          appearance: restorationAppearance
        )
        line.replacementPatches = [patch]
        if let rubyPatch = nearbyChromaticRubyPatch(above: patch, raster: samplingRaster) {
          line.replacementPatches.append(rubyPatch)
        }
      }
      // Ruby belongs to the same logical translation, but can be printed on
      // the paper outside a colored label. Infer that label's physical surface
      // from its main glyph geometry rather than the ruby-expanded parent box.
      let surfaceAnchor = physicalSurfaceAnchor(for: line)
      let hasObservedInterior = line.surface.map { $0.confidence == 1 && !$0.clippingRows.isEmpty } ?? false
      line.surface = (line.isReconstructedTextRegion || hasObservedInterior ? line.surface : nil) ?? surfaceRaster.flatMap {
        inferredSurface(
          containing: surfaceAnchor,
          appearance: line.appearance,
          raster: $0,
          limitingTo: OCRVisualStructure.surfaceSearchBounds(for: line, among: result.lines)
        )
      }
      let hasDistinctCompactFill = line.rowCount == 1
        && line.appearance.background.distance(to: surroundingBackground) >= 0.18
      if line.surface == nil, hasDistinctCompactFill, let samplingRaster {
        // The low-resolution flood fill is normally enough for cards and
        // balloons. Densely lettered pills can leave only a one-pixel corridor
        // at that scale, though, so retry just those compact high-contrast
        // candidates with the style raster already held in memory.
        line.surface = inferredSurface(
          containing: surfaceAnchor,
          appearance: line.appearance,
          raster: samplingRaster,
          limitingTo: OCRVisualStructure.surfaceSearchBounds(for: line, among: result.lines),
          minimumConfidence: 0.30,
          acceptedConfidenceFloor: 0.35
        )
      }
      if line.surface == nil, line.rowCount == 1, line.tableCell == nil, let styleRaster {
        // A one-pixel outline can disappear in the whole-page surface raster.
        // Search only a compact neighborhood at glyph resolution, and require
        // an enclosed component; whitespace cut off by this search is not a control.
        let limit = surfaceAnchor.insetBy(dx: -surfaceAnchor.width * 0.65, dy: -surfaceAnchor.height * 1.1)
          .intersection(OCRVisualStructure.surfaceSearchBounds(for: line, among: result.lines))
        if
          let surface = inferredSurface(
            containing: surfaceAnchor,
            appearance: line.appearance,
            raster: styleRaster,
            limitingTo: limit
          ), isCompactTextSurface(surface, around: surfaceAnchor)
        {
          line.surface = surface
        }
      }
      if
        hasDistinctCompactFill,
        let surface = line.surface,
        isCompactTextSurface(surface, around: surfaceAnchor)
      {
        line.surface = applyingCompactTextInsets(to: surface)
      }
      if
        hasDistinctCompactFill,
        let surface = line.surface,
        let samplingRaster,
        isCompactTextSurface(surface, around: surfaceAnchor),
        let refined = compactSurfaceAppearance(
          for: surfaceAnchor,
          inside: surface,
          original: line.appearance,
          surroundingBackground: surroundingBackground,
          raster: samplingRaster
        )
      {
        let original = line.appearance
        line.appearance = refined
        line.styleRuns = line.styleRuns.map { run in
          var run = run
          guard run.appearance.background.distance(to: original.background) <= 0.08 else {
            return run
          }
          run.appearance.background = refined.background
          if
            run.appearance.foregroundConfidence < 0.08
            || run.appearance.foreground.distance(to: original.foreground) <= 0.12
          {
            run.appearance.foreground = refined.foreground
            run.appearance.foregroundConfidence = refined.foregroundConfidence
            run.appearance.inkCoverage = refined.inkCoverage
            run.appearance.inkHeightScale = refined.inkHeightScale
            run.appearance.fontWeight = refined.fontWeight
            run.appearance.isUnderlined = refined.isUnderlined
          }
          return run
        }
        line.replacementPatches = line.replacementPatches.map { patch in
          var patch = patch
          guard patch.appearance.background.distance(to: original.background) <= 0.08 else {
            return patch
          }
          patch.appearance.background = refined.background
          patch.appearance.foreground = refined.foreground
          patch.appearance.foregroundConfidence = refined.foregroundConfidence
          patch.appearance.inkCoverage = refined.inkCoverage
          patch.appearance.inkHeightScale = refined.inkHeightScale
          patch.appearance.fontWeight = refined.fontWeight
          patch.appearance.isUnderlined = refined.isUnderlined
          return patch
        }
      }
      if !line.isVerticalBlock, line.appearance.inkHeightScale > 0 {
        line.horizontalInkScale = line.appearance.inkHeightScale
      }
      if ruleBand.height < 1 {
        line.replacementPatches = line.replacementPatches.map { patch in
          var patch = patch
          patch.clippingBox = ruleBand
          return patch
        }
      }
      return line
    })
    let assigned = OCRTableStructure.classifyingObservedCells(styled, cells: tableCells)
    let references = styleRaster.map { completingChromaticReferences(assigned, raster: $0) } ?? assigned
    let separated = OCRInlineSourceFragments.capturingAnnotations(
      OCRVisualStructure.separatingCompoundControls(OCRVisualStructure.separatingStyleAccessories(references)),
      image: image
    )
    let rubyOwned = OCRInlineSourceFragments.capturingCodeLiterals(
      OCRInlineSourceFragments.capturingRubyAnnotations(separated, image: image),
      image: image
    )
    let spaced = styleRaster.map { raster in
      OCRVisualSpacing.refining(
        rubyOwned,
        width: raster.width,
        height: raster.height,
        sample: { x, y in raster.color(at: y * raster.width + x) }
      )
    } ?? rubyOwned
    let prepared = OCRVisualStructure.preservingIdentifierTags(spaced.removingNestedDuplicates()).absorbingRubyAnnotations()
    didPrepareParagraphs?(prepared.lines)
    let coalesced = prepared.coalescingParagraphFragments(clearVerticalExpansion: styleRaster.map { raster in
      { lhs, rhs in
        OCRVerticalParagraphGrouping.clearExpansion(from: lhs, to: rhs, width: raster.width, height: raster.height) {
          raster.color(at: $1 * raster.width + $0)
        }
      }
    })
    let allocated = styleRaster.map { raster in
      OCRLayoutRegionAllocator.allocating(
        coalesced,
        width: raster.width,
        height: raster.height,
        sample: { x, y in raster.color(at: y * raster.width + x) }
      )
    } ?? coalesced
    return OCRResult(lines: await CaptureAnalysisExecutor.map(allocated.lines) { line in
      var line = line
      let clippingBox = line.replacementPatches.compactMap(\.clippingBox).first
      if line.wasCoalesced, !line.isVerticalBlock, let styleRaster {
        let sampledUnion = appearance(around: line.boundingBoxNormalized, raster: styleRaster)
        let surroundingBackground = sampledSurroundingBackground(
          around: line.boundingBoxNormalized,
          raster: styleRaster
        ) ?? sampledUnion.background
        let parentCandidates = line.styleRuns.compactMap { run -> WeightedAppearance? in
          guard run.appearance.background.distance(to: surroundingBackground) <= 0.06 else {
            return nil
          }
          return WeightedAppearance(
            appearance: run.appearance,
            weight: CGFloat(max(1, run.range.length))
          )
        }
        let neutralCandidates = parentCandidates.filter {
          $0.appearance.fontSizeScale > 0
            && !$0.appearance.isUnderlined && !isChromatic($0.appearance.foreground)
        }
        let parentSamples = neutralCandidates.isEmpty ? parentCandidates : neutralCandidates
        var unionAppearance = combinedAppearance(parentSamples, fallback: sampledUnion)
        unionAppearance.background = surroundingBackground
        unionAppearance.fontDesign = fontDesign(
          for: line.text,
          appearance: unionAppearance,
          surroundingBackground: surroundingBackground
        )
        line.appearance = unionAppearance
      }
      if let surfaceRaster {
        let sourceBox = physicalSurfaceAnchor(for: line).standardized
        let previousSurface = line.surface.flatMap { surface -> OverlaySourceSurface? in
          let bounds = (surface.clippingBox ?? surface.box).standardized
          let intersection = bounds.intersection(sourceBox)
          guard !intersection.isNull, !intersection.isEmpty else { return nil }
          let sourceArea = max(0.000_001, sourceBox.width * sourceBox.height)
          return intersection.width * intersection.height / sourceArea >= 0.94
            ? surface
            : nil
        }
        // Initial analysis already found or rejected a surface for every
        // unmerged line. Re-run the flood fill only when coalescing changed the
        // source bounds, or when that change invalidated a previously found
        // surface. The old unconditional pass doubled this cost on dense pages.
        let needsSurfaceRefresh = line.wasCoalesced
          || (line.surface != nil && previousSurface == nil)
        let updatedSurface = needsSurfaceRefresh
          ? inferredSurface(
            containing: sourceBox,
            appearance: line.appearance,
            raster: surfaceRaster,
            limitingTo: previousSurface?.clippingBox
          )
          : nil
        line.surface = previousSurface.flatMap {
          isCompactTextSurface($0, around: sourceBox) ? $0 : nil
        } ?? updatedSurface ?? previousSurface
      }
      if let styleRaster {
        let sourceLength = (line.text as NSString).length
        let inlineStyleRuns = line.styleRuns.filter { run in
          let isPartialStyle = run.range.location > 0 || NSMaxRange(run.range) < sourceLength
          return isPartialStyle
            && run.appearance.background.distance(to: line.appearance.background) >= 0.025
        }
        if !inlineStyleRuns.isEmpty, !coversVisibleSource(inlineStyleRuns, in: line.text) {
          line.replacementPatches = line.replacementPatches.map { patch in
            var patch = patch
            guard inlineStyleRuns.contains(where: { sameBox($0.box, patch.box) }) else {
              return patch
            }
            patch.appearance.background = line.appearance.background
            patch.erasesDistinctSurface = true
            return patch
          }
          let erasers = inlineSurfaceErasers(
            for: inlineStyleRuns,
            parentBackground: line.appearance.background,
            raster: styleRaster
          ).filter { candidate in
            !line.replacementPatches.contains { existing in
              existing.erasesDistinctSurface && coversSameSurface(existing.box, candidate.box)
            }
          }
          line.replacementPatches.append(contentsOf: erasers)
        }
      }
      if line.isVerticalBlock, let surface = line.surface {
        line.replacementPatches = line.replacementPatches.map { patch in
          guard SourcePatchClipping.surface(for: patch, within: surface) != nil else { return patch }
          var patch = patch
          patch.appearance.background = line.appearance.background
          return patch
        }
      }
      if
        line.isVerticalBlock,
        line.verticalCharScale > 0,
        let styleRaster,
        let surface = line.surface
      {
        line.replacementPatches = line.replacementPatches.map { patch in
          guard SourcePatchClipping.surface(for: patch, within: surface) != nil else { return patch }
          return extendingVerticalPatch(
            patch,
            characterScale: line.verticalCharScale,
            inside: surface.box,
            raster: styleRaster
          )
        }
      }
      if let clippingBox {
        line.replacementPatches = line.replacementPatches.map { patch in
          var patch = patch
          patch.clippingBox = patch.clippingBox.map { $0.intersection(clippingBox) } ?? clippingBox
          return patch
        }
      }
      return line
    })
  }

  // MARK: Private

  private struct Bucket {
    var count = 0
    var red = 0
    var green = 0
    var blue = 0
  }

  private struct DominantSample {
    var color: OverlayColor
    var count: Int
    var total: Int

    var confidence: CGFloat {
      CGFloat(count) / CGFloat(max(1, total))
    }
  }

  private struct WeightedAppearance {
    var appearance: OverlaySourceAppearance
    var weight: CGFloat = 1
  }

  /// Shared immutable ownership avoids copying/refcounting both pixel arrays
  /// and the background index through every per-pixel sampling helper.
  private final class PixelRaster: Sendable {

    // MARK: Lifecycle

    init?(image: CGImage, longestSide targetLongestSide: Int) {
      let sourceLongestSide = max(image.width, image.height)
      guard sourceLongestSide > 0, targetLongestSide > 0 else { return nil }
      let scale = min(1, CGFloat(targetLongestSide) / CGFloat(sourceLongestSide))
      let width = max(1, Int((CGFloat(image.width) * scale).rounded()))
      let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
      let bytesPerRow = width * 4
      var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
      let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
      let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
        guard
          let address = bytes.baseAddress,
          let context = CGContext(
            data: address,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          )
        else { return false }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
      }
      guard rendered else { return nil }
      self.width = width
      self.height = height
      self.pixels = pixels
      columnLimits = nil
      usesOwnershipMask = false
      edgeBackground = targetLongestSide <= 384
        ? EdgeBackgroundIndex(pixels: pixels, width: width, height: height)
        : nil
    }

    init(raster: PixelRaster, ownership: OCRSpatialOwnership.SamplingRegion) {
      width = raster.width
      height = raster.height
      pixels = raster.pixels
      edgeBackground = raster.edgeBackground
      usesOwnershipMask = true
      // Shared immutable pixels are not copied. Resolve the slanted corridor
      // once per column; every later sample then needs only two integer checks.
      columnLimits = (0..<raster.width).map { x in
        guard let range = ownership.verticalRange(at: (CGFloat(x) + 0.5) / CGFloat(raster.width)) else {
          return (raster.height, -1)
        }
        return (
          max(0, Int(ceil(range.lowerBound * CGFloat(raster.height) - 0.5))),
          min(raster.height - 1, Int(floor(range.upperBound * CGFloat(raster.height) - 0.5)))
        )
      }
    }

    // MARK: Internal

    let width: Int
    let height: Int
    let pixels: [UInt8]
    let edgeBackground: EdgeBackgroundIndex?
    let usesOwnershipMask: Bool

    func owns(x: Int, y: Int) -> Bool {
      guard let columnLimits else { return true }
      guard columnLimits.indices.contains(x) else { return false }
      return y >= columnLimits[x].minimum && y <= columnLimits[x].maximum
    }

    func color(at index: Int) -> OverlayColor? {
      if usesOwnershipMask, !owns(x: index % width, y: index / width) { return nil }
      // Borrow once for all channels. Repeated Array property reads otherwise
      // contend on the shared storage's reference count in Debug captures.
      return pixels.withUnsafeBufferPointer { bytes in
        let offset = index * 4
        guard offset >= 0, offset + 3 < bytes.count, bytes[offset + 3] > 127 else { return nil }
        return OverlayColor(
          red: CGFloat(bytes[offset]) / 255,
          green: CGFloat(bytes[offset + 1]) / 255,
          blue: CGFloat(bytes[offset + 2]) / 255,
          alpha: 1
        )
      }
    }

    func matchesBackground(
      at index: Int,
      color: OverlayColor,
      tolerance: CGFloat
    ) -> Bool {
      guard let sample = self.color(at: index) else { return false }
      return sample.distance(to: color) <= tolerance
    }

    // MARK: Private

    private let columnLimits: [(minimum: Int, maximum: Int)]?

  }

  /// Vision sometimes assigns a raised link and its preceding word one box.
  /// A distinct chromatic component supplies exclusive ownership for the
  /// reference, including brackets that OCR flattened into the word's range.
  private static func completingChromaticReferences(_ result: OCRResult, raster: PixelRaster) -> OCRResult {
    .init(lines: result.lines.map { line in
      guard !line.isVerticalBlock, !line.preservesSource else { return line }
      let text = line.text as NSString
      var line = line
      let original = line.styleRuns
      line.styleRuns = original.map { run in
        let shared = original.filter { sameBox($0.box, run.box) }
        let range = shared.reduce(run.range) { NSUnionRange($0, $1.range) }
        guard NSMaxRange(range) <= text.length, let ink = run.inkBox, isChromatic(run.appearance.foreground) else { return run }
        let value = text.substring(with: range)
        guard
          OCRVisualStructure.isReferenceTranscript(value)
        else { return run }
        // A dropped bracket can lie just outside Vision's range box. Recover
        // only nearby ink of the same hue; adjacent body ink has no ownership
        // here. The completed marker is retained rather than translated.
        let pixels = pixelRect(for: ink, raster: raster)
        let margin = max(1, pixels.height * 0.3)
        let search = pixels.insetBy(dx: -margin, dy: -margin).integral
          .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        var complete = CGRect.null
        for y in Int(search.minY)..<Int(search.maxY) {
          for x in Int(search.minX)..<Int(search.maxX) {
            guard
              let color = raster.color(at: y * raster.width + x),
              color.distance(to: run.appearance.background) > 0.02,
              sameInkColor(.init(background: run.appearance.background, foreground: color, confidence: 1), run.appearance)
            else { continue }
            complete = complete.union(CGRect(x: x, y: y, width: 1, height: 1))
          }
        }
        guard !complete.isNull else { return run }
        var run = run
        run.inkBox = CGRect(
          x: complete.minX / CGFloat(raster.width),
          y: complete.minY / CGFloat(raster.height),
          width: complete.width / CGFloat(raster.width),
          height: complete.height / CGFloat(raster.height)
        )
        return run
      }
      return line
    })
  }

  private static func separatingChromaticReferences(
    _ line: OCRResult.Line,
    raster: PixelRaster,
    band: CGRect
  ) -> [OverlaySourceStyleRun] {
    let text = line.text as NSString
    return line.styleRuns.flatMap { run -> [OverlaySourceStyleRun] in
      let shared = line.styleRuns.filter { sameBox($0.box, run.box) }
      let range = shared.reduce(run.range) { NSUnionRange($0, $1.range) }
      guard NSMaxRange(range) <= text.length else { return [run] }
      let value = text.substring(with: range)
      guard
        value.contains(where: \.isLetter),
        let suffix = value.range(of: #"[\[(]?\d+(?:\.\d+)?[\])]$"#, options: .regularExpression)
      else { return [run] }
      let local = NSRange(suffix, in: value)
      let annotation = NSRange(location: range.location + local.location, length: local.length)
      let pixels = pixelRect(for: run.box, raster: raster).intersection(pixelRect(for: band, raster: raster)).integral
      let background = sampledSurroundingBackground(around: run.box, raster: raster) ?? line.appearance.background
      var colored = CGRect.null
      for y in Int(pixels.minY)..<Int(pixels.maxY) {
        for x in Int(pixels.minX)..<Int(pixels.maxX) {
          guard
            let color = raster.color(at: y * raster.width + x),
            isChromatic(color), color.distance(to: background) > 0.15
          else { continue }
          colored = colored.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
      guard
        !colored.isNull, colored.width <= pixels.width * 0.5,
        colored.width <= colored.height * 4,
        min(colored.minX - pixels.minX, pixels.maxX - colored.maxX) <= max(2, pixels.height * 0.3)
      else { return [run] }
      let markerOnRight = colored.midX > pixels.midX
      let body = CGRect(
        x: markerOnRight ? pixels.minX : colored.maxX,
        y: pixels.minY,
        width: markerOnRight ? colored.minX - pixels.minX : pixels.maxX - colored.maxX,
        height: pixels.height
      )
      let prefix = NSRange(location: range.location, length: annotation.location - range.location)
      return [(prefix, body), (annotation, colored.insetBy(dx: -0.5, dy: -0.5).intersection(pixels))]
        .compactMap { scope, bounds -> OverlaySourceStyleRun? in
          let intersection = NSIntersectionRange(run.range, scope)
          guard intersection.length > 0, bounds.width > 0, bounds.height > 0 else { return nil }
          var piece = run
          piece.range = intersection
          piece.box = CGRect(
            x: bounds.minX / CGFloat(raster.width),
            y: bounds.minY / CGFloat(raster.height),
            width: bounds.width / CGFloat(raster.width),
            height: bounds.height / CGFloat(raster.height)
          )
          piece.inkBox = nil
          return piece
        }
    }
  }

  private static func splitChromaticRuns(
    _ runs: [OverlaySourceStyleRun],
    anchors: [OCRTextAnchor],
    raster: PixelRaster,
    band: CGRect
  ) -> [OverlaySourceStyleRun] {
    runs.flatMap { run -> [OverlaySourceStyleRun] in
      let glyphs = anchors.filter { NSIntersectionRange($0.range, run.range).length == $0.range.length }
        .sorted { $0.range.location < $1.range.location }
      guard
        glyphs.count >= 2, glyphs.first?.range.location == run.range.location,
        glyphs.last.map({ NSMaxRange($0.range) }) == NSMaxRange(run.range),
        zip(glyphs, glyphs.dropFirst()).allSatisfy({ a, b in
          let intersection = a.box.intersection(b.box)
          return intersection.isNull || intersection.width * intersection.height
            < min(a.box.width * a.box.height, b.box.width * b.box.height) * 0.3
        })
      else { return [run] }
      var groups = [OverlaySourceStyleRun]()
      for glyph in glyphs {
        let sample = appearance(around: glyph.box, raster: raster, within: band)
        if
          let previous = groups.last,
          sameInkColor(previous.appearance, sample),
          previous.appearance.background.distance(to: sample.background) < 0.08
        {
          groups[groups.count - 1].range = NSUnionRange(previous.range, glyph.range)
          groups[groups.count - 1].box = previous.box.union(glyph.box)
        } else {
          groups.append(.init(range: glyph.range, box: glyph.box, appearance: sample))
        }
      }
      return groups.count > 1 ? groups : [run]
    }
  }

  private static func sameInkColor(_ a: OverlaySourceAppearance, _ b: OverlaySourceAppearance) -> Bool {
    let left = a.foreground
    let right = b.foreground
    let leftChroma = max(left.red, left.green, left.blue) - min(left.red, left.green, left.blue)
    let rightChroma = max(right.red, right.green, right.blue) - min(right.red, right.green, right.blue)
    // Thin neutral glyphs (i/l/punctuation) have lighter antialiasing, not a
    // different style. Compare chromatic ink after removing that opacity bias.
    if leftChroma < 0.12, rightChroma < 0.12 { return true }
    func direction(_ appearance: OverlaySourceAppearance) -> [CGFloat] {
      let delta = [
        appearance.background.red - appearance.foreground.red,
        appearance.background.green - appearance.foreground.green,
        appearance.background.blue - appearance.foreground.blue,
      ]
      let scale = max(0.01, delta.map { abs($0) }.max() ?? 0)
      return delta.map { $0 / scale }
    }
    return zip(direction(a), direction(b)).allSatisfy { abs($0 - $1) < 0.15 }
  }

  /// A continuous horizontal stroke that crosses the whole observation and
  /// extends well beyond it is a layout rule, not an ascender or underline.
  /// Require a blank gap above it; do not trim a glyph's own horizontal stroke.
  private static func horizontalRuleSamplingBand(
    around line: OCRResult.Line,
    background: OverlayColor,
    raster: PixelRaster
  ) -> CGRect {
    let canvas = CGRect(x: 0, y: 0, width: 1, height: 1)
    guard !line.isVerticalBlock, line.rowCount == 1, abs(line.rotationRadians) < 0.1 else { return canvas }
    let box = pixelRect(for: line.boundingBoxNormalized, raster: raster).integral
      .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
    guard box.width >= box.height * 3, box.height >= 8 else { return canvas }
    let left = Int(box.minX)
    let right = Int(box.maxX)
    let extensionWidth = max(12, Int(box.height * 2))
    func uniform(_ range: Range<Int>, y: Int, color: OverlayColor, threshold: CGFloat) -> Bool {
      guard
        !range.isEmpty, range.lowerBound >= 0, range.upperBound <= raster.width, y >= 0,
        y < raster.height
      else { return false }
      return range.count(where: { x in
        raster.color(at: y * raster.width + x).map { $0.distance(to: color) <= threshold } == true
      }) >= Int(ceil(Double(range.count) * 0.95))
    }
    for y in Int(box.minY + box.height * 0.6)..<Int(box.maxY) {
      guard
        let color = raster.color(at: y * raster.width + (left + right) / 2),
        color.distance(to: background) > 0.08,
        uniform(left..<right, y: y, color: color, threshold: 0.04),
        uniform(left..<right, y: y - 1, color: background, threshold: 0.04),
        uniform(left..<right, y: y - 2, color: background, threshold: 0.04),
        uniform(right..<right + extensionWidth, y: y, color: color, threshold: 0.04)
        || uniform(left - extensionWidth..<left, y: y, color: color, threshold: 0.04)
      else { continue }
      return CGRect(x: 0, y: 0, width: 1, height: CGFloat(y) / CGFloat(raster.height))
    }
    return canvas
  }

  private static func observedInkBox(
    _ box: CGRect,
    appearance: OverlaySourceAppearance,
    raster: PixelRaster,
    within band: CGRect
  ) -> CGRect? {
    let pixels = pixelRect(for: box, raster: raster).integral
      .intersection(pixelRect(for: band, raster: raster))
      .intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
    guard !pixels.isNull, !pixels.isEmpty else { return nil }
    let threshold = max(0.08, appearance.foreground.distance(to: appearance.background) * 0.4)
    var ink = CGRect.null
    for y in Int(pixels.minY)..<Int(pixels.maxY) {
      for x in Int(pixels.minX)..<Int(pixels.maxX) {
        if let color = raster.color(at: y * raster.width + x), color.distance(to: appearance.background) > threshold {
          ink = ink.union(CGRect(x: x, y: y, width: 1, height: 1))
        }
      }
    }
    guard !ink.isNull, ink.height >= 2 else { return nil }
    return CGRect(
      x: ink.minX / CGFloat(raster.width),
      y: ink.minY / CGFloat(raster.height),
      width: ink.width / CGFloat(raster.width),
      height: ink.height / CGFloat(raster.height)
    )
  }

  private static func physicalSurfaceAnchor(for line: OCRResult.Line) -> CGRect {
    guard line.isVerticalBlock, line.rowCount == 1, abs(line.rotationRadians) < 0.025 else {
      return line.boundingBoxNormalized
    }
    let mainRunBounds = line.styleRuns.reduce(CGRect.null) { $0.union($1.box) }
    if !mainRunBounds.isNull, coversVisibleSource(line.styleRuns, in: line.text) { return mainRunBounds }
    return line.orientedBox ?? line.boundingBoxNormalized
  }

  private static func extendingVerticalPatch(
    _ patch: OverlaySourcePatch,
    characterScale: CGFloat,
    inside normalizedSurface: CGRect,
    raster: PixelRaster
  ) -> OverlaySourcePatch {
    let source = pixelRect(for: patch.box, raster: raster).integral
    let surface = pixelRect(for: normalizedSurface, raster: raster).integral
    guard
      !source.isNull,
      !source.isEmpty,
      !surface.isNull,
      !surface.isEmpty
    else { return patch }

    let characterExtent = max(4, Int(ceil(characterScale * CGFloat(raster.width))))
    let inset = max(1, Int(source.width * 0.12))
    let minimumX = max(Int(surface.minX), Int(source.minX) + inset)
    let maximumX = min(Int(surface.maxX), Int(source.maxX) - inset)
    guard maximumX > minimumX else { return patch }

    let foregroundDistance = patch.appearance.background.distance(to: patch.appearance.foreground)
    let inkThreshold = max(0.18, foregroundDistance * 0.35)
    let minimumInkPerRow = max(2, Int(ceil(CGFloat(maximumX - minimumX) * 0.12)))
    let minimumRunLength = max(4, Int(ceil(CGFloat(characterExtent) * 0.22)))

    func qualifyingRuns(in range: Range<Int>) -> [Range<Int>] {
      var runs = [Range<Int>]()
      var runStart: Int?
      for y in range {
        let inkCount = (minimumX ..< maximumX).count { x in
          guard let color = raster.color(at: y * raster.width + x) else { return false }
          return color.distance(to: patch.appearance.background) >= inkThreshold
        }
        if inkCount >= minimumInkPerRow {
          runStart = runStart ?? y
        } else if let start = runStart {
          if y - start >= minimumRunLength { runs.append(start ..< y) }
          runStart = nil
        }
      }
      if let start = runStart, range.upperBound - start >= minimumRunLength {
        runs.append(start ..< range.upperBound)
      }
      return runs
    }

    let sourceMinimumY = max(Int(surface.minY), Int(source.minY))
    let sourceMaximumY = min(Int(surface.maxY), Int(source.maxY))
    let upperRange = max(Int(surface.minY), sourceMinimumY - characterExtent) ..< sourceMinimumY
    let lowerRange = sourceMaximumY ..< min(Int(surface.maxY), sourceMaximumY + characterExtent)
    let upperRun = qualifyingRuns(in: upperRange).last.flatMap { run in
      let startsAtSurfaceEdge = upperRange.lowerBound == Int(surface.minY)
        && run.lowerBound <= upperRange.lowerBound + 1
      return startsAtSurfaceEdge ? nil : run
    }
    let lowerRun = qualifyingRuns(in: lowerRange).first.flatMap { run in
      let endsAtSurfaceEdge = lowerRange.upperBound == Int(surface.maxY)
        && run.upperBound >= lowerRange.upperBound - 1
      return endsAtSurfaceEdge ? nil : run
    }
    guard upperRun != nil || lowerRun != nil else { return patch }

    let minimumY = CGFloat(upperRun?.lowerBound ?? Int(source.minY))
    let maximumY = CGFloat(lowerRun?.upperBound ?? Int(source.maxY))
    var result = patch
    result.box = CGRect(
      x: patch.box.minX,
      y: minimumY / CGFloat(raster.height),
      width: patch.box.width,
      height: (maximumY - minimumY) / CGFloat(raster.height)
    )
    return result
  }

  private static func nearbyChromaticRubyPatch(
    above patch: OverlaySourcePatch,
    raster: PixelRaster
  ) -> OverlaySourcePatch? {
    let source = pixelRect(for: patch.box, raster: raster).integral
    guard !source.isNull, !source.isEmpty else { return nil }

    let extensionHeight = max(3, min(24, Int(ceil(source.height * 0.45))))
    var minimumY = max(0, Int(source.minY) - extensionHeight)
    let sourceMinimumY = max(minimumY, Int(source.minY))
    let minimumX = max(0, Int(source.minX))
    let maximumX = min(raster.width, Int(source.maxX))
    guard minimumY < sourceMinimumY, minimumX < maximumX else { return nil }

    let background = patch.appearance.background
    let borderThreshold = max(4, Int(CGFloat(maximumX - minimumX) * 0.45))
    for y in minimumY ..< sourceMinimumY {
      var currentRun = 0
      var longestRun = 0
      for x in minimumX ..< maximumX {
        if
          let color = raster.color(at: y * raster.width + x),
          color.distance(to: background) >= 0.14
        {
          currentRun += 1
          longestRun = max(longestRun, currentRun)
        } else {
          currentRun = 0
        }
      }
      if longestRun >= borderThreshold {
        minimumY = min(sourceMinimumY, y + 1)
      }
    }

    let foreground = patch.appearance.foreground
    let red = foreground.red - background.red
    let green = foreground.green - background.green
    let blue = foreground.blue - background.blue
    let denominator = red * red + green * green + blue * blue
    guard denominator > 0.01 else { return nil }

    var inkMinimumX = Int.max
    var inkMaximumX = Int.min
    var inkMinimumY = Int.max
    var inkMaximumY = Int.min
    var inkCount = 0
    for y in minimumY ..< sourceMinimumY {
      for x in minimumX ..< maximumX {
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        let sampleRed = color.red - background.red
        let sampleGreen = color.green - background.green
        let sampleBlue = color.blue - background.blue
        let amount = (sampleRed * red + sampleGreen * green + sampleBlue * blue) / denominator
        guard amount >= 0.12, amount <= 1.35 else { continue }
        let expected = OverlayColor(
          red: background.red + red * amount,
          green: background.green + green * amount,
          blue: background.blue + blue * amount,
          alpha: 1
        )
        guard color.distance(to: expected) <= 0.08 else { continue }
        inkMinimumX = min(inkMinimumX, x)
        inkMaximumX = max(inkMaximumX, x)
        inkMinimumY = min(inkMinimumY, y)
        inkMaximumY = max(inkMaximumY, y)
        inkCount += 1
      }
    }
    guard inkCount >= 4, inkMaximumY - inkMinimumY + 1 >= 2 else { return nil }

    return OverlaySourcePatch(
      box: CGRect(
        x: CGFloat(inkMinimumX) / CGFloat(raster.width),
        y: CGFloat(inkMinimumY) / CGFloat(raster.height),
        width: CGFloat(inkMaximumX - inkMinimumX + 1) / CGFloat(raster.width),
        height: CGFloat(inkMaximumY - inkMinimumY + 1) / CGFloat(raster.height)
      ),
      appearance: patch.appearance
    )
  }

  private static func inferredSurface(
    containing normalizedSource: CGRect,
    appearance: OverlaySourceAppearance,
    raster: PixelRaster,
    limitingTo normalizedLimit: CGRect? = nil,
    minimumConfidence: CGFloat = 0.35,
    acceptedConfidenceFloor: CGFloat? = nil
  ) -> OverlaySourceSurface? {
    let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    let normalizedSource = normalizedSource.standardized.intersection(unit)
    guard !normalizedSource.isNull, !normalizedSource.isEmpty else { return nil }
    let rasterBounds = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
    let allowedBounds = normalizedLimit.map { normalizedLimit in
      CGRect(
        x: normalizedLimit.minX * CGFloat(raster.width),
        y: normalizedLimit.minY * CGFloat(raster.height),
        width: normalizedLimit.width * CGFloat(raster.width),
        height: normalizedLimit.height * CGFloat(raster.height)
      ).integral.intersection(rasterBounds)
    } ?? rasterBounds
    let source = CGRect(
      x: normalizedSource.minX * CGFloat(raster.width),
      y: normalizedSource.minY * CGFloat(raster.height),
      width: max(1, normalizedSource.width * CGFloat(raster.width)),
      height: max(1, normalizedSource.height * CGFloat(raster.height))
    ).integral.intersection(allowedBounds)
    guard !source.isNull, !source.isEmpty else { return nil }

    // Keep nearby dark surfaces distinct. A #1c1c1e card on a black page is
    // only ~0.11 apart in sRGB; the old adaptive 0.22 ceiling crossed its
    // border and flooded to the image edge, discarding the card surface.
    let tolerance = min(0.09, max(0.05, 0.05 + (1 - appearance.confidence) * 0.12))
    let search = source.insetBy(
      dx: -max(2, source.width * 0.2),
      dy: -max(2, source.height * 0.2)
    ).integral.intersection(allowedBounds)
    var seed: Int?
    var seedScore = -CGFloat.infinity
    let center = CGPoint(x: source.midX, y: source.midY)
    // Nine matching neighbors is the maximum possible score. A nearest such
    // seed within four pixels always beats every lower-degree candidate and
    // every farther seed, so most flat text rows need only a tiny local search.
    let local = CGRect(x: center.x - 4, y: center.y - 4, width: 9, height: 9).integral.intersection(search)
    for y in Int(local.minY) ..< Int(local.maxY) {
      for x in Int(local.minX) ..< Int(local.maxX) {
        guard x > 0, y > 0, x + 1 < raster.width, y + 1 < raster.height else { continue }
        let distance = hypot(CGFloat(x) - center.x, CGFloat(y) - center.y)
        guard distance <= 4 else { continue }
        let fullySurrounded = (y - 1 ... y + 1).allSatisfy { row in
          (x - 1 ... x + 1).allSatisfy { column in
            raster.matchesBackground(at: row * raster.width + column, color: appearance.background, tolerance: tolerance)
          }
        }
        let score = 900 - distance
        if fullySurrounded, score > seedScore { seed = y * raster.width + x
          seedScore = score
        }
      }
    }
    if seed == nil {
      for y in Int(search.minY) ..< Int(search.maxY) {
        for x in Int(search.minX) ..< Int(search.maxX) {
          let index = y * raster.width + x
          guard raster.matchesBackground(at: index, color: appearance.background, tolerance: tolerance) else {
            continue
          }
          var matchingNeighbors = 0
          for neighborY in max(0, y - 1) ... min(raster.height - 1, y + 1) {
            for neighborX in max(0, x - 1) ... min(raster.width - 1, x + 1) {
              let neighbor = neighborY * raster.width + neighborX
              if raster.matchesBackground(at: neighbor, color: appearance.background, tolerance: tolerance) {
                matchingNeighbors += 1
              }
            }
          }
          let distance = hypot(CGFloat(x) - center.x, CGFloat(y) - center.y)
          let score = CGFloat(matchingNeighbors) * 100 - distance
          if score > seedScore {
            seed = index
            seedScore = score
          }
        }
      }
    }
    guard let seed else { return nil }
    if
      allowedBounds == rasterBounds, let background = raster.edgeBackground,
      background.connected[seed], background.color.distance(to: appearance.background) <= tolerance
    {
      return nil
    }

    let localWidth = Int(allowedBounds.width)
    func localIndex(_ index: Int) -> Int {
      (index / raster.width - Int(allowedBounds.minY)) * localWidth + index % raster.width - Int(allowedBounds.minX)
    }
    var visited = [Bool](repeating: false, count: localWidth * Int(allowedBounds.height))
    var queue = [seed]
    visited[localIndex(seed)] = true
    var cursor = 0
    var minimumX = raster.width
    var minimumY = raster.height
    var maximumX = 0
    var maximumY = 0
    var rowMinimumX = [Int](repeating: raster.width, count: raster.height)
    var rowMaximumX = [Int](repeating: -1, count: raster.height)
    while cursor < queue.count {
      let index = queue[cursor]
      cursor += 1
      let x = index % raster.width
      let y = index / raster.width
      // Components that reach the capture edge represent the page/background,
      // not a local text surface. Return as soon as that outcome is known
      // instead of traversing the full page.
      if x == 0 || y == 0 || x == raster.width - 1 || y == raster.height - 1 {
        return nil
      }
      if
        x == Int(allowedBounds.minX) || y == Int(allowedBounds.minY)
        || x == Int(allowedBounds.maxX) - 1 || y == Int(allowedBounds.maxY) - 1 { return nil }
      minimumX = min(minimumX, x)
      minimumY = min(minimumY, y)
      maximumX = max(maximumX, x)
      maximumY = max(maximumY, y)
      rowMinimumX[y] = min(rowMinimumX[y], x)
      rowMaximumX[y] = max(rowMaximumX[y], x)
      let neighbors = [
        x > 0 ? index - 1 : -1,
        x + 1 < raster.width ? index + 1 : -1,
        y > 0 ? index - raster.width : -1,
        y + 1 < raster.height ? index + raster.width : -1,
      ]
      for neighbor in neighbors where neighbor >= 0 {
        let neighborX = neighbor % raster.width
        let neighborY = neighbor / raster.width
        guard
          allowedBounds.contains(CGPoint(
            x: CGFloat(neighborX) + 0.5,
            y: CGFloat(neighborY) + 0.5
          ))
        else { continue }
        let local = localIndex(neighbor)
        guard !visited[local] else { continue }
        visited[local] = true
        guard
          raster.matchesBackground(
            at: neighbor,
            color: appearance.background,
            tolerance: tolerance
          )
        else {
          continue
        }
        queue.append(neighbor)
      }
    }

    let component = CGRect(
      x: minimumX,
      y: minimumY,
      width: maximumX - minimumX + 1,
      height: maximumY - minimumY + 1
    )
    // A page or screenshot enclosed by a border is a flat closed component too,
    // but it is not a semantic text container. Treating it as one made the
    // entire document look like a single speech bubble.
    let componentWidthRatio = component.width / CGFloat(raster.width)
    let componentHeightRatio = component.height / CGFloat(raster.height)
    guard componentWidthRatio < 0.9 || componentHeightRatio < 0.9 else { return nil }
    let fillRatio = CGFloat(queue.count) / max(1, component.width * component.height)
    let expansion = component.width * component.height / max(1, source.width * source.height)
    guard fillRatio >= 0.45, expansion >= 1.15 else { return nil }

    let safe = component.insetBy(
      dx: max(1, component.width * 0.07),
      dy: max(1, component.height * 0.05)
    )
    guard safe.width > 1, safe.height > 1 else { return nil }
    let confidence = min(
      1,
      appearance.confidence
        * min(1, fillRatio / 0.65)
        * min(1, 0.65 + (expansion - 1) * 0.2)
    )
    guard confidence >= minimumConfidence else { return nil }
    let cornerRadiusFraction = inferredCornerRadiusFraction(
      minimumY: minimumY,
      maximumY: maximumY,
      rowMinimumX: rowMinimumX,
      rowMaximumX: rowMaximumX
    )
    return OverlaySourceSurface(
      box: CGRect(
        x: safe.minX / CGFloat(raster.width),
        y: safe.minY / CGFloat(raster.height),
        width: safe.width / CGFloat(raster.width),
        height: safe.height / CGFloat(raster.height)
      ),
      // A high-resolution retry is made only for a compact fill already known
      // to contrast with its surroundings. Promote that accepted geometry to
      // the renderer's ordinary confidence floor instead of detecting it and
      // then discarding it one stage later.
      confidence: max(confidence, acceptedConfidenceFloor ?? confidence),
      clippingBox: CGRect(
        x: component.minX / CGFloat(raster.width),
        y: component.minY / CGFloat(raster.height),
        width: component.width / CGFloat(raster.width),
        height: component.height / CGFloat(raster.height)
      ),
      cornerRadiusFraction: cornerRadiusFraction
    )
  }

  private static func inferredCornerRadiusFraction(
    minimumY: Int,
    maximumY: Int,
    rowMinimumX: [Int],
    rowMaximumX: [Int]
  ) -> CGFloat {
    guard maximumY >= minimumY else { return 0 }
    let rowWidths = (minimumY ... maximumY).map { y in
      max(0, rowMaximumX[y] - rowMinimumX[y] + 1)
    }
    guard let maximumWidth = rowWidths.max(), maximumWidth > 0 else { return 0 }
    let edgeBandSize = max(1, Int(ceil(CGFloat(rowWidths.count) * 0.08)))
    let edgeWidths = Array(rowWidths.prefix(edgeBandSize))
      + Array(rowWidths.suffix(edgeBandSize))
    let edgeWidthRatio = CGFloat(edgeWidths.reduce(0, +))
      / CGFloat(max(1, edgeWidths.count * maximumWidth))
    return edgeWidthRatio < 0.78 ? 0.35 : 0
  }

  private static func appearance(
    around normalizedBox: CGRect,
    raster: PixelRaster,
    text: String? = nil,
    within samplingBand: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
  ) -> OverlaySourceAppearance {
    let rasterBounds = pixelRect(for: samplingBand, raster: raster)
    let source = pixelRect(for: normalizedBox, raster: raster).intersection(rasterBounds)
    guard !source.isNull, !source.isEmpty else { return .fallback }
    // Include the glyph box itself and only a narrow local ring. The dominant
    // color inside a word box is still its background, while a width-relative
    // ring escapes long inline-code pills and incorrectly samples the table or
    // page beneath them.
    let sampleBounds = source.insetBy(
      dx: -max(2, min(source.width * 0.12, source.height * 0.5)),
      dy: -max(2, source.height * 0.35)
    ).integral.intersection(rasterBounds)

    let interior = dominantSample(in: source, excluding: nil, raster: raster)
    let exterior = dominantSample(in: sampleBounds, excluding: source, raster: raster)
    let dominant: DominantSample
    var hasHighContrastSurface = false
    switch (interior, exterior) {
    case (.some(let interior), .some(let exterior)):
      // Text glyphs are usually much farther from their surface than adjacent
      // UI surfaces are from one another. A moderately different, dominant
      // interior color is therefore an inline-code/control fill; a high-contrast
      // interior cluster is glyph ink unless it forms a continuous edge band,
      // which identifies a high-contrast pill or button fill.
      let interiorDistance = interior.color.distance(to: exterior.color)
      let innerEdgeCoverage = edgeMatchRatio(
        color: interior.color,
        in: source,
        raster: raster
      )
      let outerEdgeCoverage = edgeMatchRatio(
        color: interior.color,
        in: source.insetBy(dx: -2, dy: -2).intersection(rasterBounds),
        raster: raster
      )
      let interiorFormsSurface = innerEdgeCoverage >= 0.95
        || (innerEdgeCoverage >= 0.55 && outerEdgeCoverage >= 0.55)
        || hasOpposingBackgroundEdges(
          color: interior.color,
          in: source.insetBy(dx: -2, dy: -2).intersection(rasterBounds),
          raster: raster
        )
      hasHighContrastSurface = interiorDistance > 0.25 && interiorFormsSurface
      dominant = interior.confidence >= 0.32
        && (interiorDistance <= 0.25 || interiorFormsSurface)
        ? interior
        : exterior

    case (.some(let interior), .none):
      dominant = interior

    case (.none, .some(let exterior)):
      dominant = exterior

    case (.none, .none):
      return .fallback
    }
    let background = dominant.color
    var maximumDistance: CGFloat = 0
    var sourceSampleCount = 0
    for y in Int(source.minY) ..< Int(source.maxY) {
      for x in Int(source.minX) ..< Int(source.maxX) {
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        maximumDistance = max(maximumDistance, color.distance(to: background))
        sourceSampleCount += 1
      }
    }
    let foregroundThreshold = max(0.08, maximumDistance * 0.94)
    let inkThreshold = max(0.06, maximumDistance * 0.35)
    var foregroundRed: CGFloat = 0
    var foregroundGreen: CGFloat = 0
    var foregroundBlue: CGFloat = 0
    var foregroundSampleCount = 0
    var foregroundBuckets = [Int: Bucket]()
    var foregroundMinimumY = Int.max
    var foregroundMaximumY = Int.min
    var inkSampleCount = 0
    var inkMinimumX = Int.max
    var inkMaximumX = Int.min
    var inkMinimumY = Int.max
    var inkMaximumY = Int.min
    var integratedInk: CGFloat = 0
    var inkColumns = [CGFloat](repeating: 0, count: text == nil ? 0 : Int(source.width))
    let measuresSlant = text.map {
      SourceTypographySlant.canMeasure(text: $0, width: Int(source.width), height: Int(source.height))
    } == true
    var slantInk = [CGFloat](repeating: 0, count: measuresSlant ? Int(source.width * source.height) : 0)
    for y in Int(source.minY) ..< Int(source.maxY) {
      for x in Int(source.minX) ..< Int(source.maxX) {
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        let distance = color.distance(to: background)
        if distance >= max(0.08, maximumDistance * 0.65) {
          let red = Int((color.red * 255).rounded())
          let green = Int((color.green * 255).rounded())
          let blue = Int((color.blue * 255).rounded())
          let key = (red / 16) * 256 + (green / 16) * 16 + blue / 16
          var bucket = foregroundBuckets[key, default: Bucket()]
          bucket.count += 1
          bucket.red += red
          bucket.green += green
          bucket.blue += blue
          foregroundBuckets[key] = bucket
        }
        if distance >= foregroundThreshold {
          foregroundRed += color.red
          foregroundGreen += color.green
          foregroundBlue += color.blue
          foregroundSampleCount += 1
          foregroundMinimumY = min(foregroundMinimumY, y)
          foregroundMaximumY = max(foregroundMaximumY, y)
        }
        if distance >= inkThreshold {
          inkSampleCount += 1
          inkMinimumX = min(inkMinimumX, x)
          inkMaximumX = max(inkMaximumX, x)
          inkMinimumY = min(inkMinimumY, y)
          inkMaximumY = max(inkMaximumY, y)
        }
        if !inkColumns.isEmpty {
          inkColumns[x - Int(source.minX)] = max(inkColumns[x - Int(source.minX)], distance)
        }
        let strength = min(1, distance / max(0.001, maximumDistance))
        integratedInk += strength
        if measuresSlant {
          slantInk[(y - Int(source.minY)) * Int(source.width) + x - Int(source.minX)] = strength
        }
      }
    }
    // An isolated darker bracket must not choose the ink color of a blue
    // link. The modal strong-ink cluster represents the observed glyph style;
    // the darkest pixel alone only measures contrast, not semantic ownership.
    func bucketColor(_ bucket: Bucket) -> OverlayColor {
      .init(
        red: CGFloat(bucket.red) / CGFloat(bucket.count * 255),
        green: CGFloat(bucket.green) / CGFloat(bucket.count * 255),
        blue: CGFloat(bucket.blue) / CGFloat(bucket.count * 255),
        alpha: 1
      )
    }
    func sameFamily(_ a: Bucket, _ b: Bucket) -> Bool {
      sameInkColor(
        .init(background: background, foreground: bucketColor(a), confidence: 1),
        .init(background: background, foreground: bucketColor(b), confidence: 1)
      )
    }
    // Antialiasing disperses one hue across RGB buckets. Count its family
    // before choosing a mode so a few solid black brackets cannot win by
    // occupying one undispersed bucket.
    let mode = foregroundBuckets.values.sorted { $0.count > $1.count }.prefix(8)
      .map { candidate in
        (bucket: candidate, count: foregroundBuckets.values.filter { sameFamily($0, candidate) }.reduce(0) { $0 + $1.count })
      }.max(by: { $0.count < $1.count })?.bucket
    let family = mode.map { mode in
      foregroundBuckets.values.filter {
        sameInkColor(
          .init(background: background, foreground: bucketColor($0), confidence: 1),
          .init(background: background, foreground: bucketColor(mode), confidence: 1)
        )
      }
    } ?? []
    let familyContrast = family.map { bucketColor($0).distance(to: background) }.max() ?? 0
    let dominantForeground = family.filter { bucketColor($0).distance(to: background) >= familyContrast * 0.94 }
      .reduce(Bucket()) { sum, item in
        Bucket(
          count: sum.count + item.count,
          red: sum.red + item.red,
          green: sum.green + item.green,
          blue: sum.blue + item.blue
        )
      }
    let foreground: OverlayColor =
      if dominantForeground.count > 0 {
        OverlayColor(
          red: CGFloat(dominantForeground.red) / CGFloat(dominantForeground.count * 255),
          green: CGFloat(dominantForeground.green) / CGFloat(dominantForeground.count * 255),
          blue: CGFloat(dominantForeground.blue) / CGFloat(dominantForeground.count * 255),
          alpha: 1
        )
      } else if foregroundSampleCount > 0 {
        OverlayColor(
          red: foregroundRed / CGFloat(foregroundSampleCount),
          green: foregroundGreen / CGFloat(foregroundSampleCount),
          blue: foregroundBlue / CGFloat(foregroundSampleCount),
          alpha: 1
        )
      } else {
        relativeLuminance(background) >= 0.179 ? .black : .white
      }
    let inkCoverage = CGFloat(inkSampleCount) / CGFloat(max(1, sourceSampleCount))
    let inkHeightScale = foregroundSampleCount > 0
      ? CGFloat(foregroundMaximumY - foregroundMinimumY + 1) / CGFloat(raster.height)
      : 0
    let foregroundConfidence = min(
      1,
      maximumDistance * min(1, CGFloat(foregroundSampleCount) / CGFloat(max(1, sourceSampleCount)) * 10)
    )
    let underlineThreshold = max(2, Int(source.width * 0.58))
    let underlineStart = Int(source.minY + source.height * 0.68)
    let underlineScan = CGRect(
      x: source.minX,
      y: CGFloat(underlineStart),
      width: source.width,
      height: source.maxY - CGFloat(underlineStart)
        + (hasHighContrastSurface ? 0 : max(2, source.height * 0.15))
    ).integral.intersection(rasterBounds)
    let underlineInkThreshold = max(0.08, maximumDistance * 0.7)
    var underlineRuns = [Int: Int]()
    for y in Int(underlineScan.minY) ..< Int(underlineScan.maxY) {
      var currentRun = 0
      var longestRun = 0
      for x in Int(underlineScan.minX) ..< Int(underlineScan.maxX) {
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        if color.distance(to: background) >= underlineInkThreshold {
          currentRun += 1
          longestRun = max(longestRun, currentRun)
        } else {
          currentRun = 0
        }
      }
      underlineRuns[y] = longestRun
    }
    let canContainUnderline = source.width >= max(8, source.height * 1.4)
    let isUnderlined = canContainUnderline && underlineRuns.contains { y, longestRun in
      y >= underlineStart && longestRun >= underlineThreshold
    }
    let inkWidth = inkSampleCount > 0 ? inkMaximumX - inkMinimumX + 1 : 0
    let inkHeight = inkSampleCount > 0 ? inkMaximumY - inkMinimumY + 1 : 0
    let typography = text.flatMap {
      SourceTypography.measure(
        text: $0,
        inkSize: CGSize(width: inkWidth, height: inkHeight),
        coverage: integratedInk / CGFloat(max(1, inkWidth * inkHeight))
      )
    }
    let isItalic = measuresSlant && inkWidth > 0 && inkHeight > 0 && SourceTypographySlant.isItalic(
      text: text!,
      ink: (inkMinimumY...inkMaximumY).flatMap { y in
        (inkMinimumX...inkMaximumX).map { x in
          slantInk[(y - Int(source.minY)) * Int(source.width) + x - Int(source.minX)]
        }
      },
      width: inkWidth,
      height: inkHeight
    )
    return OverlaySourceAppearance(
      background: background,
      foreground: foreground,
      confidence: min(1, dominant.confidence),
      foregroundConfidence: foregroundConfidence,
      inkCoverage: inkCoverage,
      inkHeightScale: inkHeightScale,
      fontSizeScale: (typography?.pointSize ?? 0) / CGFloat(raster.height),
      fontWeight: typography?.weight ?? fontWeight(for: inkCoverage, source: source, raster: raster),
      fontDesign: text.map { SourceTypography.isMonospaced(text: $0, inkColumns: inkColumns) } == true ? .monospaced : .standard,
      isItalic: isItalic,
      isUnderlined: isUnderlined
    )
  }

  private static func combinedAppearance(
    _ samples: [WeightedAppearance],
    fallback: OverlaySourceAppearance
  ) -> OverlaySourceAppearance {
    let samples = samples.filter { $0.appearance.confidence > 0 && $0.weight > 0 }
    guard !samples.isEmpty else { return fallback }
    var clusters = [[WeightedAppearance]]()
    for sample in samples {
      if
        let index = clusters.firstIndex(where: { cluster in
          guard let representative = cluster.first?.appearance else { return false }
          let appearance = sample.appearance
          return representative.background.distance(to: appearance.background) <= 0.045
            && representative.foreground.distance(to: appearance.foreground) <= 0.12
            && representative.fontDesign == appearance.fontDesign
            && abs(representative.fontWeight.rawValue - appearance.fontWeight.rawValue) <= 1
        })
      {
        clusters[index].append(sample)
      } else {
        clusters.append([sample])
      }
    }
    let dominant = clusters.max { lhs, rhs in
      clusterWeight(lhs) < clusterWeight(rhs)
    } ?? samples
    let totalSemanticWeight = dominant.reduce(0) { $0 + $1.weight }
    let backgroundWeight = dominant.reduce(0) {
      $0 + $1.weight * max(0.01, $1.appearance.confidence)
    }
    let foregroundWeight = dominant.reduce(0) {
      $0 + $1.weight * max(0.01, $1.appearance.foregroundConfidence)
    }
    let background = weightedColor(dominant, totalWeight: backgroundWeight) {
      ($0.appearance.background, $0.weight * max(0.01, $0.appearance.confidence))
    }
    let foreground = weightedColor(dominant, totalWeight: foregroundWeight) {
      ($0.appearance.foreground, $0.weight * max(0.01, $0.appearance.foregroundConfidence))
    }
    let coverage = dominant.reduce(0) {
      $0 + $1.appearance.inkCoverage * $1.weight
    } / max(1, totalSemanticWeight)
    let inkHeight = weightedInkHeight(dominant)
    let fontSamples = samples.filter { $0.appearance.fontSizeScale > 0 }.sorted {
      $0.appearance.fontSizeScale < $1.appearance.fontSizeScale
    }
    // A large marker or a small footnote owns only its characters. Giving
    // every span one vote makes tokenization determine the paragraph's size.
    let midpoint = fontSamples.reduce(0) { $0 + $1.weight } / 2
    var cumulative: CGFloat = 0
    let fontSize = fontSamples.first { sample in
      cumulative += sample.weight
      return cumulative >= midpoint
    }?.appearance.fontSizeScale ?? 0
    return OverlaySourceAppearance(
      background: background,
      foreground: foreground,
      confidence: min(1, dominant.reduce(0) {
        $0 + $1.appearance.confidence * $1.weight
      } / max(1, totalSemanticWeight)),
      foregroundConfidence: min(
        1,
        dominant.reduce(0) {
          $0 + $1.appearance.foregroundConfidence * $1.weight
        } / max(1, totalSemanticWeight)
      ),
      inkCoverage: coverage,
      inkHeightScale: inkHeight,
      fontSizeScale: fontSize,
      fontWeight: combinedFontWeight(dominant),
      fontDesign: dominant.filter { $0.appearance.fontDesign == .monospaced }.reduce(0) {
        $0 + $1.weight
      } * 2 >= totalSemanticWeight
        ? .monospaced
        : .standard,
      isItalic: dominant.filter { $0.appearance.isItalic }.reduce(0) { $0 + $1.weight } * 2 >= totalSemanticWeight,
      isUnderlined: dominant.filter { $0.appearance.isUnderlined }.reduce(0) {
        $0 + $1.weight
      } * 2 >= totalSemanticWeight
    )
  }

  private static func dominantSample(
    in bounds: CGRect,
    excluding excluded: CGRect?,
    raster: PixelRaster
  ) -> DominantSample? {
    // Samples are quantized to four bits per RGB channel below, so every key
    // is in a fixed 16³ space. Direct indexing avoids allocating and hashing a
    // fresh Dictionary for every line, word, and restoration patch.
    var buckets = [Bucket](repeating: Bucket(), count: 4_096)
    var occupiedKeys = [Int]()
    var total = 0
    let usesOwnershipMask = raster.usesOwnershipMask
    raster.pixels.withUnsafeBufferPointer { pixels in
      for y in Int(bounds.minY) ..< Int(bounds.maxY) {
        for x in Int(bounds.minX) ..< Int(bounds.maxX) {
          let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
          if excluded?.contains(point) == true { continue }
          if usesOwnershipMask, !raster.owns(x: x, y: y) { continue }
          let offset = (y * raster.width + x) * 4
          guard offset >= 0, offset + 3 < pixels.count, pixels[offset + 3] > 127 else { continue }
          let red = Int(pixels[offset])
          let green = Int(pixels[offset + 1])
          let blue = Int(pixels[offset + 2])
          let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
          if buckets[key].count == 0 {
            occupiedKeys.append(key)
          }
          buckets[key].count += 1
          buckets[key].red += red
          buckets[key].green += green
          buckets[key].blue += blue
          total += 1
        }
      }
    }
    guard total > 0 else { return nil }
    // Quantization is an index, not evidence of distinct physical surfaces.
    // JPEG noise and gradients split one fill across adjacent color buckets.
    // Compare a bounded set of likely centers so one unsplit glyph-color
    // bucket cannot beat a surface dispersed across several nearby buckets.
    func neighborhoodCount(around dominant: Bucket) -> Int {
      occupiedKeys.reduce(0) { count, key in
        let sample = buckets[key]
        let divisor = max(1, sample.count)
        let distance = max(
          abs(sample.red / divisor - dominant.red / dominant.count),
          abs(sample.green / divisor - dominant.green / dominant.count),
          abs(sample.blue / divisor - dominant.blue / dominant.count)
        )
        return count + (distance <= 20 ? sample.count : 0)
      }
    }
    let candidates = occupiedKeys.sorted { buckets[$0].count > buckets[$1].count }.prefix(8)
    guard
      let selected = candidates.map({ key in
        (bucket: buckets[key], count: neighborhoodCount(around: buckets[key]))
      }).max(by: { $0.count < $1.count })
    else { return nil }
    // Use the modal color within the winning neighborhood, not a sparse
    // antialiasing bucket whose wider reach merely collected more samples.
    // Otherwise a flat dark surface drifts toward gray and inflates measured
    // glyph coverage/font weight.
    let center = selected.bucket
    let neighborhood = occupiedKeys.map { buckets[$0] }.filter { sample in
      max(
        abs(sample.red / sample.count - center.red / center.count),
        abs(sample.green / sample.count - center.green / center.count),
        abs(sample.blue / sample.count - center.blue / center.count)
      ) <= 20
    }
    let mode = neighborhood.max(by: { $0.count < $1.count }) ?? center
    // A coherent flat fill has one majority bucket. A gradient has no such
    // mode; use its neighborhood mean so later connected-surface inference
    // can follow both sides of the gradient rather than only its light end.
    let dominant = mode.count * 2 >= selected.count
      ? mode
      : neighborhood.reduce(Bucket()) { sum, item in
        Bucket(count: sum.count + item.count, red: sum.red + item.red, green: sum.green + item.green, blue: sum.blue + item.blue)
      }
    let divisor = CGFloat(dominant.count * 255)
    return DominantSample(
      color: OverlayColor(
        red: CGFloat(dominant.red) / divisor,
        green: CGFloat(dominant.green) / divisor,
        blue: CGFloat(dominant.blue) / divisor,
        alpha: 1
      ),
      count: selected.count,
      total: total
    )
  }

  /// A speech balloon can meet artwork above and below the text while its
  /// actual background continues on both sides. Conversely dense glyphs have
  /// no such continuation outside their tight OCR box. Require evidence on
  /// opposing edges rather than taking the color of unrelated nearby artwork.
  private static func hasOpposingBackgroundEdges(
    color: OverlayColor,
    in bounds: CGRect,
    raster: PixelRaster
  ) -> Bool {
    guard bounds.width >= 3, bounds.height >= 3 else { return false }
    let x0 = Int(bounds.minX)
    let x1 = Int(bounds.maxX) - 1
    let y0 = Int(bounds.minY)
    let y1 = Int(bounds.maxY) - 1
    func matches(_ x: Int, _ y: Int) -> Bool {
      raster.color(at: y * raster.width + x).map { $0.distance(to: color) <= 0.12 } ?? false
    }
    let horizontal = CGFloat(max(1, x1 - x0 + 1))
    let vertical = CGFloat(max(1, y1 - y0 + 1))
    let top = CGFloat((x0...x1).count { matches($0, y0) }) / horizontal
    let bottom = CGFloat((x0...x1).count { matches($0, y1) }) / horizontal
    let left = CGFloat((y0...y1).count { matches(x0, $0) }) / vertical
    let right = CGFloat((y0...y1).count { matches(x1, $0) }) / vertical
    return min(top, bottom) >= 0.25 || min(left, right) >= 0.25
  }

  private static func edgeMatchRatio(
    color: OverlayColor,
    in bounds: CGRect,
    raster: PixelRaster
  ) -> CGFloat {
    let band = max(1, min(3, Int(min(bounds.width, bounds.height) * 0.15)))
    var matching = 0
    var total = 0
    for y in Int(bounds.minY) ..< Int(bounds.maxY) {
      for x in Int(bounds.minX) ..< Int(bounds.maxX) {
        let onEdge = x < Int(bounds.minX) + band
          || x >= Int(bounds.maxX) - band
          || y < Int(bounds.minY) + band
          || y >= Int(bounds.maxY) - band
        guard onEdge, let sample = raster.color(at: y * raster.width + x) else { continue }
        total += 1
        if sample.distance(to: color) <= 0.08 { matching += 1 }
      }
    }
    return CGFloat(matching) / CGFloat(max(1, total))
  }

  private static func clusterWeight(_ samples: [WeightedAppearance]) -> CGFloat {
    samples.reduce(0) {
      $0 + $1.weight * (1 + $1.appearance.confidence + $1.appearance.foregroundConfidence)
    }
  }

  private static func fontDesign(
    for text: String,
    appearance: OverlaySourceAppearance,
    surroundingBackground: OverlayColor
  ) -> OverlayFontDesign {
    // Punctuation at the edge of a control is not evidence of a code font.
    // Whole code-only rows are already protected before appearance analysis.
    guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return .standard }
    if appearance.fontDesign == .monospaced || OCRTextSemantics.isCode(text) { return .monospaced }
    // Footnotes and bracketed edit links do not turn surrounding prose into
    // code. Syntax heuristics apply only to compact literals, never a paragraph.
    guard text.split(whereSeparator: \.isWhitespace).count <= 1 else { return .standard }
    let strongCodePunctuation = CharacterSet(charactersIn: "_`{}<>\\=")
    if
      text.count > 1 && text.hasPrefix(".")
      || text.unicodeScalars.contains(where: strongCodePunctuation.contains)
    {
      return .monospaced
    }
    let sitsOnDistinctSurface = appearance.background.distance(to: surroundingBackground) >= 0.025
    guard sitsOnDistinctSurface else { return .standard }
    let codePunctuation = CharacterSet(charactersIn: "/:*")
    return text.unicodeScalars.contains(where: codePunctuation.contains) || OCRTextSemantics.isIndexedIdentifier(text)
      ? .monospaced
      : .standard
  }

  private static func sampledSurroundingBackground(
    around normalizedBox: CGRect,
    raster: PixelRaster
  ) -> OverlayColor? {
    let source = pixelRect(for: normalizedBox, raster: raster)
    guard !source.isNull, !source.isEmpty else { return nil }
    let bounds = source.insetBy(
      dx: -max(4, source.height * 1.2),
      dy: -max(4, source.height)
    ).integral.intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
    return dominantSample(in: bounds, excluding: source, raster: raster)?.color
  }

  private static func compactSurfaceAppearance(
    for source: CGRect,
    inside surface: OverlaySourceSurface,
    original: OverlaySourceAppearance,
    surroundingBackground: OverlayColor,
    raster: PixelRaster
  ) -> OverlaySourceAppearance? {
    let sampleBox = source.standardized.intersection(surface.box.standardized)
    guard !sampleBox.isNull, !sampleBox.isEmpty else { return nil }
    var refined = appearance(around: sampleBox, raster: raster)
    guard refined.background.distance(to: original.background) <= 0.08 else { return nil }

    // A tight OCR box can protrude by a pixel beyond a rounded chip. The
    // parent's high-contrast color then wins the "farthest pixel" vote and is
    // mistaken for both glyph ink and font height. Sampling within the detected
    // interior removes that border contamination while retaining actual ink.
    let originalMatchesParent = original.foreground.distance(to: surroundingBackground) <= 0.12
    let hasBetterInkEvidence = refined.foregroundConfidence
      >= max(0.04, original.foregroundConfidence * 1.2)
    guard originalMatchesParent || hasBetterInkEvidence else { return nil }
    refined.fontDesign = original.fontDesign
    refined.isItalic = original.isItalic
    return refined
  }

  private static func isCompactTextSurface(
    _ surface: OverlaySourceSurface,
    around normalizedSource: CGRect
  ) -> Bool {
    let surface = (surface.clippingBox ?? surface.box).standardized
    let source = normalizedSource.standardized
    guard !surface.isEmpty, !source.isEmpty else { return false }
    let intersection = surface.intersection(source)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    let sourceArea = max(0.000_001, source.width * source.height)
    let surfaceArea = surface.width * surface.height
    let coveredSource = intersection.width * intersection.height / sourceArea
    return coveredSource >= 0.75
      && surfaceArea / sourceArea <= 8
      && surface.width <= source.width * 2.2
      && surface.height <= source.height * 3
  }

  private static func applyingCompactTextInsets(
    to surface: OverlaySourceSurface
  ) -> OverlaySourceSurface {
    guard let clippingBox = surface.clippingBox?.standardized else { return surface }
    guard clippingBox.width / max(0.000_001, clippingBox.height) >= 2.2 else { return surface }
    let verticalInset = clippingBox.height * 0.15
    let insetBox = CGRect(
      x: surface.box.minX,
      y: clippingBox.minY + verticalInset,
      width: surface.box.width,
      height: clippingBox.height - verticalInset * 2
    )
    guard !insetBox.isEmpty else { return surface }
    var surface = surface
    surface.box = insetBox
    return surface
  }

  private static func isCompactInlineSurface(_ surface: CGRect, around source: CGRect) -> Bool {
    let surface = surface.standardized
    let source = source.standardized
    guard !surface.isEmpty, !source.isEmpty, surface.contains(source) else { return false }
    let areaRatio = surface.width * surface.height / max(0.000_001, source.width * source.height)
    return areaRatio <= 8
      && surface.width <= source.width * 2.2
      && surface.height <= source.height * 3
  }

  private static func coversVisibleSource(
    _ runs: [OverlaySourceStyleRun],
    in text: String
  ) -> Bool {
    guard !runs.isEmpty else { return false }
    var visible = IndexSet()
    for lowerBound in text.indices {
      let character = text[lowerBound]
      guard !character.unicodeScalars.allSatisfy(\.properties.isWhitespace) else { continue }
      let upperBound = text.index(after: lowerBound)
      let range = NSRange(lowerBound ..< upperBound, in: text)
      visible.insert(integersIn: range.location ..< NSMaxRange(range))
    }
    guard !visible.isEmpty else { return false }

    let sourceLength = (text as NSString).length
    var covered = IndexSet()
    for run in runs {
      let lowerBound = max(0, min(sourceLength, run.range.location))
      let upperBound = max(lowerBound, min(sourceLength, NSMaxRange(run.range)))
      covered.insert(integersIn: lowerBound ..< upperBound)
    }
    return visible.subtracting(covered).isEmpty
  }

  private static func inlineSurfaceErasers(
    for runs: [OverlaySourceStyleRun],
    parentBackground: OverlayColor,
    raster: PixelRaster
  ) -> [OverlaySourcePatch] {
    let runs = runs.reduce(into: [OverlaySourceStyleRun]()) { result, run in
      guard !result.contains(where: { sameBox($0.box, run.box) }) else { return }
      result.append(run)
    }
    var visited = Array(repeating: false, count: runs.count)
    var erasers = [OverlaySourcePatch]()
    for start in runs.indices where !visited[start] {
      visited[start] = true
      var queue = [start]
      var group = [runs[start]]
      while let index = queue.popLast() {
        for candidate in runs.indices where !visited[candidate] {
          guard sharesInlineSurface(runs[index], runs[candidate], raster: raster) else { continue }
          visited[candidate] = true
          queue.append(candidate)
          group.append(runs[candidate])
        }
      }
      let source = group.dropFirst().reduce(group[0].box) { $0.union($1.box) }
      let representative = group.max {
        $0.appearance.confidence < $1.appearance.confidence
      } ?? group[0]
      let detected = inferredSurface(
        containing: source,
        appearance: representative.appearance,
        raster: raster
      )?.clippingBox
      let box: CGRect
      if let detected, isCompactInlineSurface(detected, around: source) {
        box = detected
      } else {
        let pixels = pixelRect(for: source, raster: raster)
        let padded = pixels.insetBy(
          dx: -max(1, pixels.height * 0.45),
          dy: -max(1, pixels.height * 0.5)
        ).intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
        box = CGRect(
          x: padded.minX / CGFloat(raster.width),
          y: padded.minY / CGFloat(raster.height),
          width: padded.width / CGFloat(raster.width),
          height: padded.height / CGFloat(raster.height)
        )
      }
      var appearance = representative.appearance
      appearance.background = parentBackground
      erasers.append(OverlaySourcePatch(
        box: box,
        appearance: appearance,
        erasesDistinctSurface: true
      ))
    }
    return erasers
  }

  private static func sharesInlineSurface(
    _ lhs: OverlaySourceStyleRun,
    _ rhs: OverlaySourceStyleRun,
    raster: PixelRaster
  ) -> Bool {
    guard lhs.appearance.background.distance(to: rhs.appearance.background) <= 0.04 else {
      return false
    }
    let lhs = pixelRect(for: lhs.box, raster: raster)
    let rhs = pixelRect(for: rhs.box, raster: raster)
    let verticalOverlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    guard verticalOverlap / max(1, min(lhs.height, rhs.height)) >= 0.45 else { return false }
    let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
    return horizontalGap <= max(lhs.height, rhs.height) * 0.8
  }

  private static func text(in range: NSRange, source: String) -> String {
    guard let range = Range(range, in: source) else { return "" }
    return String(source[range])
  }

  private static func sameBox(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    abs(lhs.minX - rhs.minX) < 0.000_1
      && abs(lhs.minY - rhs.minY) < 0.000_1
      && abs(lhs.maxX - rhs.maxX) < 0.000_1
      && abs(lhs.maxY - rhs.maxY) < 0.000_1
  }

  private static func coversSameSurface(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
    let lhs = lhs.standardized
    let rhs = rhs.standardized
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    let intersectionArea = intersection.width * intersection.height
    let minimumArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
    return intersectionArea / max(0.000_001, minimumArea) >= 0.8
  }

  private static func shouldConsolidatePatches(
    _ patches: [OverlaySourcePatch],
    into lineAppearance: OverlaySourceAppearance,
    isVertical: Bool
  ) -> Bool {
    guard
      !isVertical,
      patches.count > 1,
      lineAppearance.confidence >= 0.3
    else { return false }
    return patches.allSatisfy {
      $0.appearance.background.distance(to: lineAppearance.background) <= 0.045
    }
  }

  private static func pixelRect(for normalizedBox: CGRect, raster: PixelRaster) -> CGRect {
    let box = normalizedBox.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard !box.isNull, !box.isEmpty else { return .null }
    return CGRect(
      x: box.minX * CGFloat(raster.width),
      y: box.minY * CGFloat(raster.height),
      width: max(1, box.width * CGFloat(raster.width)),
      height: max(1, box.height * CGFloat(raster.height))
    ).integral.intersection(CGRect(x: 0, y: 0, width: raster.width, height: raster.height))
  }

  private static func weightedColor(
    _ appearances: [WeightedAppearance],
    totalWeight: CGFloat,
    component: (WeightedAppearance) -> (OverlayColor, CGFloat)
  ) -> OverlayColor {
    appearances.reduce(OverlayColor(red: 0, green: 0, blue: 0, alpha: 1)) { result, appearance in
      let (color, weight) = component(appearance)
      return OverlayColor(
        red: result.red + color.red * weight / totalWeight,
        green: result.green + color.green * weight / totalWeight,
        blue: result.blue + color.blue * weight / totalWeight,
        alpha: 1
      )
    }
  }

  private static func fontWeight(
    for inkCoverage: CGFloat,
    source: CGRect,
    raster: PixelRaster
  ) -> OverlayFontWeight {
    if source.width >= source.height * 2, source.height / CGFloat(raster.height) >= 0.06, inkCoverage >= 0.2 {
      return .bold
    }
    return switch inkCoverage {
    case ..<0.23: .regular
    case ..<0.27: .medium
    case ..<0.33: .semibold
    default: .bold
    }
  }

  private static func combinedFontWeight(
    _ samples: [WeightedAppearance]
  ) -> OverlayFontWeight {
    let sorted = samples.sorted {
      $0.appearance.fontWeight.rawValue < $1.appearance.fontWeight.rawValue
    }
    let midpoint = sorted.reduce(0) { $0 + $1.weight } / 2
    var cumulative: CGFloat = 0
    for sample in sorted {
      cumulative += sample.weight
      if cumulative >= midpoint { return sample.appearance.fontWeight }
    }
    return sorted.last?.appearance.fontWeight ?? .semibold
  }

  private static func weightedInkHeight(_ samples: [WeightedAppearance]) -> CGFloat {
    let sorted = samples.filter { $0.appearance.inkHeightScale > 0 }.sorted {
      $0.appearance.inkHeightScale < $1.appearance.inkHeightScale
    }
    guard !sorted.isEmpty else { return 0 }
    let midpoint = sorted.reduce(0) { $0 + $1.weight } / 2
    var cumulative: CGFloat = 0
    for sample in sorted {
      cumulative += sample.weight
      if cumulative >= midpoint { return sample.appearance.inkHeightScale }
    }
    return sorted.last?.appearance.inkHeightScale ?? 0
  }

  private static func relativeLuminance(_ color: OverlayColor) -> CGFloat {
    func linearized(_ component: CGFloat) -> CGFloat {
      component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linearized(color.red)
      + 0.7152 * linearized(color.green)
      + 0.0722 * linearized(color.blue)
  }

  private static func isChromatic(_ color: OverlayColor) -> Bool {
    max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue) >= 0.15
  }

  private static func isLightNeutral(_ color: OverlayColor) -> Bool {
    min(color.red, color.green, color.blue) >= 0.8
      && max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue) <= 0.08
  }
}
