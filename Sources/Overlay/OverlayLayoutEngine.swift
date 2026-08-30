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
  /// The original visual container used for translated text.
  let frame: CGRect
  /// Hard boundary that replacement text must never cross.
  let placementBounds: CGRect
  let fontSize: CGFloat
  let lineLimit: Int?
  let alignment: OverlayTextAlignment

  var id: UUID {
    line.id
  }
}

// MARK: - OverlayLayoutEngine

/// Keeps every translation inside its original visual container. Horizontal
/// source text uses its OCR frame; a horizontal translation replacing vertical
/// source text may use the detected speech bubble or panel. If the translated
/// string needs more room, Core Text reduces its font instead of moving or
/// expanding into neighboring content.
enum OverlayLayoutEngine {

  // MARK: Internal

  static func placements(
    for lines: [OverlayLine],
    in canvasSize: CGSize,
    prefersHorizontalTextLayout: Bool = false
  ) -> [OverlayPlacement] {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
    let canvas = CGRect(origin: .zero, size: canvasSize)
    let safeBounds = canvasSize.width > 8 && canvasSize.height > 8
      ? canvas.insetBy(dx: 4, dy: 4)
      : canvas

    return lines.compactMap { line in
      // Pending, same-language, unavailable, and deliberately preserved metadata
      // stay as untouched source pixels.
      guard line.translatedText != nil else { return nil }
      let sourceFrame = sourceFrame(
        for: line.source.box,
        canvas: canvas,
        safeBounds: safeBounds
      )
      let flow = line.textFlow(prefersHorizontalTextLayout: prefersHorizontalTextLayout)
      let alignment = resolvedAlignment(
        for: line,
        flow: flow,
        sourceFrame: sourceFrame,
        canvas: canvas,
        safeBounds: safeBounds,
        among: lines
      )
      let frame = originalContainerFrame(
        for: line,
        flow: flow,
        alignment: alignment,
        sourceFrame: sourceFrame,
        canvas: canvas,
        safeBounds: safeBounds
      )
      return makePlacement(
        line: line,
        flow: flow,
        sourceFrame: sourceFrame,
        frame: frame,
        alignment: alignment,
        preferredFontSize: preferredFontSize(
          for: line,
          sourceFrame: sourceFrame,
          canvasSize: canvasSize
        )
      )
    }
  }

  static func replacementFrame(
    for patch: OverlaySourcePatch,
    sourceLayout: OverlaySourceLayout,
    in canvasSize: CGSize,
    displayScale: CGFloat
  ) -> CGRect {
    guard canvasSize.width > 0, canvasSize.height > 0 else { return .zero }
    let canvas = CGRect(origin: .zero, size: canvasSize)
    let box = patch.box.standardized
    let source = CGRect(
      x: box.minX * canvasSize.width,
      y: box.minY * canvasSize.height,
      width: max(1, box.width * canvasSize.width),
      height: max(1, box.height * canvasSize.height)
    )
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
      verticalBleed = rows > 1
        ? max(1, min(3, source.height * 0.08))
        : min(1, source.height * 0.04)

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
    return CGRect(
      x: minimumX,
      y: minimumY,
      width: maximumX - minimumX,
      height: maximumY - minimumY
    )
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

  private static func originalContainerFrame(
    for line: OverlayLine,
    flow: OverlayTextFlow,
    alignment: OverlayTextAlignment,
    sourceFrame: CGRect,
    canvas: CGRect,
    safeBounds: CGRect
  ) -> CGRect {
    guard let surface = line.source.surface, surface.confidence >= 0.35 else {
      return sourceFrame
    }

    let surfaceFrame = self.sourceFrame(
      for: surface.box,
      canvas: canvas,
      safeBounds: safeBounds
    )
    guard surfaceFrame.contains(CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)) else {
      return sourceFrame
    }
    switch (line.source.layout, flow) {
    case (.vertical, .horizontal):
      return surfaceFrame

    case (.horizontal(let rows), .horizontal) where rows == 1:
      // Pills and buttons are compact text containers rather than whole cards.
      // Use their detected interior so longer translations retain source scale,
      // but preserve the source text's leading/trailing anchor. Starting at the
      // surface edge shifts short badge labels into their original padding.
      guard isCompactSurface(surfaceFrame, around: sourceFrame) else { return sourceFrame }
      return compactFrame(
        inside: surfaceFrame,
        anchoredTo: sourceFrame,
        alignment: alignment
      )

    default:
      return sourceFrame
    }
  }

  private static func makePlacement(
    line: OverlayLine,
    flow: OverlayTextFlow,
    sourceFrame: CGRect,
    frame: CGRect,
    alignment: OverlayTextAlignment,
    preferredFontSize: CGFloat
  ) -> OverlayPlacement {
    let fittedPreferred: CGFloat =
      switch flow {
      case .horizontal:
        CoreTextTypesetter.horizontalWordFittedFontSize(
          text: line.displayedText,
          language: line.displayedLanguage,
          constrainedToWidth: frame.width,
          preferred: preferredFontSize,
          minimum: minimumFontSize,
          fontWeight: line.source.appearance.fontWeight,
          fontDesign: line.source.appearance.fontDesign
        )

      case .vertical:
        preferredFontSize
      }
    let fontSize = CoreTextTypesetter.fittedFontSize(
      text: line.displayedText,
      language: line.displayedLanguage,
      flow: flow,
      fontWeight: line.source.appearance.fontWeight,
      fontDesign: line.source.appearance.fontDesign,
      constrainedTo: frame.size,
      preferred: fittedPreferred,
      minimum: minimumFontSize
    )

    let lineLimit: Int? =
      switch flow {
      case .vertical:
        nil

      case .horizontal:
        max(
          1,
          CoreTextTypesetter.horizontalLineCount(
            text: line.displayedText,
            language: line.displayedLanguage,
            fontSize: fontSize,
            fontWeight: line.source.appearance.fontWeight,
            fontDesign: line.source.appearance.fontDesign,
            in: frame.size
          )
        )
      }
    return OverlayPlacement(
      line: line,
      flow: flow,
      sourceFrame: sourceFrame,
      frame: frame,
      placementBounds: frame,
      fontSize: fontSize,
      lineLimit: lineLimit,
      alignment: alignment
    )
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
    let canvasRelativeMaximum = max(72, min(canvasSize.width, canvasSize.height) * 0.22)
    return max(8, min(canvasRelativeMaximum, raw))
  }

  private static func compactFrame(
    inside surfaceFrame: CGRect,
    anchoredTo sourceFrame: CGRect,
    alignment: OverlayTextAlignment
  ) -> CGRect {
    let surface = surfaceFrame.standardized
    let source = sourceFrame.standardized
    let contentInset = min(surface.height * 0.22, surface.width * 0.12)
    switch alignment {
    case .leading:
      let minimumX = min(
        max(source.minX, surface.minX + contentInset),
        surface.maxX - 1
      )
      return CGRect(
        x: minimumX,
        y: surface.minY,
        width: surface.maxX - minimumX,
        height: surface.height
      )

    case .trailing:
      let maximumX = max(
        min(source.maxX, surface.maxX - contentInset),
        surface.minX + 1
      )
      return CGRect(
        x: surface.minX,
        y: surface.minY,
        width: maximumX - surface.minX,
        height: surface.height
      )

    case .center:
      return surface
    }
  }

  private static func resolvedAlignment(
    for line: OverlayLine,
    flow: OverlayTextFlow,
    sourceFrame: CGRect,
    canvas: CGRect,
    safeBounds: CGRect,
    among lines: [OverlayLine]
  ) -> OverlayTextAlignment {
    switch flow {
    case .vertical:
      return .center

    case .horizontal(let direction):
      guard case .horizontal(let rows) = line.source.layout else { return .center }
      let fallback = line.source.alignment
        ?? (direction == .rightToLeft ? .trailing : .leading)

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
            return fallback
          }
          if let local = geometricAlignment(of: sourceFrame, inside: surfaceFrame) {
            return local
          }
        }
      }
      return pageAlignment(
        of: line,
        sourceFrame: sourceFrame,
        canvas: canvas,
        safeBounds: safeBounds,
        among: lines
      ) ?? fallback
    }
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
    of line: OverlayLine,
    sourceFrame: CGRect,
    canvas: CGRect,
    safeBounds: CGRect,
    among lines: [OverlayLine]
  ) -> OverlayTextAlignment? {
    let centeredAxis = abs(sourceFrame.midX - canvas.midX) <= max(
      sourceFrame.height,
      canvas.width * 0.035
    )
    let sourceBox = line.source.box.standardized
    let hasNearbyWideCenteredSibling = lines.contains { candidate in
      guard
        candidate.id != line.id,
        candidate.source.surface == nil,
        case .horizontal = candidate.source.layout
      else { return false }
      let candidateBox = candidate.source.box.standardized
      let verticalGap = max(
        0,
        max(sourceBox.minY, candidateBox.minY) - min(sourceBox.maxY, candidateBox.maxY)
      )
      return candidateBox.width >= 0.28
        && abs(candidateBox.midX - 0.5) <= 0.035
        && abs(candidateBox.midX - sourceBox.midX) <= 0.035
        && verticalGap <= max(0.06, min(sourceBox.height * 3, 0.12))
    }
    if
      centeredAxis,
      sourceFrame.width >= canvas.width * 0.28 || hasNearbyWideCenteredSibling
    {
      return .center
    }

    let edgeTolerance = max(4, canvas.width * 0.025)
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
    let boxScale = line.source.horizontalGlyphScale > 0
      ? line.source.horizontalGlyphScale
      : sourceFrame.height / CGFloat(max(1, rows)) / canvasSize.height
    // Weight changes stroke thickness, not point size.
    let boxBasedSize = boxScale * canvasSize.height * 0.94
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
    return containedFrame(raw, in: safeBounds)
  }

  private static func containedFrame(_ frame: CGRect, in bounds: CGRect) -> CGRect {
    let width = min(max(1, frame.width), max(1, bounds.width))
    let height = min(max(1, frame.height), max(1, bounds.height))
    let x = min(max(frame.minX, bounds.minX), bounds.maxX - width)
    let y = min(max(frame.minY, bounds.minY), bounds.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }
}
