// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - OverlaySourceAppearanceAnalyzer

enum OverlaySourceAppearanceAnalyzer {

  // MARK: Internal

  static func applyingAppearances(to result: OCRResult, from image: CGImage) -> OCRResult {
    let styleRaster = PixelRaster(image: image, longestSide: 1_024)
    let surfaceRaster = PixelRaster(image: image, longestSide: 384)
    let styled = OCRResult(lines: result.lines.map { line in
      var line = line
      let lineAppearance = styleRaster.map {
        appearance(around: line.boundingBoxNormalized, raster: $0)
      } ?? .fallback
      let surroundingBackground = styleRaster.flatMap {
        sampledSurroundingBackground(around: line.boundingBoxNormalized, raster: $0)
      } ?? lineAppearance.background
      line.styleRuns = line.styleRuns.map { run in
        var run = run
        if let styleRaster {
          run.appearance = appearance(around: run.box, raster: styleRaster)
          run.appearance.fontDesign = fontDesign(
            for: text(in: run.range, source: line.text),
            appearance: run.appearance,
            surroundingBackground: surroundingBackground
          )
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
        } else if let styleRaster {
          patch.appearance = appearance(around: patch.box, raster: styleRaster)
        }
        return patch
      }
      if let styleRaster, !inlineStyleRuns.isEmpty {
        line.replacementPatches.append(contentsOf: inlineSurfaceErasers(
          for: inlineStyleRuns,
          parentBackground: surroundingBackground,
          raster: styleRaster
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
      line.appearance = combinedAppearance(appearanceSamples, fallback: lineAppearance)
      if
        !line.replacementPatches.contains(where: \.erasesDistinctSurface),
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
        let styleRaster,
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
        if let rubyPatch = nearbyChromaticRubyPatch(above: patch, raster: styleRaster) {
          line.replacementPatches.append(rubyPatch)
        }
      }
      if !line.isVerticalBlock, line.appearance.inkHeightScale > 0 {
        line.horizontalInkScale = line.appearance.inkHeightScale
      }
      line.surface = surfaceRaster.flatMap {
        inferredSurface(
          containing: line.boundingBoxNormalized,
          appearance: line.appearance,
          raster: $0
        )
      }
      return line
    })
    let coalesced = styled.absorbingRubyAnnotations().coalescingParagraphFragments()
    return OCRResult(lines: coalesced.lines.map { line in
      var line = line
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
          !$0.appearance.isUnderlined && !isChromatic($0.appearance.foreground)
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
        let sourceBox = line.boundingBoxNormalized.standardized
        let previousSurface = line.surface.flatMap { surface -> OverlaySourceSurface? in
          let bounds = (surface.clippingBox ?? surface.box).standardized
          let intersection = bounds.intersection(sourceBox)
          guard !intersection.isNull, !intersection.isEmpty else { return nil }
          let sourceArea = max(0.000_001, sourceBox.width * sourceBox.height)
          return intersection.width * intersection.height / sourceArea >= 0.94
            ? surface
            : nil
        }
        line.surface = inferredSurface(
          containing: sourceBox,
          appearance: line.appearance,
          raster: surfaceRaster,
          limitingTo: previousSurface?.clippingBox
        ) ?? previousSurface
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
      if line.isVerticalBlock, line.surface != nil {
        line.replacementPatches = line.replacementPatches.map { patch in
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
        line.replacementPatches = line.replacementPatches.map {
          extendingVerticalPatch(
            $0,
            characterScale: line.verticalCharScale,
            inside: surface.box,
            raster: styleRaster
          )
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

  private struct PixelRaster {

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
    }

    // MARK: Internal

    let width: Int
    let height: Int
    let pixels: [UInt8]

    func color(at index: Int) -> OverlayColor? {
      let offset = index * 4
      guard offset >= 0, offset + 3 < pixels.count, pixels[offset + 3] > 127 else { return nil }
      return OverlayColor(
        red: CGFloat(pixels[offset]) / 255,
        green: CGFloat(pixels[offset + 1]) / 255,
        blue: CGFloat(pixels[offset + 2]) / 255,
        alpha: 1
      )
    }

    func matchesBackground(
      at index: Int,
      color: OverlayColor,
      tolerance: CGFloat
    ) -> Bool {
      guard let sample = self.color(at: index) else { return false }
      return sample.distance(to: color) <= tolerance
    }
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
    limitingTo normalizedLimit: CGRect? = nil
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
    guard let seed else { return nil }

    var visited = [Bool](repeating: false, count: raster.width * raster.height)
    var queue = [seed]
    visited[seed] = true
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
      for neighbor in neighbors where neighbor >= 0 && !visited[neighbor] {
        visited[neighbor] = true
        let neighborX = neighbor % raster.width
        let neighborY = neighbor / raster.width
        guard
          allowedBounds.contains(CGPoint(
            x: CGFloat(neighborX) + 0.5,
            y: CGFloat(neighborY) + 0.5
          ))
        else { continue }
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

    let touchesImageEdge = minimumX == 0
      || minimumY == 0
      || maximumX == raster.width - 1
      || maximumY == raster.height - 1
    guard !touchesImageEdge else { return nil }
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
    guard confidence >= 0.35 else { return nil }
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
      confidence: confidence,
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
    raster: PixelRaster
  ) -> OverlaySourceAppearance {
    let source = pixelRect(for: normalizedBox, raster: raster)
    guard !source.isNull, !source.isEmpty else { return .fallback }
    let rasterBounds = CGRect(x: 0, y: 0, width: raster.width, height: raster.height)
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
      let interiorFormsSurface = edgeMatchRatio(
        color: interior.color,
        in: source,
        raster: raster
      ) >= 0.55
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
    var foregroundMinimumY = Int.max
    var foregroundMaximumY = Int.min
    var inkSampleCount = 0
    for y in Int(source.minY) ..< Int(source.maxY) {
      for x in Int(source.minX) ..< Int(source.maxX) {
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        let distance = color.distance(to: background)
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
        }
      }
    }
    let foreground: OverlayColor =
      if foregroundSampleCount > 0 {
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
    return OverlaySourceAppearance(
      background: background,
      foreground: foreground,
      confidence: min(1, dominant.confidence),
      foregroundConfidence: foregroundConfidence,
      inkCoverage: inkCoverage,
      inkHeightScale: inkHeightScale,
      fontWeight: fontWeight(for: inkCoverage, source: source, raster: raster),
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
      fontWeight: combinedFontWeight(dominant),
      fontDesign: dominant.filter { $0.appearance.fontDesign == .monospaced }.reduce(0) {
        $0 + $1.weight
      } * 2 >= totalSemanticWeight
        ? .monospaced
        : .standard,
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
    var buckets = [Int: Bucket]()
    var total = 0
    for y in Int(bounds.minY) ..< Int(bounds.maxY) {
      for x in Int(bounds.minX) ..< Int(bounds.maxX) {
        let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
        if excluded?.contains(point) == true { continue }
        guard let color = raster.color(at: y * raster.width + x) else { continue }
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        let key = (red >> 4) << 8 | (green >> 4) << 4 | (blue >> 4)
        var bucket = buckets[key, default: Bucket()]
        bucket.count += 1
        bucket.red += red
        bucket.green += green
        bucket.blue += blue
        buckets[key] = bucket
        total += 1
      }
    }
    guard total > 0, let dominant = buckets.values.max(by: { $0.count < $1.count }) else {
      return nil
    }
    let divisor = CGFloat(dominant.count * 255)
    return DominantSample(
      color: OverlayColor(
        red: CGFloat(dominant.red) / divisor,
        green: CGFloat(dominant.green) / divisor,
        blue: CGFloat(dominant.blue) / divisor,
        alpha: 1
      ),
      count: dominant.count,
      total: total
    )
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
    let strongCodePunctuation = CharacterSet(charactersIn: "*_`{}[]<>\\=")
    if
      text.count > 1 && text.hasPrefix(".")
      || text.unicodeScalars.contains(where: strongCodePunctuation.contains)
    {
      return .monospaced
    }
    let sitsOnDistinctSurface = appearance.background.distance(to: surroundingBackground) >= 0.025
    guard sitsOnDistinctSurface else { return .standard }
    let codePunctuation = CharacterSet(charactersIn: "/:")
    return text.unicodeScalars.contains(where: codePunctuation.contains)
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

extension OverlayColor {
  fileprivate func distance(to other: OverlayColor) -> CGFloat {
    max(abs(red - other.red), abs(green - other.green), abs(blue - other.blue))
  }
}
