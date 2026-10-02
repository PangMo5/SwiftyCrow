// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import ImageIO

/// One deterministic compositor for capture, export and the transparent live
/// layer. Retained source is clipped out before any eraser or target ink draws.
enum OverlayRasterRenderer {

  // MARK: Internal

  @MainActor
  static func render(
    source: CGImage? = nil,
    lines: [OverlayLine],
    size: CGSize,
    scale: CGFloat = 1,
    prefersHorizontalTextLayout: Bool
  ) -> CGImage? {
    guard
      size.width > 0, size.height > 0, scale > 0, size.width.isFinite, size.height.isFinite,
      scale.isFinite
    else { return nil }
    let pixelWidth = ceil(size.width * scale)
    let pixelHeight = ceil(size.height * scale)
    guard
      pixelWidth < CGFloat(Int.max), pixelHeight < CGFloat(Int.max),
      pixelWidth * pixelHeight < CGFloat(Int.max / 4)
    else { return nil }
    let width = Int(pixelWidth)
    let height = Int(pixelHeight)
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    context.interpolationQuality = .high
    if let source { context.draw(source, in: CGRect(origin: .zero, size: size)) }
    let placements = OverlayLayoutEngine.placements(
      for: lines,
      in: size,
      prefersHorizontalTextLayout: prefersHorizontalTextLayout
    )
    let frames = OverlayLayoutEngine.protectedSourceFrames(for: lines, placements: placements, in: size, displayScale: scale)
    let allowed = OverlayLayoutEngine.sourceProtectionPath(frames: frames, in: size)
    var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height)
    guard let clip = allowed.copy(using: &flip) else { return nil }
    context.addPath(clip)
    context.clip()
    for placement in placements {
      for patch in placement.line.source.replacementPatches {
        let surface = placement.line.source.surface.flatMap { SourcePatchClipping.surface(for: patch, within: $0) }
        let frame = OverlayLayoutEngine.replacementFrame(
          for: patch,
          sourceLayout: placement.line.source.layout,
          sourceSurface: surface,
          in: size,
          displayScale: scale
        )
        context.saveGState()
        if let surface {
          let boundary = OverlayLayoutEngine.sourceSurfaceFrame(for: surface, in: size)
          if !surface.clippingRows.isEmpty {
            let path = CGMutablePath()
            for row in surface.clippingRows {
              path.addRect(bottomLeft(
                CGRect(
                  x: row.minX * size.width,
                  y: row.minY * size.height,
                  width: row.width * size.width,
                  height: row.height * size.height
                ),
                height: size.height
              ))
            }
            context.addPath(path)
            context.clip()
          } else {
            let radius = min(boundary.width, boundary.height) * surface.cornerRadiusFraction
            context.addPath(CGPath(
              roundedRect: bottomLeft(boundary, height: size.height),
              cornerWidth: radius,
              cornerHeight: radius,
              transform: nil
            ))
            context.clip()
          }
        }
        let target = bottomLeft(frame, height: size.height)
        if let png = patch.restorationPNG {
          guard let image = image(png) else { return nil }
          context.draw(image, in: target)
        } else {
          let color = patch.appearance.background
          guard
            let fill = CGColor(
              colorSpace: context.colorSpace!,
              components: [color.red, color.green, color.blue, color.alpha]
            )
          else { return nil }
          context.setFillColor(fill)
          context.fill(target)
        }
        context.restoreGState()
      }
    }
    for placement in placements {
      let glyphs: CGImage?
      switch placement.flow {
      case .horizontal:
        glyphs = HorizontalTextRenderer.image(for: placement, scale: scale)
      case .vertical(let progression):
        let appearance = placement.line.source.appearance
        glyphs = CoreTextTypesetter.verticalGlyphImage(
          text: placement.line.displayedText,
          language: placement.line.displayedLanguage,
          fontSize: placement.fontSize,
          fontWeight: appearance.fontWeight,
          fontDesign: appearance.fontDesign,
          isItalic: appearance.isItalic,
          size: placement.frame.size,
          scale: scale,
          progression: progression,
          wrapping: placement.verticalWrapping,
          foreground: appearance.foreground,
          baseBackground: appearance.background,
          styles: placement.line.displayedStyleRuns,
          isUnderlined: appearance.isUnderlined
        )
      }
      guard let glyphs else { return nil }
      context.saveGState()
      context.clip(to: bottomLeft(placement.placementBounds, height: size.height))
      context.translateBy(x: placement.frame.midX, y: size.height - placement.frame.midY)
      context.rotate(by: -placement.rotationRadians)
      let local = CGRect(
        x: -placement.frame.width / 2,
        y: -placement.frame.height / 2,
        width: placement.frame.width,
        height: placement.frame.height
      )
      context.clip(to: local)
      context.draw(glyphs, in: local)
      context.restoreGState()
    }
    return context.makeImage()
  }

  static func image(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  // MARK: Private

  private static func bottomLeft(_ rect: CGRect, height: CGFloat) -> CGRect {
    CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height)
  }

}
