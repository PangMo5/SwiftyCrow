// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRLayoutRegionAllocatorTests {
  @Test
  func sourceAntialiasingDoesNotTurnRaggedTextIntoAnObstacle() {
    let boxes = [
      CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.05),
      CGRect(x: 0.3, y: 0.18, width: 0.5, height: 0.05),
      CGRect(x: 0.5, y: 0.26, width: 0.3, height: 0.05),
    ]
    let line = OCRResult.Line(
      boundingBoxNormalized: boxes.reduce(CGRect.null) { $0.union($1) },
      text: "A plain paragraph.",
      rowCount: 3,
      horizontalGlyphScale: 0.05,
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1
      ),
      styleRuns: boxes.enumerated().map { .init(
        range: NSRange(location: $0.offset, length: 1),
        box: $0.element,
        inkBox: $0.element.insetBy(dx: 0.0025, dy: 0.0025)
      ) }
    )
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: [line]), width: 400, height: 400) { x, y in
      boxes.contains { $0.contains(CGPoint(x: Double(x) / 400, y: Double(y) / 400)) } ? .black : .white
    }
    #expect(result.lines[0].textFlowRegions.isEmpty)
  }

  @Test(arguments: [false, true])
  func paragraphCorridorsFollowThePixelsBesideAFloatingFigure(_ mirrored: Bool) throws {
    let boxes = [
      CGRect(x: 0.5, y: 0.1, width: 0.35, height: 0.04),
      CGRect(x: 0.5, y: 0.17, width: 0.35, height: 0.04),
      CGRect(x: 0.3, y: 0.24, width: 0.55, height: 0.04),
      CGRect(x: 0.3, y: 0.31, width: 0.55, height: 0.04),
    ].map { box in mirrored ? CGRect(x: 1 - box.maxX, y: box.minY, width: box.width, height: box.height) : box }
    let line = OCRResult.Line(
      boundingBoxNormalized: boxes.reduce(CGRect.null) { $0.union($1) },
      text: "A wrapped paragraph around a figure.",
      rowCount: 4,
      horizontalGlyphScale: 0.04,
      appearance: .init(background: .white, foreground: .black, confidence: 1),
      styleRuns: boxes.enumerated().map { .init(range: NSRange(location: $0.offset, length: 1), box: $0.element) }
    )
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: [line]), width: 400, height: 400) { x, y in
      let x = mirrored ? 399 - x : x
      return x < 180 && y < 88 ? .black : .white
    }
    let regions = result.lines[0].textFlowRegions
    #expect(regions.count == 4)
    let first = try #require(regions.first)
    let last = try #require(regions.last)
    if mirrored {
      #expect(first.maxX <= 0.55)
      #expect(last.maxX > first.maxX + 0.1)
    } else {
      #expect(first.minX >= 0.45)
      #expect(last.minX < first.minX - 0.1)
    }
    #expect(result.lines[0].boundingBoxNormalized == line.boundingBoxNormalized)
  }

  @Test
  func liveStabilizationDoesNotRestoreAnUnverifiedOldContainer() {
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.1, height: 0.05),
      text: "Settings",
      surface: .init(box: CGRect(x: 0.05, y: 0.1, width: 0.8, height: 0.2), confidence: 1)
    )
    var previous = OverlayLine.Source(recognized: line, language: Locale.Language(identifier: "en"))
    previous.textFlowRegions = [CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.1)]
    var current = previous
    current.surface = nil
    current.textFlowRegions = []
    current.layoutBounds = CGRect(x: 0.1, y: 0.2, width: 0.12, height: 0.05)
    let stabilized = current.stabilized(relativeTo: previous, imageSize: CGSize(width: 1000, height: 800))
    #expect(stabilized.surface == nil)
    #expect(stabilized.layoutBounds == current.layoutBounds)
    #expect(stabilized.textFlowRegions == current.textFlowRegions)
  }

  @Test
  func paragraphSpaceStopsBeforeFollowingTextOrArtwork() throws {
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let paragraph = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.5, height: 0.2),
      text: "这是需要完整阅读的段落。",
      imageAspectRatio: 1,
      rowCount: 2,
      appearance: appearance
    )
    let footer = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05),
      text: "Footer",
      appearance: appearance
    )
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: [paragraph, footer]), width: 200, height: 200) { _, y in
      y == 100 ? .white : .black
    }
    let bounds = try #require(result.lines[0].layoutBounds)
    #expect(bounds.maxY == 0.5)
    #expect(bounds.maxY < footer.boundingBoxNormalized.minY)
    #expect(result.lines[0].boundingBoxNormalized == paragraph.boundingBoxNormalized)
  }

  @Test
  func subtleCardBoundaryIsNotTreatedAsEmptyCanvas() throws {
    let bg = OverlayColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.05, height: 0.2),
      text: "下载",
      imageAspectRatio: 6,
      appearance: .init(background: bg, foreground: .black, confidence: 1)
    )
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: [line]), width: 600, height: 100) { x, _ in
      x < 120 ? bg : OverlayColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1)
    }
    #expect(try #require(result.lines[0].layoutBounds).maxX <= 120.0 / 600)
  }

  @Test(arguments: [("개요", "Overview", "ko"), ("下载", "Download", "zh-Hans"), ("設定", "Settings", "ja")])
  func allocatedWhitespaceCannotEnlargeTranslatedTextRegions(_ item: (String, String, String)) throws {
    let appearance = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      fontSizeScale: 0.25,
      fontWeight: .regular
    )
    let lines = (0..<3).map { i in
      let box = CGRect(x: 0.1 + CGFloat(i) * 0.3, y: 0.2, width: 0.05, height: 0.25)
      return OCRResult.Line(
        boundingBoxNormalized: box,
        text: item.0,
        imageAspectRatio: 6,
        appearance: appearance,
        replacementPatches: [.init(box: box, appearance: appearance)],
        alignment: .leading
      )
    }
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: lines), width: 600, height: 100) { _, _ in .black }
    #expect(result.lines[0].replacementPatches == lines[0].replacementPatches)
    var translated = OverlayLine(
      id: UUID(),
      source: .init(recognized: result.lines[0], language: Locale.Language(identifier: item.2)),
      initialContent: .pending
    )
    translated.showTranslation(item.1, language: Locale.Language(identifier: "en"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [translated], in: CGSize(width: 600, height: 100)).first)
    #expect(placement.sourceFrame.contains(placement.frame))
    #expect(CaptureQualityMetrics.sourceBoundaryIssues([placement], canvas: CGSize(width: 600, height: 100)).isEmpty)
    #expect(placement.frame.maxX < lines[1].boundingBoxNormalized.minX * 600)
  }

  @Test
  func nonTextArtworkIsAnExpansionBoundary() throws {
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let lines = (0..<3).map { i in OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1 + CGFloat(i) * 0.3, y: 0.2, width: 0.05, height: 0.2),
      text: "菜单",
      imageAspectRatio: 6,
      appearance: appearance
    ) }
    let result = OCRLayoutRegionAllocator.allocating(.init(lines: lines), width: 600, height: 100) { x, _ in
      x == 110 ? .white : .black
    }
    #expect(try #require(result.lines[0].layoutBounds).maxX <= 110.0 / 600)
    #expect(result.lines[0].boundingBoxNormalized == lines[0].boundingBoxNormalized)
  }
}
