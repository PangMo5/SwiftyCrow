// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Extends masks to observed ink, not an arbitrary larger rectangle. On textured
/// surfaces, replace only glyph pixels using nearby background samples. Tiles
/// remain transparent outside their masks so neighboring owners stay intact.
enum SourceRestorationBuilder {

  // MARK: Internal

  static func applying(to result: OCRResult, image: CGImage) async -> OCRResult {
    await resolvingOwnership(to: result, image: image) ?? result
  }

  /// A literal capture cannot interpret a failed raster allocation as proof
  /// that no protected artwork exists. Expose completion to that caller.
  static func resolvingOwnership(to result: OCRResult, image: CGImage) async -> OCRResult? {
    guard
      let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = context.data else { return nil }
    // Own immutable bytes before parallel work; no child borrows a mutable
    // CGContext or an escaping pointer. Each worker owns one line's masks.
    let raster = Data(bytes: data, count: image.width * image.height * 4)
    // Translation may split one observation into language/style fragments.
    // Its internal word gaps remain text, not newly discovered artwork.
    let observedBounds = result.lines.map { line in
      line.replacementPatches.reduce(line.boundingBoxNormalized) { $0.union($1.box) }
    }
    var groupedBounds = [ObservationGroup: CGRect]()
    for (index, line) in result.lines.enumerated() {
      if let group = ObservationGroup(line) {
        groupedBounds[group] = groupedBounds[group].map { $0.union(observedBounds[index]) } ?? observedBounds[index]
      }
    }
    let inputs = result.lines.enumerated().map { index, line in
      let bounds = ObservationGroup(line).flatMap { groupedBounds[$0] } ?? observedBounds[index]
      return (line: line, readingBounds: CGRect(
        x: bounds.minX * CGFloat(image.width),
        y: bounds.minY * CGFloat(image.height),
        width: bounds.width * CGFloat(image.width),
        height: bounds.height * CGFloat(image.height)
      ).integral)
    }
    let lines = await CaptureAnalysisExecutor.map(inputs) { input in
      raster.withUnsafeBytes { bytes in
        restore(
          input.line,
          readingBounds: input.readingBounds,
          width: image.width,
          height: image.height,
          pixels: bytes.bindMemory(to: UInt8.self)
        )
      }
    }
    return OCRResult(lines: lines)
  }

  // MARK: Private

  private struct ObservationGroup: Hashable {
    init?(_ line: OCRResult.Line) {
      guard let group = line.recognitionGroupID else { return nil }
      self.group = group
      context = line.recognitionContextID
      container = line.recognitionContainer
      table = line.tableCell?.table
      row = line.tableCell?.row
      column = line.tableCell?.column
      vertical = line.isVerticalBlock
    }

    var group: Int
    var context: Int?
    var container: CGRect?
    var table: Int?
    var row: Int?
    var column: Int?
    var vertical: Bool
  }

  private struct Pixel: Hashable {
    var r: Int
    var g: Int
    var b: Int

    var luminance: Int {
      (r + g + b) / 3
    }
  }

  private struct OutlineRange {
    var threshold: Int
    var isLight: Bool
    var strokeThreshold: Int

    func isStrokeTransition(_ luminance: Int) -> Bool {
      isLight ? luminance <= strokeThreshold : luminance >= strokeThreshold
    }

    func contains(_ luminance: Int) -> Bool {
      isLight ? luminance >= threshold : luminance <= threshold
    }
  }

  private static func restore(
    _ line: OCRResult.Line,
    readingBounds: CGRect,
    width: Int,
    height: Int,
    pixels: UnsafeBufferPointer<UInt8>
  ) -> OCRResult.Line {
    guard
      !Task.isCancelled, !line.preservesSource,
      !OCRTextSemantics.isCode(line.text), !OCRTextSemantics.isIdentifier(line.text)
    else { return line }
    func color(_ x: Int, _ y: Int) -> Pixel {
      let i = (y * width + x) * 4
      return Pixel(r: Int(pixels[i]), g: Int(pixels[i + 1]), b: Int(pixels[i + 2]))
    }
    var result = line
    result.layoutExclusions = []
    let compactSurface = line.surface.map {
      $0.box.height <= line.boundingBoxNormalized.height * 3.5
        && $0.box.width <= line.boundingBoxNormalized.width * 2.5
    } ?? false
    let bounds = line.boundingBoxNormalized
    var samples = [Int]()
    for y in [Int(bounds.minY * CGFloat(height)) - 2, Int(bounds.maxY * CGFloat(height)) + 2]
      where y >= 0 && y < height
    {
      for x in stride(
        from: max(0, Int(bounds.minX * CGFloat(width))),
        to: min(width, Int(bounds.maxX * CGFloat(width))),
        by: 3
      ) {
        samples.append(color(x, y).luminance)
      }
    }
    samples.sort()
    var histogram = [Int: Int]()
    for sample in samples { histogram[sample / 12, default: 0] += 1 }
    let textured = samples.count >= 30 && samples[samples.count * 9 / 10] - samples[samples.count / 10] > 24
      && histogram.values.count(where: { $0 * 20 >= samples.count }) >= 3
    // A recognized word can contain several foreground colors while Vision
    // supplies only one style run. On a verified flat background, every ink
    // color inside its owned text patch must disappear. Otherwise unmodeled
    // link colors become "background" samples and are copied into the tile.
    let backgroundLuminance = components(line.appearance.background).luminance
    let flatBackground = !textured && samples.count >= 10
      && samples.count(where: { abs($0 - backgroundLuminance) <= 18 }) * 5 >= samples.count * 4
    if textured {
      // Background variation is not an inline badge/code style. Keeping
      // those false style spans would repaint blocks over the restored tile.
      result.styleRuns = line.styleRuns.map { run in
        var run = run
        run.appearance.background = line.appearance.background
        return run
      }
    }
    // A paragraph envelope is not an erasure owner. In particular, the gap
    // beside a short row can contain a balloon border or other artwork. Keep
    // each observed row/word's geometry and local background even on texture.
    // A reconstructed enclosed text region has separate pixel evidence for
    // ownership between its rows (including small pronunciation marks). Its
    // measured surface contour still clips the resulting restoration tile.
    let ownsEnclosedText = line.isReconstructedTextRegion && line.surface?.clippingRows.isEmpty == false
    let patches = textured && ownsEnclosedText && !line.replacementPatches.contains(where: \.isAnnotation)
      ? [OverlaySourcePatch(
        box: line.boundingBoxNormalized,
        appearance: line.appearance,
        clippingBox: line.replacementPatches.compactMap(\.clippingBox).first
      )]
      : line.replacementPatches + missingAnnotationPatches(for: line, width: width, height: height, color: color)
    result.replacementPatches = patches
    // Base glyphs, ruby and adjacent observed words share one translation owner.
    // Continuing into another patch of that owner is still text evidence.
    let textOwners = (line.replacementPatches + patches).map { patch in
      CGRect(
        x: patch.box.minX * CGFloat(width),
        y: patch.box.minY * CGFloat(height),
        width: patch.box.width * CGFloat(width),
        height: patch.box.height * CGFloat(height)
      ).integral
    }
    for j in patches.indices {
      var patch = patches[j]
      guard !patch.erasesDistinctSurface || textured else { continue }
      if textured { patch.erasesDistinctSurface = false }
      let fg = components(patch.appearance.foreground)
      let bg = components(patch.appearance.background)
      let foregrounds = Array(Set([fg] + line.styleRuns.filter {
        !$0.box.intersection(patch.box).isNull
      }.map { components($0.appearance.foreground) }))
      let contrast = distance(fg, bg)
      guard contrast >= 30 else { continue }
      let backgroundTolerance = flatBackground ? min(18, contrast / 3) : contrast / 3
      let box = patch.box
      let original = CGRect(
        x: box.minX * CGFloat(width),
        y: box.minY * CGFloat(height),
        width: box.width * CGFloat(width),
        height: box.height * CGFloat(height)
      ).integral
      let measuredGlyph = line.isVerticalBlock
        ? line.verticalCharScale * CGFloat(width)
        : line.horizontalGlyphScale * CGFloat(height)
      let fontExtent = line.appearance.fontSizeScale * CGFloat(height)
      let glyphExtent = measuredGlyph > 0
        ? measuredGlyph
        : fontExtent > 0
          ? fontExtent
          : line.isVerticalBlock ? original.width : original.height
      let outlineRadius = max(2, Int(ceil(glyphExtent * 0.2)))
      let contactDistance = max(2, Int(ceil(glyphExtent * 0.05)))
      // Sampling must contain a scaled stroke and its outline. Extra analysis
      // pixels do not become text owners or seeds for unrelated nearby glyphs.
      let minimumAnalysisMargin = max(2, min(8, Int(original.height * 0.15)))
      let margin = max(minimumAnalysisMargin, outlineRadius + contactDistance)
      var rect = original.insetBy(dx: -CGFloat(margin), dy: -CGFloat(margin)).intersection(CGRect(
        x: 0,
        y: 0,
        width: width,
        height: height
      )).integral
      if let clip = patch.clippingBox {
        rect = rect.intersection(CGRect(
          x: clip.minX * CGFloat(width),
          y: clip.minY * CGFloat(height),
          width: clip.width * CGFloat(width),
          height: clip.height * CGFloat(height)
        ))
        guard !rect.isNull else { continue }
        rect = CGRect(
          x: ceil(rect.minX),
          y: ceil(rect.minY),
          width: max(0, floor(rect.maxX) - ceil(rect.minX)),
          height: max(0, floor(rect.maxY) - ceil(rect.minY))
        )
      }
      let candidateOutline = outlineRange(
        width: Int(rect.width),
        height: Int(rect.height),
        foreground: fg
      ) { color(Int(rect.minX) + $0, Int(rect.minY) + $1) }
      if candidateOutline == nil {
        // No opposite-polarity range exists on this material. Keep the
        // ordinary working tile instead of scanning a larger empty margin.
        rect = rect.intersection(original.insetBy(
          dx: -CGFloat(minimumAnalysisMargin),
          dy: -CGFloat(minimumAnalysisMargin)
        ))
      }
      let x0 = Int(rect.minX)
      let y0 = Int(rect.minY)
      let w = Int(rect.width)
      let h = Int(rect.height)
      guard w > 0, h > 0 else { continue }
      var ink = [Bool](repeating: false, count: w * h)
      var queue = [Int]()
      // Observation boxes seed ownership; surrounding analysis padding does
      // not. Connected glyph strokes can grow beyond an underbounded OCR box.
      // Separately observed annotations have their own patches instead of
      // claiming arbitrary detached marks above/below a row.
      for y in 0..<h {
        for x in 0..<w {
          let c = color(x0 + x, y0 + y)
          if
            original.contains(CGPoint(x: x0 + x, y: y0 + y)),
            foregrounds.contains(where: { distance(c, $0) < distance($0, bg) / 2 && distance($0, bg) >= 30 })
            || (flatBackground && !patch.isAnnotation && original.contains(CGPoint(x: x0 + x, y: y0 + y))
              && distance(c, bg) >= 30)
          {
            ink[y * w + x] = true
            queue.append(y * w + x)
          }
        }
      }
      guard !queue.isEmpty else { continue }
      var cursor = 0
      while cursor < queue.count {
        let k = queue[cursor]
        cursor += 1
        let x = k % w
        let y = k / w
        for ny in max(0, y - 1)...min(h - 1, y + 1) {
          for nx in max(0, x - 1)...min(w - 1, x + 1) {
            let next = ny * w + nx
            guard !ink[next] else { continue }
            let c = color(x0 + nx, y0 + ny)
            guard
              distance(c, bg) >= max(8, contrast / 8),
              foregrounds.contains(where: { distance(c, $0) < distance(c, bg) })
              || (flatBackground && !patch.isAnnotation && original.contains(CGPoint(x: x0 + nx, y: y0 + ny)))
            else { continue }
            ink[next] = true
            queue.append(next)
          }
        }
      }
      let protected = rejectExternalArtwork(
        in: &ink,
        width: w,
        height: h,
        origin: CGPoint(x: x0, y: y0),
        source: original,
        owners: textOwners,
        readingBounds: readingBounds,
        vertical: line.isVerticalBlock,
        glyphExtent: glyphExtent,
        imageWidth: width,
        imageHeight: height
      ) { x, y in
        let pixel = color(x, y)
        return distance(pixel, bg) >= max(8, contrast / 8)
          && foregrounds.contains(where: { distance(pixel, $0) < distance(pixel, bg) })
      }
      guard ink.contains(true) else {
        // There is no established glyph owner. An opaque rectangle would
        // re-erase the very component whose external ownership was just proved.
        patch.appearance.background.alpha = 0
        patch.restorationPNG = nil
        result.replacementPatches[j] = patch
        continue
      }
      let outline = absorbOutline(
        into: &ink,
        width: w,
        height: h,
        range: candidateOutline,
        radius: min(max(w, h), outlineRadius),
        contactDistance: contactDistance,
        color: { x, y in
          let sx = x0 + x
          let sy = y0 + y
          guard sx >= 0, sx < width, sy >= 0, sy < height else { return nil }
          return color(sx, sy)
        },
        ownsInk: { x, y in
          let point = CGPoint(x: x0 + x, y: y0 + y)
          guard
            textOwners.contains(where: { $0.contains(point) }),
            point.x >= 0, point.x < CGFloat(width), point.y >= 0, point.y < CGFloat(height)
          else { return false }
          let pixel = color(Int(point.x), Int(point.y))
          return foregrounds.contains { distance(pixel, $0) < distance($0, bg) / 2 && distance($0, bg) >= 30 }
        }
      )
      // Resampling spreads the glyph edge beyond the high-contrast ink.
      // Exclude that fringe before estimating background variation, too:
      // otherwise gray antialiasing is mistaken for texture and copied back
      // into the removed letters as a restoration sample.
      let fringe = max(1, min(3, Int(ceil(original.height * 0.04))))
      var protection = protected
      if let protected {
        for k in protected.indices where protected[k] {
          let x = k % w
          let y = k / w
          for ny in max(0, y - fringe)...min(h - 1, y + fringe) {
            for nx in max(0, x - fringe)...min(w - 1, x + fringe) where !ink[ny * w + nx] {
              protection![ny * w + nx] = true
            }
          }
        }
        for k in ink.indices where protection![k] { ink[k] = false }
      }
      guard ink.contains(true) else {
        patch.appearance.background.alpha = 0
        patch.restorationPNG = nil
        result.replacementPatches[j] = patch
        continue
      }
      if let protection {
        result.layoutExclusions += artworkRows(protection, width: w, height: h, x: x0, y: y0).map {
          let box = $0.insetBy(dx: -1, dy: -1).intersection(CGRect(x: 0, y: 0, width: width, height: height))
          return CGRect(
            x: box.minX / CGFloat(width),
            y: box.minY / CGFloat(height),
            width: box.width / CGFloat(width),
            height: box.height / CGFloat(height)
          )
        }
      }
      let originalInk = ink
      var minX = w
      var minY = h
      var maxX = 0
      var maxY = 0
      for k in originalInk.indices where originalInk[k] {
        let x = k % w
        let y = k / w
        minX = min(minX, max(0, x - fringe))
        minY = min(minY, max(0, y - fringe))
        maxX = max(maxX, min(w, x + fringe + 1))
        maxY = max(maxY, min(h, y + fringe + 1))
        for ny in max(0, y - fringe)...min(h - 1, y + fringe) {
          for nx in max(0, x - fringe)...min(w - 1, x + fringe) {
            ink[ny * w + nx] = true
          }
        }
      }
      if let protection {
        for k in ink.indices where protection[k] { ink[k] = false }
      }
      let maskBounds = CGRect(
        x: CGFloat(x0 + minX) / CGFloat(width),
        y: CGFloat(y0 + minY) / CGFloat(height),
        width: CGFloat(maxX - minX) / CGFloat(width),
        height: CGFloat(maxY - minY) / CGFloat(height)
      )
      patch.renderingBox = maskBounds
      // The spread of non-glyph pixels distinguishes texture from a flat
      // surface. Keep the cheap color fill for ordinary UI and paper.
      var background = [Int]()
      for k in stride(from: 0, to: ink.count, by: 3) where !ink[k] {
        background.append(color(x0 + k % w, y0 + k / w).luminance)
      }
      background.sort()
      if
        protected != nil || patch.isAnnotation || compactSurface || textured || outline != nil ||
        (background.count > 20 && background[background.count * 9 / 10] - background[background.count / 10] > 24),
        let tile = CGContext(
          data: nil,
          width: w,
          height: h,
          bitsPerComponent: 8,
          bytesPerRow: w * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let destination = tile.data
      {
        let out = destination.bindMemory(to: UInt8.self, capacity: w * h * 4)
        tile.clear(CGRect(x: 0, y: 0, width: w, height: h))
        // Material observed inside the text owner can establish a flat surface
        // even when analysis padding crosses a neighboring row or card edge.
        // A dominant local color is evidence; foreground contrast alone cannot
        // authorize borrowing a different, nearby surface as a donor.
        // Match the renderer's established surface ownership. Its safe
        // interior is a stronger material sample than padding outside the
        // source plane (for example the white row under a gray table header).
        let materialSurface = line.surface.flatMap { SourcePatchClipping.surface(for: patch, within: $0) }
        let localMaterial: Pixel?
        if materialSurface == nil {
          var materialSamples = [Pixel]()
          var materialBins = [Pixel: Int]()
          for k in ink.indices where !ink[k] && protection?[k] != true {
            let point = CGPoint(x: x0 + k % w, y: y0 + k / w)
            guard original.contains(point) else { continue }
            let pixel = color(Int(point.x), Int(point.y))
            guard foregrounds.allSatisfy({ distance(pixel, bg) <= distance(pixel, $0) }) else { continue }
            materialSamples.append(pixel)
            materialBins[Pixel(r: pixel.r / 4, g: pixel.g / 4, b: pixel.b / 4), default: 0] += 1
          }
          if
            materialSamples.count >= 8,
            let dominant = materialBins.max(by: { $0.value < $1.value }),
            dominant.value * 10 >= materialSamples.count * 9
          {
            let cluster = materialSamples.filter { Pixel(r: $0.r / 4, g: $0.g / 4, b: $0.b / 4) == dominant.key }
            let median = Pixel(
              r: cluster.map(\.r).sorted()[cluster.count / 2],
              g: cluster.map(\.g).sorted()[cluster.count / 2],
              b: cluster.map(\.b).sorted()[cluster.count / 2]
            )
            localMaterial = distance(median, bg) <= 18 ? median : nil
          } else { localMaterial = nil }
        } else if let surface = materialSurface {
          // Sample the established plane's perimeter, away from this glyph's
          // antialiasing and away from the exterior material. A varying plane
          // retains the existing reconstruction instead of being flattened.
          let left = max(0, Int(ceil(surface.box.minX * CGFloat(width))))
          let right = min(width - 1, Int(floor(surface.box.maxX * CGFloat(width))))
          let top = max(0, Int(ceil(surface.box.minY * CGFloat(height))))
          let bottom = min(height - 1, Int(floor(surface.box.maxY * CGFloat(height))))
          var samples = [Pixel]()
          func append(_ x: Int, _ y: Int) {
            let point = CGPoint(x: CGFloat(x) / CGFloat(width), y: CGFloat(y) / CGFloat(height))
            guard surface.clippingRows.isEmpty || surface.clippingRows.contains(where: { $0.contains(point) }) else { return }
            let pixel = color(x, y)
            guard foregrounds.allSatisfy({ distance(pixel, bg) <= distance(pixel, $0) }) else { return }
            samples.append(pixel)
          }
          if left <= right, top <= bottom {
            for x in left...right { append(x, top)
              if bottom != top { append(x, bottom) }
            }
            if top + 1 < bottom { for y in top + 1..<bottom {
              append(left, y)
              if right != left { append(right, y) }
            } }
          }
          if samples.count >= 8 {
            let median = Pixel(
              r: samples.map(\.r).sorted()[samples.count / 2],
              g: samples.map(\.g).sorted()[samples.count / 2],
              b: samples.map(\.b).sorted()[samples.count / 2]
            )
            localMaterial = distance(median, bg) <= 18
              && samples.count(where: { distance($0, median) <= 3 }) * 10 >= samples.count * 9
              ? median
              : nil
          } else { localMaterial = nil }
        } else { localMaterial = nil }
        func belongsToLocalMaterial(_ pixel: Pixel) -> Bool {
          localMaterial.map { distance(pixel, $0) <= 3 } ?? true
        }
        if let surface = materialSurface, let localMaterial, outline == nil {
          // Resampling can leave an opposite-polarity ringing pixel just past
          // the ordinary glyph fringe. A verified flat plane authorizes one
          // additional connected ring, while retained artwork stays excluded.
          let clippingBounds = surface.clippingBox ?? surface.box
          let priorInk = ink
          for k in ink.indices where !priorInk[k] && protection?[k] != true {
            let x = k % w
            let y = k / w
            let point = CGPoint(x: CGFloat(x0 + x) / CGFloat(width), y: CGFloat(y0 + y) / CGFloat(height))
            guard
              clippingBounds.contains(point),
              surface.clippingRows.isEmpty || surface.clippingRows.contains(where: { $0.contains(point) }),
              distance(color(x0 + x, y0 + y), localMaterial) > 1
            else { continue }
            if
              (max(0, y - 1)...min(h - 1, y + 1)).contains(where: { ny in
                (max(0, x - 1)...min(w - 1, x + 1)).contains { nx in priorInk[ny * w + nx] }
              }) { ink[k] = true }
          }
        }
        if materialSurface == nil, let localMaterial, outline == nil {
          for k in ink.indices where ink[k] && !originalInk[k] {
            let pixel = color(x0 + k % w, y0 + k / w)
            guard !belongsToLocalMaterial(pixel) else { continue }
            let delta = SIMD3(
              Float(pixel.r - localMaterial.r),
              Float(pixel.g - localMaterial.g),
              Float(pixel.b - localMaterial.b)
            )
            let transition = foregrounds.contains { foreground in
              let direction = SIMD3(
                Float(foreground.r - localMaterial.r),
                Float(foreground.g - localMaterial.g),
                Float(foreground.b - localMaterial.b)
              )
              let length = (direction * direction).sum()
              guard length > 0 else { return false }
              let position = (delta * direction).sum() / length
              guard (0...1).contains(position) else { return false }
              let error = delta - direction * position
              return max(abs(error.x), abs(error.y), abs(error.z)) <= 3
            }
            if !transition {
              ink[k] = false
            }
          }
        }
        let unresolved = BackgroundReconstruction.fill(
          width: w,
          height: h,
          mask: ink,
          barriers: protection,
          allowsExteriorSamples: true
        ) { x, y in
          let sourceX = x0 + x
          let sourceY = y0 + y
          guard sourceX >= 0, sourceX < width, sourceY >= 0, sourceY < height else { return nil }
          if let surface = materialSurface {
            let point = CGPoint(x: CGFloat(sourceX) / CGFloat(width), y: CGFloat(sourceY) / CGFloat(height))
            guard
              (surface.clippingBox ?? surface.box).contains(point),
              surface.clippingRows.isEmpty || surface.clippingRows.contains(where: { $0.contains(point) })
            else { return nil }
          }
          let candidate = color(sourceX, sourceY)
          // Neighboring text and opposite-polarity decoration are not material.
          guard
            distance(candidate, bg) < backgroundTolerance, belongsToLocalMaterial(candidate),
            outline?.contains(candidate.luminance) != true,
            outline?.isStrokeTransition(candidate.luminance) != true
          else { return nil }
          return SIMD3(Float(candidate.r), Float(candidate.g), Float(candidate.b))
        } write: { index, color in
          // A missing material sample must not copy the old glyph opaquely
          // over a neighboring owner's successful restoration.
          guard let color else { return }
          out[index * 4] = UInt8(clamping: Int(color.x.rounded()))
          out[index * 4 + 1] = UInt8(clamping: Int(color.y.rounded()))
          out[index * 4 + 2] = UInt8(clamping: Int(color.z.rounded()))
          out[index * 4 + 3] = 255
        }
        if unresolved > 0 { result.needsReview = true }
        patch.renderingBox = CGRect(
          x: rect.minX / CGFloat(width),
          y: rect.minY / CGFloat(height),
          width: rect.width / CGFloat(width),
          height: rect.height / CGFloat(height)
        )
        patch.restorationPNG = tile.makeImage()?.pngData
      }
      if patch.restorationPNG == nil {
        // The raster pass already resolves connected ink and antialiasing.
        // A second font-sized bleed during drawing would erase unowned nearby
        // artwork or page chrome. Bound the cheap flat fill to that evidence.
        patch.clippingBox = patch.clippingBox.map { $0.intersection(maskBounds) } ?? maskBounds
      }
      result.replacementPatches[j] = patch
    }
    return result
  }

  /// Keep holes and curved contours; a single enclosing box could incorrectly
  /// reserve the entire interior of a frame. Equal adjacent row spans merge.
  private static func artworkRows(_ mask: [Bool], width: Int, height: Int, x: Int, y: Int) -> [CGRect] {
    var rectangles = [CGRect]()
    var previous = [Range<Int>: Int]()
    for row in 0..<height {
      var current = [Range<Int>: Int]()
      var column = 0
      while column < width {
        guard mask[row * width + column] else { column += 1
          continue
        }
        let start = column
        while column < width, mask[row * width + column] { column += 1 }
        let span = start..<column
        if let index = previous[span] {
          rectangles[index].size.height += 1
          current[span] = index
        } else {
          current[span] = rectangles.count
          rectangles.append(CGRect(x: x + start, y: y + row, width: column - start, height: 1))
        }
      }
      previous = current
    }
    return rectangles
  }

  /// The expanded perimeter must be checked even when the final working
  /// tile can stay small: a tight OCR crop may contain only the outline.
  private static func outlineRange(
    width: Int,
    height: Int,
    foreground: Pixel,
    color: (Int, Int) -> Pixel
  ) -> OutlineRange? {
    guard width > 4, height > 4 else { return nil }
    var perimeter = [Int]()
    for x in 0..<width {
      perimeter.append(color(x, 0).luminance)
      perimeter.append(color(x, height - 1).luminance)
    }
    for y in 1..<(height - 1) {
      perimeter.append(color(0, y).luminance)
      perimeter.append(color(width - 1, y).luminance)
    }
    perimeter.sort()
    let median = perimeter[perimeter.count / 2]
    let range: OutlineRange
    if foreground.luminance < median - 40 {
      // A nearby frame can occupy one entire sampling edge. Remove the
      // foreground-side cluster before estimating material, then keep the
      // outline itself out of the background's upper tail.
      let contrast = perimeter[perimeter.count * 9 / 10] - foreground.luminance
      let material = perimeter.filter { $0 - foreground.luminance > contrast / 2 }
      guard !material.isEmpty else { return nil }
      let center = material[material.count / 2]
      let band = material.filter { abs($0 - center) <= 16 }
      let threshold = max(center + 18, band[band.count * 9 / 10] + 8)
      guard threshold <= 255 else { return nil }
      range = OutlineRange(
        threshold: threshold,
        isLight: true,
        strokeThreshold: center - max(8, abs(center - foreground.luminance) / 8)
      )
    } else if foreground.luminance > median + 40 {
      let contrast = foreground.luminance - perimeter[perimeter.count / 10]
      let material = perimeter.filter { foreground.luminance - $0 > contrast / 2 }
      guard !material.isEmpty else { return nil }
      let center = material[material.count / 2]
      let band = material.filter { abs($0 - center) <= 16 }
      let threshold = min(center - 18, band[band.count / 10] - 8)
      guard threshold >= 0 else { return nil }
      range = OutlineRange(
        threshold: threshold,
        isLight: false,
        strokeThreshold: center + max(8, abs(center - foreground.luminance) / 8)
      )
    } else { return nil }

    return range
  }

  /// Detect bounded, opposite-polarity components around established glyphs.
  /// The outer perimeter estimates material without sampling the stroke halo.
  /// An open component must remain close to observed glyphs of this same text
  /// owner outside the tile, too. Reaching a crop edge alone proves neither
  /// background nor decoration ownership.
  private static func absorbOutline(
    into ink: inout [Bool],
    width: Int,
    height: Int,
    range: OutlineRange?,
    radius: Int,
    contactDistance: Int,
    color: (Int, Int) -> Pixel?,
    ownsInk: (Int, Int) -> Bool
  ) -> OutlineRange? {
    guard let range else { return nil }

    // Classify local color once. Plain material without an opposite-polarity
    // component needs no distance-buffer allocation or exterior traversal.
    let candidates = ink.indices.map { !ink[$0] && range.contains(color($0 % width, $0 / width)!.luminance) }
    guard candidates.contains(true) else { return nil }
    var visited = [Bool](repeating: false, count: ink.count)
    var components = [(pixels: [Int], bounded: Bool)]()
    for start in ink.indices where candidates[start] && !visited[start] {
      var component = [start]
      visited[start] = true
      var cursor = 0
      var bounded = true
      while cursor < component.count {
        let index = component[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        bounded = bounded && x > 0 && y > 0 && x < width - 1 && y < height - 1
        for ny in max(0, y - 1)...min(height - 1, y + 1) {
          for nx in max(0, x - 1)...min(width - 1, x + 1) {
            let next = ny * width + nx
            if candidates[next], !visited[next] {
              visited[next] = true
              component.append(next)
            }
          }
        }
      }
      if component.count >= 3 { components.append((component, bounded)) }
    }
    guard !components.isEmpty else { return nil }
    // Outline thickness starts at the stroke's antialiased edge, not its
    // darkest/lightest core. Grow distance seeds only through connected pixels
    // on the foreground side of the measured material. A geometric dilation
    // would also turn nearby background and unrelated decorations into seeds.
    let strongDistances = inkDistances(ink, width: width, height: height, limit: contactDistance)
    var transitionInk = ink
    var transitionQueue = ink.indices.filter { ink[$0] }
    var transitionCursor = 0
    while transitionCursor < transitionQueue.count {
      let index = transitionQueue[transitionCursor]
      transitionCursor += 1
      let x = index % width
      let y = index / width
      for ny in max(0, y - 1)...min(height - 1, y + 1) {
        for nx in max(0, x - 1)...min(width - 1, x + 1) {
          let next = ny * width + nx
          guard !transitionInk[next], strongDistances[next] <= contactDistance else { continue }
          let luminance = color(nx, ny)!.luminance
          guard range.isStrokeTransition(luminance) else { continue }
          transitionInk[next] = true
          transitionQueue.append(next)
        }
      }
    }
    let distances = inkDistances(transitionInk, width: width, height: height, limit: radius)
    // Exterior queries see the original strong pixels, so include their
    // bounded transition gap when checking a neighboring observed owner.
    let maximumDistance = radius + contactDistance
    struct Point: Hashable {
      var x: Int
      var y: Int
    }
    var ownedInk = [Point: Bool]()
    func nearOwner(_ point: Point) -> Bool {
      for distance in 0...maximumDistance {
        for y in (point.y - distance)...(point.y + distance) {
          for x in (point.x - distance)...(point.x + distance)
            where distance == 0 || abs(x - point.x) == distance || abs(y - point.y) == distance
          {
            let p = Point(x: x, y: y)
            let owned: Bool
            if let cached = ownedInk[p] { owned = cached }
            else { owned = ownsInk(x, y)
              ownedInk[p] = owned
            }
            if owned { return true }
          }
        }
      }
      return false
    }
    func exteriorBelongsToOwner(_ component: [Int]) -> Bool {
      var queue = component.map { Point(x: $0 % width, y: $0 / width) }
      var visited = Set(queue)
      var cursor = 0
      while cursor < queue.count {
        let point = queue[cursor]
        cursor += 1
        for y in (point.y - 1)...(point.y + 1) {
          for x in (point.x - 1)...(point.x + 1) {
            let next = Point(x: x, y: y)
            guard visited.insert(next).inserted else { continue }
            guard let pixel = color(x, y) else { return false }
            guard range.contains(pixel.luminance) else { continue }
            // Whole bright/dark surfaces eventually leave the glyph corridor.
            // Reject the component then; do not truncate it into a fake halo.
            guard nearOwner(next) else { return false }
            queue.append(next)
          }
        }
      }
      return true
    }
    var accepted = false
    for component in components {
      guard
        component.pixels.contains(where: { distances[$0] <= contactDistance }),
        component.pixels.allSatisfy({
          distances[$0] <= radius || (!component.bounded && nearOwner(Point(x: $0 % width, y: $0 / width)))
        }),
        component.bounded || exteriorBelongsToOwner(component.pixels)
      else { continue }
      for index in component.pixels { ink[index] = true }
      accepted = true
    }
    if accepted {
      // These connected foreground-side pixels are part of the observed
      // stroke, not merely distance seeds. Leaving them outside the final
      // mask can reveal gray source fragments between the core and outline.
      for index in transitionInk.indices where transitionInk[index] { ink[index] = true }
    }
    return accepted ? range : nil
  }

  /// Exact eight-neighbor distance to any ink pixel on an unobstructed raster.
  /// Two linear sweeps replace a per-pixel queue; work stays proportional to
  /// pixel count as the search radius grows. More distant values are capped.
  private static func inkDistances(_ ink: [Bool], width: Int, height: Int, limit: Int) -> [Int] {
    var values = ink.map { $0 ? 0 : limit + 1 }
    for y in 0..<height {
      for x in 0..<width {
        let index = y * width + x
        guard values[index] > 0 else { continue }
        if x > 0 { values[index] = min(values[index], values[index - 1] + 1) }
        if y > 0 {
          for nx in max(0, x - 1)...min(width - 1, x + 1) {
            values[index] = min(values[index], values[(y - 1) * width + nx] + 1)
          }
        }
      }
    }
    for y in stride(from: height - 1, through: 0, by: -1) {
      for x in stride(from: width - 1, through: 0, by: -1) {
        let index = y * width + x
        guard values[index] > 0 else { continue }
        if x < width - 1 { values[index] = min(values[index], values[index + 1] + 1) }
        if y < height - 1 {
          for nx in max(0, x - 1)...min(width - 1, x + 1) {
            values[index] = min(values[index], values[(y + 1) * width + nx] + 1)
          }
        }
      }
    }
    return values
  }

  /// A pixel inside an OCR rectangle is not necessarily text. For components
  /// reaching the tile edge, check whether the same stroke continues a full
  /// glyph beyond the observed text owner. The bounded external walk never
  /// expands erasure ownership; it only proves pixels that must be preserved.
  private static func rejectExternalArtwork(
    in ink: inout [Bool],
    width: Int,
    height: Int,
    origin: CGPoint,
    source: CGRect,
    owners: [CGRect],
    readingBounds: CGRect,
    vertical: Bool,
    glyphExtent: CGFloat,
    imageWidth: Int,
    imageHeight: Int,
    isForeground: (Int, Int) -> Bool
  ) -> [Bool]? {
    // Most text patches never reach an edge. Visit their perimeter directly,
    // instead of rescanning every interior glyph/background pixel twice.
    var boundary = [Int]()
    boundary.reserveCapacity(2 * (width + height))
    for x in 0..<width { boundary.append(x)
      boundary.append((height - 1) * width + x)
    }
    for y in 0..<height { boundary.append(y * width)
      boundary.append(y * width + width - 1)
    }
    // A disconnected accessory can graze an OCR edge while fitting entirely
    // inside the analysis tile. A crop-edge-only scan would never inspect it.
    // Read-axis ownership also preserves accents above/beside an observed
    // glyph, while rejecting an adjacent component centered beyond the text.
    let axisLength = vertical ? height : width
    let crossLength = vertical ? width : height
    let axisOrigin = vertical ? origin.y : origin.x
    var ownedAxis = [Bool](repeating: false, count: axisLength)
    let lower = (vertical ? readingBounds.minY : readingBounds.minX) - axisOrigin
    let upper = (vertical ? readingBounds.maxY : readingBounds.maxX) - axisOrigin
    let start = max(0, Int(ceil(lower - 0.5)))
    let end = min(axisLength, Int(ceil(upper - 0.5)))
    if start < end { for position in start..<end { ownedAxis[position] = true } }
    for axis in 0..<axisLength where !ownedAxis[axis] {
      for cross in 0..<crossLength {
        let index = vertical ? axis * width + cross : cross * width + axis
        if ink[index] { boundary.append(index) }
      }
    }
    guard boundary.contains(where: { ink[$0] }) else { return nil }
    var visited = [Bool](repeating: false, count: ink.count)
    var protected: [Bool]?
    for start in boundary where ink[start] && !visited[start] {
      var component = [start]
      var endpoints = [Int]()
      visited[start] = true
      var cursor = 0
      var touchesLeft = false
      var touchesRight = false
      var touchesTop = false
      var touchesBottom = false
      var containsOwnedInk = false
      var minimumAxis = axisLength
      var maximumAxis = 0
      while cursor < component.count {
        let index = component[cursor]
        cursor += 1
        let x = index % width
        let y = index / width
        minimumAxis = min(minimumAxis, vertical ? y : x)
        maximumAxis = max(maximumAxis, vertical ? y : x)
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 { endpoints.append(index) }
        touchesLeft = touchesLeft || x == 0
        touchesRight = touchesRight || x == width - 1
        touchesTop = touchesTop || y == 0
        touchesBottom = touchesBottom || y == height - 1
        containsOwnedInk = containsOwnedInk || owners.contains {
          $0.contains(CGPoint(x: origin.x + CGFloat(x), y: origin.y + CGFloat(y)))
        }
        for ny in max(0, y - 1)...min(height - 1, y + 1) {
          for nx in max(0, x - 1)...min(width - 1, x + 1) {
            let next = ny * width + nx
            if ink[next], !visited[next] { visited[next] = true
              component.append(next)
            }
          }
        }
      }
      let whollyExternalBorder = !containsOwnedInk && ((touchesLeft && touchesRight) || (touchesTop && touchesBottom))
      let center = (minimumAxis + maximumAxis) / 2
      let centeredOutsideOwner = !ownedAxis[center]
      if
        whollyExternalBorder || centeredOutsideOwner || continuesOutsideOwner(
          endpoints: endpoints,
          width: width,
          height: height,
          origin: origin,
          source: source,
          owners: owners,
          glyphExtent: glyphExtent,
          imageWidth: imageWidth,
          imageHeight: imageHeight,
          isForeground: isForeground
        )
      {
        if protected == nil { protected = [Bool](repeating: false, count: ink.count) }
        for index in component { ink[index] = false
          protected![index] = true
        }
      }
    }
    return protected
  }

  private static func continuesOutsideOwner(
    endpoints: [Int],
    width: Int,
    height: Int,
    origin: CGPoint,
    source: CGRect,
    owners: [CGRect],
    glyphExtent: CGFloat,
    imageWidth: Int,
    imageHeight: Int,
    isForeground: (Int, Int) -> Bool
  ) -> Bool {
    guard glyphExtent.isFinite, glyphExtent > 0 else { return false }
    let reach = max(2, Int(ceil(glyphExtent)))
    let tile = CGRect(origin: origin, size: CGSize(width: width, height: height))
    let search = source.union(tile).insetBy(dx: -CGFloat(reach + 1), dy: -CGFloat(reach + 1))
      .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight)).integral
    let x0 = Int(origin.x)
    let y0 = Int(origin.y)
    var queue = endpoints.map { (y0 + $0 / width) * imageWidth + x0 + $0 % width }
    var visited = Set(queue)
    var cursor = 0
    while cursor < queue.count {
      let index = queue[cursor]
      cursor += 1
      let x = index % imageWidth
      let y = index / imageWidth
      let outside = max(source.minX - CGFloat(x), CGFloat(x) - source.maxX, source.minY - CGFloat(y), CGFloat(y) - source.maxY)
      let outsideTile = max(tile.minX - CGFloat(x), CGFloat(x) - tile.maxX, tile.minY - CGFloat(y), CGFloat(y) - tile.maxY)
      // A tiny OCR annotation can fill its entire sampling tile. Reaching that
      // edge is not evidence of artwork: the stroke must actually continue
      // beyond the sampled area as well as beyond the original text owner.
      if
        outside >= CGFloat(reach), outsideTile >= CGFloat(max(2, reach / 2)), owners.allSatisfy({ owner in
          max(owner.minX - CGFloat(x), CGFloat(x) - owner.maxX, owner.minY - CGFloat(y), CGFloat(y) - owner.maxY) >=
            CGFloat(reach)
        }) { return true }
      for ny in max(Int(search.minY), y - 1)...min(Int(search.maxY) - 1, y + 1) {
        for nx in max(Int(search.minX), x - 1)...min(Int(search.maxX) - 1, x + 1) {
          if nx >= x0, nx < x0 + width, ny >= y0, ny < y0 + height { continue }
          let next = ny * imageWidth + nx
          guard visited.insert(next).inserted, isForeground(nx, ny) else { continue }
          queue.append(next)
        }
      }
    }
    return false
  }

  /// Once OCR has established a pronunciation column, recover tiny disconnected
  /// glyphs on that same rail. They can be too small for another OCR pass. Never
  /// infer a new rail from arbitrary nearby artwork or erase a connected border.
  private static func missingAnnotationPatches(
    for line: OCRResult.Line,
    width: Int,
    height: Int,
    color: (Int, Int) -> Pixel
  ) -> [OverlaySourcePatch] {
    let annotations = line.replacementPatches.filter(\.isAnnotation)
    guard line.isVerticalBlock, line.verticalCharScale > 0, !annotations.isEmpty else { return [] }
    let glyph = line.verticalCharScale * CGFloat(width)
    guard glyph >= 12 else { return [] }
    let bounds = line.boundingBoxNormalized
    var patches = [OverlaySourcePatch]()
    for annotation in annotations {
      let rail = CGRect(
        x: annotation.box.minX * CGFloat(width),
        y: bounds.minY * CGFloat(height),
        width: min(glyph * 0.65, annotation.box.width * CGFloat(width)),
        height: bounds.height * CGFloat(height)
      ).integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
      guard !rail.isNull, rail.width >= 2, rail.height >= 2 else { continue }
      let x0 = Int(rail.minX)
      let y0 = Int(rail.minY)
      let w = Int(rail.width)
      let h = Int(rail.height)
      let fg = components(annotation.appearance.foreground)
      let bg = components(annotation.appearance.background)
      guard distance(fg, bg) >= 60 else { continue }
      var visited = [Bool](repeating: false, count: w * h)
      func ink(_ k: Int) -> Bool {
        let c = color(x0 + k % w, y0 + k / w)
        return distance(c, fg) < distance(c, bg) && distance(c, bg) >= 40
      }
      for start in visited.indices where !visited[start] {
        visited[start] = true
        guard ink(start) else { continue }
        var component = [start]
        var cursor = 0
        var rect = CGRect(x: start % w, y: start / w, width: 1, height: 1)
        while cursor < component.count {
          let k = component[cursor]
          let x = k % w
          let y = k / w
          cursor += 1
          for ny in max(0, y - 1)...min(h - 1, y + 1) {
            for nx in max(0, x - 1)...min(w - 1, x + 1) {
              let next = ny * w + nx
              guard !visited[next] else { continue }
              visited[next] = true
              if ink(next) {
                component.append(next)
                rect = rect.union(CGRect(x: nx, y: ny, width: 1, height: 1))
              }
            }
          }
        }
        guard
          component.count >= 3, rect.minX > 0, rect.maxX < CGFloat(w),
          rect.height <= glyph * 0.7, rect.width <= glyph * 0.6,
          CGFloat(component.count) < glyph * glyph * 0.25
        else { continue }
        let box = CGRect(
          x: (CGFloat(x0) + rect.minX) / CGFloat(width),
          y: (CGFloat(y0) + rect.minY) / CGFloat(height),
          width: rect.width / CGFloat(width),
          height: rect.height / CGFloat(height)
        )
        guard !(annotations + patches).contains(where: { $0.box.contains(CGPoint(x: box.midX, y: box.midY)) }) else { continue }
        patches.append(.init(box: box, appearance: annotation.appearance, isAnnotation: true))
        if patches.count >= 64 { return patches }
      }
    }
    return patches
  }

  private static func components(_ c: OverlayColor) -> Pixel {
    Pixel(
      r: Int(c.red * 255),
      g: Int(c.green * 255),
      b: Int(c.blue * 255)
    )
  }

  private static func distance(_ a: Pixel, _ b: Pixel) -> Int {
    max(abs(a.r - b.r), abs(a.g - b.g), abs(a.b - b.b))
  }
}
