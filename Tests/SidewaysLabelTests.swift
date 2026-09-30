// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Compact vertical label orientation")
struct SidewaysLabelTests {

  // MARK: Internal

  static let targets = [("ar", "كيفية الاستخدام"), ("de", "Gebrauchsand"), ("he", "אופן שימוש")]

  @Test(arguments: targets, [OverlayColumnProgression.rightToLeft, .leftToRight])
  func shortLabelsRetainShapingAndReadableScale(_ target: (String, String), _ progression: OverlayColumnProgression) throws {
    let line = Self.label(target, progression: progression)
    let source = line.source
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: Self.canvas).first)
    #expect(placement.fontSize >= 20)
    #expect(placement.rotationRadians == (progression == .rightToLeft ? .pi / 2 : -.pi / 2))
    #expect(placement.line.source == source)
    #expect(placement.line.displayedText == target.1)
    #expect(placement.flow == .horizontal(target.0 == "de" ? .leftToRight : .rightToLeft))
    let physical = CGRect(x: 98, y: 63, width: 44, height: 144)
    #expect(abs(placement.visualFrame.minX - physical.minX) < 1e-6)
    #expect(abs(placement.visualFrame.minY - physical.minY) < 1e-6)
    #expect(abs(placement.visualFrame.width - physical.width) < 1e-6)
    #expect(abs(placement.visualFrame.height - physical.height) < 1e-6)
    let plan = HorizontalTextRenderer.plan(for: placement)
    #expect(plan.fits(placement.frame.size))
    #expect(plan.lines.count == 1)
  }

  @Test(arguments: [1, 2, 3])
  func orientationAndPhysicalSizeSurviveCaptureScaling(scale: Int) throws {
    let line = Self.label(Self.targets[0])
    let small = try #require(OverlayLayoutEngine.placements(for: [line], in: Self.canvas).first)
    let large = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(
      width: Self.canvas.width * CGFloat(scale),
      height: Self.canvas.height * CGFloat(scale)
    )).first)
    #expect(large.rotationRadians == small.rotationRadians)
    // SF Arabic uses automatic optical sizing: its normalized advances change
    // with point size. Require readable scale and real ink fit, not an invalid
    // assumption that native font-point values must scale linearly.
    #expect(large.fontSize / CGFloat(scale) >= 20)
    let plan = HorizontalTextRenderer.plan(for: large)
    #expect(plan.lines.count == 1)
    #expect(plan.fits(large.frame.size))
    #expect(plan.inkBounds.width >= large.frame.width * 0.9)
    #expect(abs(large.visualFrame.width / CGFloat(scale) - small.visualFrame.width) < 1e-6)
    #expect(abs(large.visualFrame.height / CGFloat(scale) - small.visualFrame.height) < 1e-6)
  }

  @Test(arguments: targets)
  func horizontalAccessibilityPreferenceIsRespected(_ target: (String, String)) throws {
    let line = Self.label(target)
    let placement = try #require(OverlayLayoutEngine.placements(
      for: [line],
      in: Self.canvas,
      prefersHorizontalTextLayout: true
    ).first)
    #expect(placement.rotationRadians == 0)
    #expect(placement.frame.height > placement.frame.width)
  }

  @Test(arguments: targets)
  func embeddingPreservesOrientationAndPhysicalGeometry(_ target: (String, String)) throws {
    let line = Self.label(target)
    let original = try #require(OverlayLayoutEngine.placements(for: [line], in: Self.canvas).first)
    var recognized = OCRResult.Line(
      boundingBoxNormalized: line.source.box,
      text: line.source.text,
      isVerticalBlock: true,
      verticalCharScale: 0.1,
      appearance: line.source.appearance
    )
    recognized.surface = line.source.surface
    recognized.recognitionContextID = 0
    recognized.recognitionContextBounds = CGRect(x: 0, y: 0, width: 1, height: 1)
    let canvas = CGSize(width: 1_100, height: 700)
    let crop = CGRect(x: 450, y: 180, width: Self.canvas.width, height: Self.canvas.height)
    let mapped = OCRDocumentRegion.remap(.init(lines: [recognized], containers: []), crop: crop, imageSize: canvas)
    var embedded = OverlayLine(id: UUID(), source: .init(recognized: mapped.lines[0], language: .init(identifier: "ja")))
    embedded.showTranslation(target.1, language: .init(identifier: target.0))
    let placement = try #require(OverlayLayoutEngine.placements(for: [embedded], in: canvas).first)
    #expect(placement.rotationRadians == original.rotationRadians)
    #expect(abs(placement.fontSize - original.fontSize) < 1e-6)
    #expect(abs(placement.visualFrame.minX - original.visualFrame.minX - crop.minX) < 1e-6)
    #expect(abs(placement.visualFrame.minY - original.visualFrame.minY - crop.minY) < 1e-6)
    #expect(abs(placement.visualFrame.width - original.visualFrame.width) < 1e-6)
    #expect(abs(placement.visualFrame.height - original.visualFrame.height) < 1e-6)
  }

  @Test(arguments: targets)
  func retainedContentIsCheckedAfterTargetRotation(_ target: (String, String)) throws {
    var line = Self.label(target)
    let exclusion = CGRect(x: 98, y: 63, width: 44, height: 25)
    line.source.layoutExclusions = [CGRect(
      x: exclusion.minX / Self.canvas.width,
      y: exclusion.minY / Self.canvas.height,
      width: exclusion.width / Self.canvas.width,
      height: exclusion.height / Self.canvas.height
    )]
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: Self.canvas).first)
    #expect(placement.targetRotationRadians == .pi / 2)
    for ink in HorizontalTextRenderer.paintedBounds(for: placement) {
      let shared = ink.applying(placement.transform).intersection(exclusion)
      #expect(shared.isNull || shared.width * shared.height < 1e-6)
    }
    #expect(placement.line.source == line.source)
  }

  @Test(arguments: ["readable", "no surface", "shared", "long paragraph", "multiple columns", "CJK", "shaped paragraph"])
  func unrelatedContentDoesNotAcquireSidewaysOrientation(_ kind: String) throws {
    var line = Self.label(Self.targets[1])
    var lines = [OverlayLine]()
    switch kind {
    case "readable": line.showTranslation("OK", language: .init(identifier: "en"))

    case "no surface": line.source.surface = nil

    case "shared":
      var other = OverlayLine(id: UUID(), source: line.source)
      other.showTranslation("Other", language: .init(identifier: "en"))
      lines.append(other)

    case "long paragraph":
      line.source.box.size.height = 0.7
      line.source.surface?.box.size.height = 0.8
      line.source.layout = .vertical(characterScale: 0.04, progression: .rightToLeft)

    case "multiple columns": line.source.layout = .vertical(characterScale: 0.035, progression: .rightToLeft)

    case "CJK": line.showTranslation("読み方", language: .init(identifier: "ja"))

    case "shaped paragraph": line.source.isReconstructedTextRegion = true

    default: break
    }
    lines.insert(line, at: 0)
    let placement = try #require(OverlayLayoutEngine.placements(for: lines, in: Self.canvas).first)
    #expect(placement.targetRotationRadians == 0)
  }

  @Test(arguments: targets)
  @MainActor
  func exportedInkStaysInsideItsPhysicalSurface(_ target: (String, String)) throws {
    var line = Self.label(target)
    line.source.replacementPatches = []
    let width = Int(Self.canvas.width)
    let height = Int(Self.canvas.height)
    let context = try #require(CGContext(
      data: nil,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: width * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(origin: .zero, size: Self.canvas))
    let data = try #require(context.makeImage()?.pngData)
    let rendered = try #require(CaptureResultImage.render(
      imageData: data,
      imageSize: Self.canvas,
      lines: [line],
      prefersHorizontalTextLayout: false
    ))
    context.draw(rendered, in: CGRect(origin: .zero, size: Self.canvas))
    let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: width * height * 4)
    var count = 0
    var outside = 0
    let surface = CGRect(x: 98, y: 63, width: 44, height: 144)
    for y in 0..<height {
      for x in 0..<width where pixels[(y * width + x) * 4] < 128 {
        count += 1
        if !surface.contains(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)) { outside += 1 }
      }
    }
    #expect(count > 150)
    #expect(outside == 0)
  }

  // MARK: Private

  private static let canvas = CGSize(width: 400, height: 300)

  private static func label(
    _ target: (String, String),
    progression: OverlayColumnProgression = .rightToLeft
  ) -> OverlayLine {
    let box = CGRect(x: 0.25, y: 0.25, width: 0.1, height: 0.4)
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: box,
      text: "使い方",
      isVerticalBlock: true,
      verticalCharScale: 0.1,
      appearance: .init(background: .white, foreground: .black, confidence: 1)
    ), language: .init(identifier: "ja")))
    line.source.layout = .vertical(characterScale: 0.1, progression: progression)
    line.source.surface = .init(
      box: CGRect(x: 0.245, y: 0.21, width: 0.11, height: 0.48),
      confidence: 0.9,
      cornerRadiusFraction: 0.3
    )
    line.showTranslation(target.1, language: .init(identifier: target.0))
    return line
  }
}
