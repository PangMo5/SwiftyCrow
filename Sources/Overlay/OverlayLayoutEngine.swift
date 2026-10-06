// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - OverlayTextAlignment

enum OverlayTextAlignment: Equatable, Sendable {
  case leading
  case center
  case trailing
}

// MARK: - OverlayPlacement

struct OverlayPlacement: Equatable, Identifiable, Sendable {
  let line: OverlayLine
  let flow: OverlayTextFlow
  /// The exact OCR source region whose pixels are being replaced.
  let sourceFrame: CGRect
  /// Unrotated text-layout coordinates, centered on the physical container.
  let frame: CGRect
  /// Hard boundary that replacement text must never cross.
  let placementBounds: CGRect
  let fontSize: CGFloat
  let lineHeightMultiple: CGFloat
  let alignment: OverlayTextAlignment
  var verticalWrapping = CoreTextTypesetter.VerticalWrapping.words
  var isTextLayoutComplete = true
  /// Additional target orientation; source geometry/erasure remain unchanged.
  var targetRotationRadians: CGFloat = 0
  /// Local top-left coordinates, already clipped to the chosen frame.
  var textFlowRegions = [CGRect]()

  var id: UUID {
    line.id
  }

  var rotationRadians: CGFloat {
    line.source.rotationRadians + targetRotationRadians
  }

  var transform: CGAffineTransform {
    CGAffineTransform(translationX: frame.midX, y: frame.midY)
      .rotated(by: rotationRadians).translatedBy(x: -frame.midX, y: -frame.midY)
  }

  var visualFrame: CGRect {
    frame.applying(transform)
  }
}

// MARK: - OverlayLayoutEngine

/// Fits every target inside its own original text region. Surrounding
/// whitespace, control surfaces and table cells never expand that boundary.
enum OverlayLayoutEngine {

  // MARK: Internal

  static func placements(
    for lines: [OverlayLine],
    in canvasSize: CGSize,
    prefersHorizontalTextLayout: Bool = false
  ) -> [OverlayPlacement] {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
    return lines.compactMap { line in
      proposal(for: line, among: lines, in: canvasSize, prefersHorizontalTextLayout: prefersHorizontalTextLayout)
    }.filter(\.isTextLayoutComplete)
  }

  /// An eraser belonging to a translated neighbor must not touch source that
  /// is pending, unavailable, or deliberately preserved (including separators).
  static func protectedSourceFrames(
    for lines: [OverlayLine],
    placements: [OverlayPlacement],
    in size: CGSize,
    displayScale: CGFloat
  ) -> [CGRect] {
    let scale = max(1, displayScale)
    let halo = 1 / scale
    let replaced = Set(placements.map(\.id))
    return lines.filter { !replaced.contains($0.id) }.flatMap { line in
      line.source.replacementPatches.map { patch in
        CGRect(
          x: patch.box.minX * size.width,
          y: patch.box.minY * size.height,
          width: patch.box.width * size.width,
          height: patch.box.height * size.height
        ).insetBy(dx: -halo, dy: -halo)
          .applying(CGAffineTransform(scaleX: scale, y: scale)).integral
          .applying(CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
      }
    }
  }

  /// Vector subtraction unions overlapping owners without a Canvas blend buffer.
  static func sourceProtectionPath(frames: [CGRect], in size: CGSize) -> CGPath {
    let canvas = CGPath(rect: CGRect(origin: .zero, size: size), transform: nil)
    guard !frames.isEmpty else { return canvas }
    let protected = CGMutablePath()
    protected.addRects(frames)
    return canvas.subtracting(protected, using: .winding)
  }

  static func replacementFrame(
    for patch: OverlaySourcePatch,
    sourceLayout: OverlaySourceLayout,
    sourceSurface: OverlaySourceSurface? = nil,
    in canvasSize: CGSize,
    displayScale: CGFloat
  ) -> CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
    let canvas = CGRect(origin: .zero, size: canvasSize)
    let box = (patch.renderingBox ?? patch.box).standardized
    let source = CGRect(
      x: box.minX * canvasSize.width,
      y: box.minY * canvasSize.height,
      width: max(1, box.width * canvasSize.width),
      height: max(1, box.height * canvasSize.height)
    )
    let clippingFrame = patch.clippingBox.map {
      CGRect(
        x: $0.minX * canvas.width,
        y: $0.minY * canvas.height,
        width: $0.width * canvas.width,
        height: $0.height * canvas.height
      )
    } ?? canvas
    if patch.restorationPNG != nil {
      let clipped = source.intersection(clippingFrame)
      return clipped.isNull || clipped.isEmpty ? .zero : clipped
    }
    // Vision boxes hug the strongest part of antialiased glyphs and can omit a
    // few faint edge pixels, especially around large Japanese headings. Scale
    // the restoration bleed with glyph height while keeping it tightly bounded.
    let horizontalBleed: CGFloat
    let verticalBleed: CGFloat
    switch sourceLayout {
    case .horizontal(let rows):
      horizontalBleed = max(2.5, min(14, source.height * 0.22))
      // Vision patches hug the strongest source ink. Multiline body copy needs
      // a 1–3 px halo; single-line labels still need at most one pixel for
      // faint antialiasing. Detected controls are clipped to their original
      // rounded surface later, so this cannot repaint outside their border.
      if rows == 1, let sourceSurface, sourceSurface.confidence >= 0.35 {
        let normalizedSurface = (sourceSurface.clippingBox ?? sourceSurface.box).standardized
        let surface = sourceFrame(for: normalizedSurface, canvas: canvas, safeBounds: canvas)
        let isCompact = surface.contains(CGPoint(x: source.midX, y: source.midY))
          && surface.width <= source.width * 2.2
          && surface.height <= source.height * 3
        if isCompact {
          let topGap = max(0, source.minY - surface.minY)
          let bottomGap = max(0, surface.maxY - source.maxY)
          verticalBleed = min(14, max(1, max(topGap, bottomGap)))
        } else {
          verticalBleed = min(1, source.height * 0.04)
        }
      } else {
        verticalBleed = rows > 1
          ? max(1, min(3, source.height * 0.08))
          : min(1, source.height * 0.04)
      }

    case .vertical:
      // Vertical OCR boxes often sit against speech-bubble edges. Keep their
      // old narrow bleed instead of applying the wide horizontal-title rule.
      horizontalBleed = 2.5
      verticalBleed = 2
    }
    var expanded = source.insetBy(dx: -horizontalBleed, dy: -verticalBleed)

    expanded = expanded.intersection(canvas)
    guard !expanded.isNull, !expanded.isEmpty else { return .zero }
    let scale = max(1, displayScale)
    let minimumX = floor(expanded.minX * scale) / scale
    let minimumY = floor(expanded.minY * scale) / scale
    let maximumX = ceil(expanded.maxX * scale) / scale
    let maximumY = ceil(expanded.maxY * scale) / scale
    let clipped = CGRect(
      x: minimumX,
      y: minimumY,
      width: maximumX - minimumX,
      height: maximumY - minimumY
    ).intersection(clippingFrame)
    return clipped.isNull || clipped.isEmpty ? .zero : clipped
  }

  static func sourceSurfaceFrame(
    for surface: OverlaySourceSurface,
    in canvasSize: CGSize
  ) -> CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
    let canvas = CGRect(origin: .zero, size: canvasSize)
    let safe = surface.box.standardized
    let full = (surface.clippingBox ?? surface.box).standardized
    let interpolation: CGFloat = 0.95
    let clipping = CGRect(
      x: safe.minX + (full.minX - safe.minX) * interpolation,
      y: safe.minY + (full.minY - safe.minY) * interpolation,
      width: safe.width + (full.width - safe.width) * interpolation,
      height: safe.height + (full.height - safe.height) * interpolation
    )
    return sourceFrame(for: clipping, canvas: canvas, safeBounds: canvas)
  }

  // MARK: Private

  private static let minimumFontSize: CGFloat = 4

  private static func proposal(
    for line: OverlayLine,
    among lines: [OverlayLine],
    in canvasSize: CGSize,
    prefersHorizontalTextLayout: Bool
  ) -> OverlayPlacement? {
    guard line.shouldReplaceSourcePixels else { return nil }
    let canvas = CGRect(origin: .zero, size: canvasSize)
    let context = contextBounds(of: line.source)
    let contextFrame = sourceFrame(for: context, canvas: canvas, safeBounds: canvas)
    let boundary = sourceFrame(for: line.source.box, canvas: canvas, safeBounds: contextFrame)
    guard !boundary.isNull, !boundary.isEmpty else { return nil }
    let source = sourceFrame(for: line.source.orientedBox ?? line.source.box, canvas: canvas, safeBounds: boundary)
    guard !source.isNull, !source.isEmpty else { return nil }
    let flow = line.textFlow(prefersHorizontalTextLayout: prefersHorizontalTextLayout)
    let alignment = resolvedAlignment(
      for: line,
      flow: flow,
      sourceFrame: source,
      tableCell: exclusiveTableCell(for: line, among: lines),
      canvas: canvas,
      safeBounds: contextFrame,
      among: lines
    )
    var frame = inkAlignedFrame(for: line, alignment: alignment, sourceFrame: source, canvas: canvas) ?? source
    if abs(line.source.rotationRadians) > 0.025, !line.source.isReconstructedTextRegion {
      // An oriented OCR hint is a shaping axis, not a second ownership bound.
      // The transformed glyph footprint still has to fit the original box.
      frame.origin.y = boundary.minY
      frame.size.height = boundary.height
    }
    if line.source.isReconstructedTextRegion, let surface = exclusiveSurface(for: line, among: lines) {
      let interior = sourceFrame(for: surface.box, canvas: canvas, safeBounds: source)
      if !interior.isNull, !interior.isEmpty { frame = interior }
    }
    let preferred = preferredFontSize(for: line, sourceFrame: source, canvasSize: canvasSize)
    let original = makePlacement(
      line: line,
      flow: flow,
      sourceFrame: source,
      frame: frame,
      alignment: alignment,
      preferredFontSize: preferred,
      canvasWidth: canvasSize.width,
      canvasHeight: canvasSize.height
    )
    if
      !prefersHorizontalTextLayout,
      let sideways = sidewaysLabel(original, preferred: preferred, canvasSize: canvasSize, among: lines)
    {
      return enforcingSourceBoundary(sideways, canvasSize: canvasSize)
    }
    return avoidingRetainedContent(original, canvasSize: canvasSize).map {
      enforcingSourceBoundary($0, canvasSize: canvasSize)
    }
  }

  private static func enforcingSourceBoundary(_ placement: OverlayPlacement, canvasSize: CGSize) -> OverlayPlacement {
    func contained(_ result: OverlayPlacement) -> OverlayPlacement? {
      guard result.isTextLayoutComplete else { return nil }
      let ink: [CGRect] =
        if case .horizontal = result.flow {
          HorizontalTextRenderer.paintedBounds(for: result).map { $0.applying(result.transform) }
        } else { [result.visualFrame] }
      guard !ink.isEmpty else { return nil }
      let boundary = result.placementBounds
      if ink.allSatisfy({ boundary.insetBy(dx: -0.00001, dy: -0.00001).contains($0) }) { return result }
      let footprint = ink.reduce(CGRect.null) { $0.union($1) }
      guard
        result.textFlowRegions.isEmpty, !footprint.isNull,
        footprint.width <= boundary.width, footprint.height <= boundary.height
      else { return nil }
      let dx = min(max(0, boundary.minX - footprint.minX), boundary.maxX - footprint.maxX)
      let dy = min(max(0, boundary.minY - footprint.minY), boundary.maxY - footprint.maxY)
      let moved = footprint.offsetBy(dx: dx, dy: dy)
      let obstacles = result.line.source.layoutExclusions.map {
        CGRect(
          x: $0.minX * canvasSize.width,
          y: $0.minY * canvasSize.height,
          width: $0.width * canvasSize.width,
          height: $0.height * canvasSize.height
        )
      }
      guard !obstacles.contains(where: moved.intersects) else { return nil }
      return OverlayPlacement(
        line: result.line,
        flow: result.flow,
        sourceFrame: result.sourceFrame,
        frame: result.frame.offsetBy(dx: dx, dy: dy),
        placementBounds: boundary,
        fontSize: result.fontSize,
        lineHeightMultiple: result.lineHeightMultiple,
        alignment: result.alignment,
        verticalWrapping: result.verticalWrapping,
        isTextLayoutComplete: true,
        targetRotationRadians: result.targetRotationRadians,
        textFlowRegions: result.textFlowRegions
      )
    }
    if let original = contained(placement) { return original }
    func refitted(_ font: CGFloat) -> OverlayPlacement {
      var result = makePlacement(
        line: placement.line,
        flow: placement.flow,
        sourceFrame: placement.sourceFrame,
        frame: placement.frame,
        alignment: placement.alignment,
        preferredFontSize: font,
        canvasWidth: canvasSize.width,
        canvasHeight: canvasSize.height,
        regionsOverride: placement.textFlowRegions
      )
      result.targetRotationRadians = placement.targetRotationRadians
      return result
    }
    var lower = minimumFontSize
    var upper = placement.fontSize
    guard lower <= upper, var best = contained(refitted(lower)) else {
      var failed = placement
      failed.isTextLayoutComplete = false
      return failed
    }
    for _ in 0..<12 {
      let middle = (lower + upper) / 2
      if let candidate = contained(refitted(middle)) { best = candidate
        lower = middle
      } else { upper = middle }
    }
    return best
  }

  /// A short, independently enclosed vertical label is not a paragraph. When
  /// horizontal-only scripts would lose over half their source scale, retain
  /// normal word shaping/bidi and use the container's long axis. Already
  /// readable labels keep their upright orientation.
  private static func sidewaysLabel(
    _ original: OverlayPlacement,
    preferred: CGFloat,
    canvasSize: CGSize,
    among lines: [OverlayLine]
  ) -> OverlayPlacement? {
    let source = original.line.source
    guard
      case .horizontal = original.flow,
      case .vertical(let characterScale, let progression) = source.layout,
      characterScale > 0, abs(source.rotationRadians) < 0.025,
      !source.isReconstructedTextRegion, source.textFlowRegions.isEmpty,
      exclusiveSurface(for: original.line, among: lines) != nil,
      original.fontSize < preferred * 0.5
    else { return nil }
    let glyph = characterScale * canvasSize.width
    let frame = original.frame
    guard
      frame.height >= frame.width * 2, frame.height <= glyph * 6,
      frame.width <= glyph * 1.75, original.sourceFrame.width <= glyph * 1.75
    else { return nil }
    let rotatedFrame = CGRect(
      x: frame.midX - frame.height / 2,
      y: frame.midY - frame.width / 2,
      width: frame.height,
      height: frame.width
    )
    func candidate(maximumLineCount: Int? = nil) -> OverlayPlacement? {
      var result = makePlacement(
        line: original.line,
        flow: original.flow,
        sourceFrame: original.sourceFrame,
        frame: rotatedFrame,
        alignment: .center,
        preferredFontSize: preferred,
        canvasWidth: canvasSize.width,
        canvasHeight: canvasSize.height,
        maximumLineCount: maximumLineCount
      )
      result.targetRotationRadians = progression == .rightToLeft ? .pi / 2 : -.pi / 2
      return avoidingRetainedContent(result, canvasSize: canvasSize)
    }
    guard var result = candidate() else { return nil }
    // Avoid splitting a short label into parallel columns for a marginal font
    // gain. Measure with the same styled Core Text plan used by the renderer.
    if
      HorizontalTextRenderer.plan(for: result).lines.count > 1,
      let single = candidate(maximumLineCount: 1), single.fontSize >= result.fontSize * 0.8,
      HorizontalTextRenderer.plan(for: single).lines.count == 1
    {
      result = single
    }
    return result.fontSize >= original.fontSize * 1.2 ? result : nil
  }

  /// Native cell ownership is independent of a background shared by the row.
  /// Multiple independent text owners in one cell cannot each use its full area.
  private static func exclusiveTableCell(for line: OverlayLine, among lines: [OverlayLine]) -> OCRTableCell? {
    guard
      let cell = line.source.tableCell,
      cell.box.contains(CGPoint(x: line.source.box.midX, y: line.source.box.midY))
    else { return nil }
    let coverage = cell.box.intersection(line.source.box)
    guard !coverage.isNull, coverage.width >= line.source.box.width * 0.95 else { return nil }
    let shared = lines.contains { other in
      guard other.id != line.id, other.source.recognitionContextID == line.source.recognitionContextID else { return false }
      if
        let peer = other.source.tableCell,
        peer.table == cell.table, peer.row == cell.row, peer.column == cell.column { return true }
      let box = other.source.box
      let overlap = cell.box.intersection(box)
      return !overlap.isNull && !overlap.isEmpty
    }
    return shared ? nil : cell
  }

  private static func exclusiveSurface(for line: OverlayLine, among lines: [OverlayLine]) -> OverlaySourceSurface? {
    guard let surface = line.source.surface, surface.confidence >= 0.35 else { return nil }
    let shared = lines.contains { other in
      guard other.id != line.id, other.source.recognitionContextID == line.source.recognitionContextID else { return false }
      let box = other.source.box
      let overlap = surface.box.intersection(box)
      return !overlap.isNull && box.width * box.height > 0
        && overlap.width * overlap.height / (box.width * box.height) >= 0.5
    }
    return shared ? nil : surface
  }

  /// OCR padding is not a visible alignment edge. A fully measured single row
  /// without a separate container aligns to its ink while retaining available
  /// space on the opposite side. Erasure geometry remains independent.
  private static func inkAlignedFrame(
    for line: OverlayLine,
    alignment: OverlayTextAlignment,
    sourceFrame: CGRect,
    canvas: CGRect
  ) -> CGRect? {
    guard
      case .horizontal = line.source.layout,
      !line.source.isReconstructedTextRegion,
      abs(line.source.rotationRadians) <= 0.025, !line.source.styleRuns.isEmpty
    else { return nil }
    let text = line.source.text as NSString
    var cursor = 0
    var ink = CGRect.null
    for run in line.source.styleRuns.sorted(by: { $0.range.location < $1.range.location }) {
      guard
        run.range.location >= 0, NSMaxRange(run.range) <= text.length,
        let observed = run.inkBox, !observed.isNull, !observed.isEmpty
      else { return nil }
      if
        run.range.location > cursor,
        !text.substring(with: NSRange(location: cursor, length: run.range.location - cursor))
          .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
      cursor = max(cursor, NSMaxRange(run.range))
      ink = ink.union(observed)
    }
    guard text.substring(from: cursor).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    let left = max(sourceFrame.minX, ink.minX * canvas.width)
    let right = min(sourceFrame.maxX, ink.maxX * canvas.width)
    guard right - left >= sourceFrame.width * 0.6 else { return nil }
    // Range boxes may include a neighboring icon or loose OCR padding. Keep
    // the visible reading edge; only centered text needs both ink edges.
    let minimumX = alignment == .trailing ? sourceFrame.minX : left
    let maximumX = alignment == .leading ? sourceFrame.maxX : right
    // The measured ink anchors the row, while the original observation still
    // supplies its fitting height. A target script's taller glyphs must not be
    // shrunk to the source alphabet's cap height. Final paint stays in its owner.
    let singleRow = line.source.layout == .horizontal(rows: 1)
    let centerY = singleRow ? min(sourceFrame.maxY, max(sourceFrame.minY, ink.midY * canvas.height)) : sourceFrame.midY
    return CGRect(
      x: minimumX,
      y: centerY - sourceFrame.height / 2,
      width: maximumX - minimumX,
      height: sourceFrame.height
    )
  }

  private static func avoidingRetainedContent(_ placement: OverlayPlacement, canvasSize: CGSize) -> OverlayPlacement? {
    let source = placement.line.source
    guard !source.layoutExclusions.isEmpty else { return placement }
    let transform = placement.transform
    let inverse = transform.inverted()
    func pixels(_ box: CGRect) -> CGRect {
      CGRect(
        x: box.minX * canvasSize.width,
        y: box.minY * canvasSize.height,
        width: box.width * canvasSize.width,
        height: box.height * canvasSize.height
      )
    }
    let exclusions = source.layoutExclusions.map { pixels($0).applying(inverse) }
      .filter { $0.intersects(placement.frame) }
    guard !exclusions.isEmpty else { return placement }
    let ink: [CGRect] =
      if case .horizontal = placement.flow {
        HorizontalTextRenderer.paintedBounds(for: placement)
      } else { [placement.frame] }
    guard ink.contains(where: { bounds in exclusions.contains { $0.intersects(bounds) } }) else { return placement }
    let allowed = source.textFlowRegions.map { pixels($0).applying(inverse) }
    guard
      let clear = OverlayLayoutExclusions.largestRectangle(
        in: placement.frame,
        excluding: exclusions,
        allowed: allowed,
        alignment: placement.alignment
      )
    else { return nil }
    let translatedCenter = CGPoint(x: clear.midX, y: clear.midY).applying(transform)
    let frame = CGRect(
      x: translatedCenter.x - clear.width / 2,
      y: translatedCenter.y - clear.height / 2,
      width: clear.width,
      height: clear.height
    )
    var result = makePlacement(
      line: placement.line,
      flow: placement.flow,
      sourceFrame: placement.sourceFrame,
      frame: frame,
      alignment: placement.alignment,
      preferredFontSize: placement.fontSize,
      canvasWidth: canvasSize.width,
      canvasHeight: canvasSize.height,
      regionsOverride: []
    )
    result.targetRotationRadians = placement.targetRotationRadians
    return result
  }

  private static func makePlacement(
    line: OverlayLine,
    flow: OverlayTextFlow,
    sourceFrame: CGRect,
    frame: CGRect,
    alignment: OverlayTextAlignment,
    preferredFontSize: CGFloat,
    canvasWidth: CGFloat,
    canvasHeight: CGFloat,
    regionsOverride: [CGRect]? = nil,
    maximumLineCount: Int? = nil
  ) -> OverlayPlacement {
    let regions = regionsOverride ?? line.source.textFlowRegions.map {
      CGRect(
        x: $0.minX * canvasWidth - frame.minX,
        y: $0.minY * canvasHeight - frame.minY,
        width: $0.width * canvasWidth,
        height: $0.height * canvasHeight
      )
      .intersection(CGRect(origin: .zero, size: frame.size))
    }.filter { !$0.isNull && !$0.isEmpty }
    let lineHeightMultiple = horizontalLineHeightMultiple(
      for: line,
      flow: flow,
      preferredFontSize: preferredFontSize,
      canvasHeight: canvasHeight
    )
    let fittedPreferred: CGFloat =
      switch flow {
      case .horizontal where line.displayedStyleRuns.contains(where: { $0.sourceFragment != nil }):
        preferredFontSize

      case .horizontal:
        CoreTextTypesetter.horizontalWordFittedFontSize(
          text: line.displayedText,
          language: line.displayedLanguage,
          constrainedToWidth: frame.width,
          preferred: preferredFontSize,
          minimum: minimumFontSize,
          fontWeight: line.source.appearance.fontWeight,
          fontDesign: line.source.appearance.fontDesign,
          isItalic: line.source.appearance.isItalic
        )

      case .vertical:
        preferredFontSize
      }
    let fitted: CoreTextTypesetter.FittedLayout =
      if case .horizontal = flow {
        HorizontalTextRenderer.fittedLayout(
          line: line,
          in: frame.size,
          preferred: fittedPreferred,
          lineHeightMultiple: lineHeightMultiple,
          regions: regions,
          alignment: alignment,
          maximumLineCount: maximumLineCount,
          inlineDirection: flow.inlineDirection
        )
      } else {
        CoreTextTypesetter.fittedLayout(
          text: line.displayedText,
          language: line.displayedLanguage,
          flow: flow,
          fontWeight: line.source.appearance.fontWeight,
          fontDesign: line.source.appearance.fontDesign,
          isItalic: line.source.appearance.isItalic,
          constrainedTo: frame.size,
          preferred: fittedPreferred,
          minimum: minimumFontSize,
          lineHeightMultiple: lineHeightMultiple,
          styles: line.displayedStyleRuns,
          isUnderlined: line.source.appearance.isUnderlined
        )
      }

    return OverlayPlacement(
      line: line,
      flow: flow,
      sourceFrame: sourceFrame,
      frame: frame,
      placementBounds: Self.sourceFrame(
        for: line.source.box,
        canvas: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight),
        safeBounds: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight)
      ),
      fontSize: fitted.fontSize,
      lineHeightMultiple: lineHeightMultiple,
      alignment: alignment,
      verticalWrapping: fitted.verticalWrapping,
      isTextLayoutComplete: fitted.isComplete,
      textFlowRegions: regions
    )
  }

  private static func horizontalLineHeightMultiple(
    for line: OverlayLine,
    flow: OverlayTextFlow,
    preferredFontSize: CGFloat,
    canvasHeight: CGFloat
  ) -> CGFloat {
    guard
      case .horizontal = flow,
      case .horizontal(let rows) = line.source.layout,
      rows > 1,
      line.source.horizontalLineAdvanceScale > 0,
      canvasHeight > 0
    else { return 1 }

    let naturalLineHeight = CoreTextTypesetter.lineHeight(
      fontSize: preferredFontSize,
      language: line.displayedLanguage,
      fontWeight: line.source.appearance.fontWeight,
      fontDesign: line.source.appearance.fontDesign,
      isItalic: line.source.appearance.isItalic
    )
    guard naturalLineHeight > 0 else { return 1 }
    let sourceLineAdvance = line.source.horizontalLineAdvanceScale * canvasHeight
    return min(1.6, max(1, sourceLineAdvance / naturalLineHeight))
  }

  private static func preferredFontSize(
    for line: OverlayLine,
    sourceFrame: CGRect,
    canvasSize: CGSize
  ) -> CGFloat {
    let raw: CGFloat =
      switch line.source.layout {
      case .horizontal(let rows):
        preferredHorizontalFontSize(
          for: line,
          rows: rows,
          sourceFrame: sourceFrame,
          canvasSize: canvasSize
        )

      case .vertical(let characterScale, _):
        characterScale > 0
          ? characterScale * canvasSize.width * 0.92
          : min(sourceFrame.width * 0.72, sourceFrame.height * 0.2)
      }
    // The source frame remains the hard fitting boundary, so a fixed 72 pt cap
    // only makes large hero text artificially small. Keep a canvas-relative
    // sanity bound and let Core Text choose the largest size that really fits.
    let context = contextBounds(of: line.source)
    let canvasRelativeMaximum = max(72, min(canvasSize.width * context.width, canvasSize.height * context.height) * 0.22)
    return max(8, min(canvasRelativeMaximum, raw))
  }

  private static func resolvedAlignment(
    for line: OverlayLine,
    flow: OverlayTextFlow,
    sourceFrame: CGRect,
    tableCell: OCRTableCell?,
    canvas: CGRect,
    safeBounds: CGRect,
    among lines: [OverlayLine]
  ) -> OverlayTextAlignment {
    if line.source.isReconstructedTextRegion { return .center }
    switch flow {
    case .vertical:
      return .center

    case .horizontal(let direction):
      guard case .horizontal(let rows) = line.source.layout else { return .center }
      if OCRTextSemantics.beginsListItem(line.source.text) {
        return direction == .rightToLeft ? .trailing : .leading
      }
      if rows > 1, let measured = line.source.rowAlignment { return measured }
      // Writing direction shapes the target glyphs; physical alignment belongs
      // to the captured layout, including a single row with no native hint.
      let defaultAlignment: OverlayTextAlignment = line.source.language.characterDirection == .rightToLeft ? .trailing : .leading
      // Equal or conflicting physical rows cannot support the native hint.
      // Preserve the source reading edge when geometry is genuinely ambiguous;
      // missing row geometry still allows a native alignment hint below.
      if rows > 1, line.source.rowAlignmentEvidence == .ambiguous { return defaultAlignment }
      let fallback = line.source.alignment ?? defaultAlignment
      if
        rows == 1, line.source.alignment != nil,
        hasAdjacentPreservedAccessory(for: line, alignment: fallback, among: lines) { return fallback }
      let preservesLeadingAccessory = fallback == .leading
        && hasLeadingAccessoryIndent(for: line, among: lines)
      let neighboring = preservesLeadingAccessory
        ? .leading
        : neighboringBlockAlignment(for: line, among: lines)

      if rows > 1 {
        // A neighboring indented quote or the screen edge does not change a
        // paragraph's own edge alignment. Center hints may still be corrected
        // by repeated leading/trailing neighbors when its rows are ambiguous.
        if line.source.alignment == .leading || line.source.alignment == .trailing { return fallback }
        return neighboring == .center ? fallback : neighboring ?? fallback
      }

      if tableCell == nil, isIsolatedCenteredHeading(line, among: lines) { return .center }

      if let cell = tableCell {
        if let alignment = tableColumnAlignment(for: line, cell: cell, among: lines, canvas: canvas) { return alignment }
        let bounds = self.sourceFrame(for: cell.box, canvas: canvas, safeBounds: safeBounds)
        if geometricAlignment(of: sourceFrame, inside: bounds) == .center { return .center }
      }

      if let surface = line.source.surface, surface.confidence >= 0.35 {
        let surfaceFrame = self.sourceFrame(
          for: surface.box,
          canvas: canvas,
          safeBounds: safeBounds
        )
        if surfaceFrame.contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)) {
          // Geometry is strong evidence for compact controls because their
          // surface is the actual text container. A card is different: OCR
          // bounds hug the rendered glyphs, so a leading paragraph can look
          // accidentally centered inside the much larger card. Preserve
          // Vision's paragraph alignment for those non-compact surfaces.
          guard rows == 1, isCompactSurface(surfaceFrame, around: sourceFrame) else {
            return neighboring ?? fallback
          }
          if let local = geometricAlignment(of: sourceFrame, inside: surfaceFrame) {
            return local
          }
        }
      }
      return neighboring ?? pageAlignment(
        sourceFrame: sourceFrame,
        safeBounds: safeBounds,
        canvasWidth: canvas.width * contextBounds(of: line.source).width
      ) ?? fallback
    }
  }

  /// One large isolated heading supplies hierarchy evidence as well as equal
  /// physical margins. A merely centered OCR rectangle is insufficient.
  private static func isIsolatedCenteredHeading(_ line: OverlayLine, among lines: [OverlayLine]) -> Bool {
    let source = line.source
    let context = contextBounds(of: source)
    let size = source.appearance.fontSizeScale
    guard
      size > 0, source.appearance.confidence >= 0.35,
      source.appearance.fontWeight.rawValue >= OverlayFontWeight.semibold.rawValue,
      source.alignment == nil || source.alignment == .center,
      abs(source.rotationRadians) < 0.025,
      source.box.width < context.width * 0.7,
      abs(source.box.midX - context.midX) * source.imageAspectRatio <= size * 0.4
    else { return false }
    let neighbors = lines.filter { other in
      other.id != line.id && other.source.recognitionContextID == source.recognitionContextID
        && other.source.appearance.fontSizeScale > 0 && !other.source.isProtectedLiteral
        && abs(other.source.box.midY - source.box.midY) <= source.box.height * 5
    }
    return neighbors.count >= 2 && neighbors.allSatisfy { other in
      abs(other.source.box.midY - source.box.midY) >= source.box.height
        && other.source.appearance.fontSizeScale * 1.15 <= size
    }
  }

  /// A native edge hint plus a separate preserved marker establishes the label
  /// anchor. A neighboring row that includes its marker has a different center
  /// and must not recenter this label onto its radio button or bullet.
  private static func hasAdjacentPreservedAccessory(
    for line: OverlayLine,
    alignment: OverlayTextAlignment,
    among lines: [OverlayLine]
  ) -> Bool {
    guard alignment != .center, abs(line.source.rotationRadians) < 0.025 else { return false }
    let source = contextBox(of: line.source)
    let context = contextBounds(of: line.source)
    let aspect = line.source.imageAspectRatio * context.width / context.height
    guard source.height > 0, aspect > 0 else { return false }
    return lines.contains { other in
      guard
        other.id != line.id, other.source.preservesSource, abs(other.source.rotationRadians) < 0.025,
        other.source.recognitionContextID == line.source.recognitionContextID,
        case .horizontal(let rows) = other.source.layout, rows == 1
      else { return false }
      let box = contextBox(of: other.source)
      let overlap = min(source.maxY, box.maxY) - max(source.minY, box.minY)
      let gap = alignment == .leading ? source.minX - box.maxX : box.minX - source.maxX
      return box.width > 0 && box.height > 0
        && box.width * aspect <= source.height * 2 && box.height <= source.height * 2
        && overlap >= min(source.height, box.height) * 0.6
        && gap >= 0 && gap * aspect <= source.height * 0.75
    }
  }

  private static func neighboringBlockAlignment(
    for line: OverlayLine,
    among lines: [OverlayLine]
  ) -> OverlayTextAlignment? {
    let source = contextBox(of: line.source)
    let sourceRowScale = horizontalRowScale(of: line.source)
    let evidence = lines.compactMap { candidate -> OverlayTextAlignment? in
      guard
        candidate.id != line.id,
        candidate.source.recognitionContextID == line.source.recognitionContextID,
        case .horizontal = candidate.source.layout
      else { return nil }
      let other = contextBox(of: candidate.source)
      guard source.width > 0, source.height > 0, other.width > 0, other.height > 0 else {
        return nil
      }

      let intersection = source.intersection(other)
      let verticalOverlap = intersection.isNull ? 0 : intersection.height
      guard verticalOverlap / min(source.height, other.height) <= 0.25 else { return nil }

      let verticalGap = max(
        0,
        max(source.minY, other.minY) - min(source.maxY, other.maxY)
      )
      let rowScale = max(sourceRowScale, horizontalRowScale(of: candidate.source))
      let maximumGap = min(0.08, max(0.02, rowScale * 2.5))
      guard verticalGap <= maximumGap else { return nil }

      let horizontalOverlap = max(0, min(source.maxX, other.maxX) - max(source.minX, other.minX))
      guard horizontalOverlap / min(source.width, other.width) >= 0.55 else { return nil }

      let tolerance = max(0.003, min(0.018, rowScale * 0.55))
      let scores: [(alignment: OverlayTextAlignment, distance: CGFloat)] = [
        (.leading, abs(source.minX - other.minX)),
        (.center, abs(source.midX - other.midX)),
        (.trailing, abs(source.maxX - other.maxX)),
      ].sorted { $0.distance < $1.distance }
      guard
        let best = scores.first,
        best.distance <= tolerance,
        scores.count < 2 || scores[1].distance - best.distance >= max(0.003, tolerance * 0.4)
      else { return nil }
      return best.alignment
    }

    guard !evidence.isEmpty else { return nil }
    let ranked = [OverlayTextAlignment.leading, .center, .trailing]
      .map { alignment in
        (alignment: alignment, count: evidence.count { $0 == alignment })
      }
      .filter { $0.count > 0 }
      .sorted { $0.count > $1.count }
    guard
      let best = ranked.first,
      ranked.count < 2 || best.count > ranked[1].count
    else { return nil }
    return best.alignment
  }

  private static func hasLeadingAccessoryIndent(
    for line: OverlayLine,
    among lines: [OverlayLine]
  ) -> Bool {
    guard
      line.source.alignment == nil,
      case .horizontal(let rows) = line.source.layout,
      rows == 1
    else { return false }
    let source = contextBox(of: line.source)
    guard source.width > 0, source.height > 0, source.width <= 0.25 else { return false }
    let sourceRowScale = horizontalRowScale(of: line.source)
    let nearby = lines.compactMap { candidate -> CGRect? in
      guard
        candidate.id != line.id,
        candidate.source.recognitionContextID == line.source.recognitionContextID,
        case .horizontal = candidate.source.layout
      else { return nil }
      let other = contextBox(of: candidate.source)
      guard other.width > 0, other.height > 0 else { return nil }

      let intersection = source.intersection(other)
      let verticalOverlap = intersection.isNull ? 0 : intersection.height
      guard verticalOverlap / min(source.height, other.height) <= 0.25 else { return nil }
      let verticalGap = max(
        0,
        max(source.minY, other.minY) - min(source.maxY, other.maxY)
      )
      let rowScale = max(sourceRowScale, horizontalRowScale(of: candidate.source))
      let maximumGap = min(0.08, max(0.02, rowScale * 2.5))
      guard verticalGap <= maximumGap else { return nil }

      let horizontalOverlap = max(0, min(source.maxX, other.maxX) - max(source.minX, other.minX))
      guard horizontalOverlap / min(source.width, other.width) >= 0.55 else { return nil }
      return other
    }
    let above = nearby.filter { $0.midY < source.midY }
    let below = nearby.filter { $0.midY > source.midY }

    for upper in above {
      for lower in below {
        let rowScale = max(sourceRowScale, max(upper.height, lower.height))
        let edgeTolerance = max(0.003, min(0.018, rowScale * 0.55))
        guard abs(upper.minX - lower.minX) <= edgeTolerance else { continue }
        let commonLeadingEdge = (upper.minX + lower.minX) / 2
        let leadingIndent = source.minX - commonLeadingEdge
        guard
          leadingIndent >= max(0.006, sourceRowScale * 0.75),
          leadingIndent <= min(0.08, sourceRowScale * 3),
          source.width <= max(upper.width, lower.width) * 0.8,
          max(upper.maxX, lower.maxX) - source.maxX >= max(0.01, sourceRowScale * 2)
        else { continue }
        return true
      }
    }
    return false
  }

  private static func horizontalRowScale(of source: OverlayLine.Source) -> CGFloat {
    guard case .horizontal(let rows) = source.layout else { return 0 }
    return max(source.horizontalGlyphScale, source.box.height / CGFloat(max(1, rows))) / contextBounds(of: source).height
  }

  private static func contextBounds(of source: OverlayLine.Source) -> CGRect {
    source.recognitionContextBounds ?? CGRect(x: 0, y: 0, width: 1, height: 1)
  }

  /// Neighbor heuristics use the original input's coordinate system. Empty
  /// margins and a different neighboring page cannot change those distances.
  private static func contextBox(of source: OverlayLine.Source) -> CGRect {
    let context = contextBounds(of: source)
    let box = source.box.standardized
    return CGRect(
      x: (box.minX - context.minX) / context.width,
      y: (box.minY - context.minY) / context.height,
      width: box.width / context.width,
      height: box.height / context.height
    )
  }

  /// Native cell estimates do not establish text alignment. Unequal-width
  /// labels in the same observed column supply the physical reading edge.
  private static func tableColumnAlignment(
    for line: OverlayLine,
    cell: OCRTableCell,
    among lines: [OverlayLine],
    canvas: CGRect
  ) -> OverlayTextAlignment? {
    let peers = lines.filter {
      guard let owner = $0.source.tableCell, case .horizontal(rows: 1) = $0.source.layout else { return false }
      return owner.table == cell.table && owner.column == cell.column && owner.columnSpan == 1
        && owner.rowSpan == 1 && abs($0.source.rotationRadians) < 0.025
    }
    guard Set(peers.compactMap(\.source.tableCell?.row)).count >= 3 else { return nil }
    let boxes = peers.map { sourceFrame(for: $0.source.box, canvas: canvas, safeBounds: canvas) }
    let tolerance = max(2, line.source.box.height * canvas.height * 0.35)
    func spread(_ values: [CGFloat]) -> CGFloat {
      (values.max() ?? 0) - (values.min() ?? 0)
    }
    guard spread(boxes.map(\.width)) > tolerance * 2 else { return nil }
    let scores: [(OverlayTextAlignment, CGFloat)] = [
      (.leading, spread(boxes.map(\.minX))),
      (.center, spread(boxes.map(\.midX))),
      (.trailing, spread(boxes.map(\.maxX))),
    ].sorted { $0.1 < $1.1 }
    guard scores[0].1 <= tolerance, scores[1].1 - scores[0].1 >= tolerance * 0.5 else { return nil }
    return scores[0].0
  }

  private static func geometricAlignment(
    of sourceFrame: CGRect,
    inside containerFrame: CGRect
  ) -> OverlayTextAlignment? {
    let source = sourceFrame.standardized
    let container = containerFrame.standardized
    guard container.width > 0, container.contains(CGPoint(x: source.midX, y: source.midY)) else {
      return nil
    }

    let leadingMargin = max(0, source.minX - container.minX)
    let trailingMargin = max(0, container.maxX - source.maxX)
    if abs(source.midX - container.midX) <= max(2, container.width * 0.06) {
      return .center
    }

    let edgeTolerance = max(2, min(source.height * 0.8, container.width * 0.12))
    if leadingMargin <= edgeTolerance, trailingMargin > leadingMargin + edgeTolerance {
      return .leading
    }
    if trailingMargin <= edgeTolerance, leadingMargin > trailingMargin + edgeTolerance {
      return .trailing
    }
    return nil
  }

  private static func isCompactSurface(
    _ surfaceFrame: CGRect,
    around sourceFrame: CGRect
  ) -> Bool {
    surfaceFrame.width <= sourceFrame.width * 2.2
      && surfaceFrame.height <= sourceFrame.height * 3
  }

  private static func pageAlignment(
    sourceFrame: CGRect,
    safeBounds: CGRect,
    canvasWidth: CGFloat
  ) -> OverlayTextAlignment? {
    // A wide OCR box centered on the page is not evidence of centered text:
    // full-width search results and article rows have the same geometry. Center
    // alignment must come from Vision, a detected surface, or neighboring rows
    // that share a clear midpoint. Page geometry is reliable only at its edges.
    let edgeTolerance = max(4, canvasWidth * 0.025)
    if sourceFrame.minX <= safeBounds.minX + edgeTolerance {
      return .leading
    }
    if sourceFrame.maxX >= safeBounds.maxX - edgeTolerance {
      return .trailing
    }
    return nil
  }

  private static func preferredHorizontalFontSize(
    for line: OverlayLine,
    rows: Int,
    sourceFrame: CGRect,
    canvasSize: CGSize
  ) -> CGFloat {
    if line.source.appearance.fontSizeScale > 0 {
      return line.source.appearance.fontSizeScale * canvasSize.height
    }
    let boxScale = line.source.horizontalGlyphScale > 0
      ? line.source.horizontalGlyphScale
      : sourceFrame.height / CGFloat(max(1, rows)) / canvasSize.height
    // Weight changes stroke thickness, not point size.
    let boxBasedSize = boxScale * canvasSize.height * (line.source.isReconstructedTextRegion ? 1.2 : 0.94)
    // Vision line boxes can include icons, controls, or Japanese ruby. Whenever
    // pixel ink shows that inflation clearly, cap the estimate for every source
    // scale rather than only large controls.
    guard line.source.horizontalInkScale > 0 else { return boxBasedSize }
    let inflationRatio = boxScale / line.source.horizontalInkScale
    guard inflationRatio >= 1.7 else { return boxBasedSize }

    if
      line.source.language.languageCode?.identifier == "ja",
      case .horizontal(let rows) = line.source.layout,
      rows > 1,
      inflationRatio >= 2.4
    {
      // Japanese school material often includes furigana inside every Vision
      // row box. Pixel ink sees only the thin strokes while the box includes
      // both ruby and base glyphs, so the generic icon cap makes body text tiny.
      // The base glyph occupies roughly the lower half of that Apple-provided
      // row geometry; Core Text still performs the final fit inside the frame.
      let rubyAwareSize = boxScale * canvasSize.height * 0.54
      let inkBasedSize = line.source.horizontalInkScale * canvasSize.height * 1.3
      return min(boxBasedSize, max(inkBasedSize, rubyAwareSize))
    }
    if rows > 1 {
      if boxBasedSize <= 32 {
        // Small table/list copy can use a line-height-like Vision box while
        // low-contrast ink captures only its darkest center. Blend those two
        // bounds instead of trusting either extreme.
        let inkBasedSize = line.source.horizontalInkScale * canvasSize.height * 2.4
        return min(boxBasedSize, max(boxBasedSize * 0.76, inkBasedSize))
      }
      // A multiline paragraph supplies independent row geometry, so its
      // per-row Vision box is a better point-size estimate than the darkest
      // antialiased ink pixels. The ink cap is for single-line controls whose
      // box may include an icon; applying it to body copy made 32pt source text
      // render around 24pt despite ample room in the original frame.
      return boxBasedSize
    }
    // On small, low-contrast single-line copy, thresholded foreground ink can
    // cover only the darkest core of each antialiased glyph. Reserve the ink
    // cap for genuinely inflated observations such as an icon and label
    // reported inside one large control row.
    guard boxBasedSize > 32 else { return boxBasedSize }
    return min(boxBasedSize, line.source.horizontalInkScale * canvasSize.height * 1.3)
  }

  private static func sourceFrame(
    for normalizedBox: CGRect,
    canvas: CGRect,
    safeBounds: CGRect
  ) -> CGRect {
    let box = normalizedBox.standardized
    let raw = CGRect(
      x: box.minX * canvas.width,
      y: box.minY * canvas.height,
      width: max(1, box.width * canvas.width),
      height: max(1, box.height * canvas.height)
    )
    return raw.intersection(safeBounds).intersection(canvas)
  }

}
