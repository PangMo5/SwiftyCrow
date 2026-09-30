// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

struct OCRDocumentRegionTests {
  @Test
  func localDetectionCannotLoseGlobalEvidenceOrClaimAnotherInput() {
    let input = OCRDocumentRegion.Input(
      bounds: CGRect(x: 100, y: 200, width: 400, height: 300),
      ownership: [CGRect(x: 100, y: 200, width: 400, height: 300)]
    )
    let global = [
      CGRect(x: 0.12, y: 0.22, width: 0.08, height: 0.02),
      CGRect(x: 0.3, y: 0.4, width: 0.1, height: 0.02),
      CGRect(x: 0.8, y: 0.4, width: 0.1, height: 0.02),
    ]
    let local = [CGRect(x: 0.05, y: 1.0 / 15, width: 0.2, height: 1.0 / 15)]
    let result = OCRDocumentRegion.detections(
      in: input,
      imageSize: CGSize(width: 1000, height: 1000),
      global: global,
      local: local
    )
    #expect(result.count == 2)
    #expect(result.first == local.first)
    #expect(result.last == CGRect(x: 0.5, y: 2.0 / 3, width: 0.25, height: 1.0 / 15))
  }

  @Test
  func detachedContentSurfacesKeepTheirWholeExtent() throws {
    let size = CGSize(width: 3424, height: 1060)
    let context = try #require(CGContext(
      data: nil,
      width: 3424,
      height: 1060,
      bitsPerComponent: 8,
      bytesPerRow: 3424 * 4,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(gray: 0.15, alpha: 1))
    context.fill(CGRect(origin: .zero, size: size))
    let pages = [CGRect(x: 400, y: 170, width: 700, height: 720), CGRect(x: 1700, y: 170, width: 900, height: 720)]
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for page in pages { context.fill(page) }
    let surfaces = OCRDocumentRegion.surfaceBounds(in: try #require(context.makeImage()))
    #expect(surfaces.count == 2)
    #expect(pages.allSatisfy { page in surfaces.contains { $0.contains(page) } })
    #expect(Set(surfaces.map(NSValue.init(rect:))) == Set(pages.map(NSValue.init(rect:))))
  }

  @Test(arguments: [
    CGRect(x: 1265, y: 174, width: 894, height: 850),
    CGRect(x: 41, y: 39, width: 1390, height: 978),
    CGRect(x: 893, y: 217, width: 731, height: 517),
  ])
  func sourceResolutionRemovesOnlyBackdropOutsideTheContent(_ page: CGRect) throws {
    let context = try #require(CGContext(
      data: nil,
      width: 3424,
      height: 1060,
      bitsPerComponent: 8,
      bytesPerRow: 3424 * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    // Use image-pixel coordinates (top-left origin), matching CGImage crops.
    context.translateBy(x: 0, y: 1060)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(red: 0.125, green: 0.125, blue: 0.125, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 3424, height: 1060))
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(page)
    let opaqueBounds = OCRDocumentRegion.surfaceBounds(in: try #require(context.makeImage()))
    #expect(opaqueBounds == [page])

    // A one-pixel fringe must survive even when it is too faint/small for
    // the low-resolution component map. Its color differs by one byte.
    let fringe = page.insetBy(dx: -1, dy: -1)
    context.setFillColor(CGColor(red: 33.0 / 255, green: 33.0 / 255, blue: 33.0 / 255, alpha: 1))
    context.fill(fringe)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(page)
    let fringeBounds = OCRDocumentRegion.surfaceBounds(in: try #require(context.makeImage()))
    #expect(fringeBounds == [fringe])
  }

  @Test
  func requestBudgetKeepsEveryDetectionAndIsIndependentOfInputOrder() {
    let rows = (0..<25).map { index in
      CGRect(x: Double(index % 5) * 0.2 + 0.04, y: Double(index / 5) * 0.2 + 0.04, width: 0.02, height: 0.01)
    }
    let size = CGSize(width: 5000, height: 5000)
    let surfaces = [CGRect(x: 400, y: 250, width: 1700, height: 4000), CGRect(x: 2700, y: 250, width: 1700, height: 4000)]
    let inputs = OCRDocumentRegion.inputs(imageSize: size, detectedText: rows, surfaceBounds: surfaces)
    #expect(inputs.count <= 4)
    #expect(inputs == OCRDocumentRegion.inputs(
      imageSize: size,
      detectedText: rows.reversed(),
      surfaceBounds: surfaces.reversed()
    ))
    for row in rows {
      let pixels = CGRect(
        x: row.minX * size.width,
        y: row.minY * size.height,
        width: row.width * size.width,
        height: row.height * size.height
      )
      #expect(inputs.contains { $0.bounds.contains(pixels) })
    }
  }

  @Test
  func nativeStructureIDsAreNamespacedAcrossRequests() {
    let a = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
    let b = CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.2)
    let cell = OCRTableCell(table: 0, row: 2, column: 3, box: b)
    let first = VisionTextRecognizer.Document(
      lines: [.init(boundingBoxNormalized: a, text: "First", recognitionGroupID: 17)],
      containers: [a],
      tableCells: [.init(table: 9, row: 1, column: 1, box: a)]
    )
    let second = VisionTextRecognizer.Document(
      lines: [.init(boundingBoxNormalized: b, text: "Second", recognitionGroupID: 3, tableCell: cell)],
      containers: [b],
      tableCells: [cell]
    )
    let combined = VisionTextRecognizer.combining(first, second)
    #expect(combined.lines.map(\.recognitionGroupID) == [17, 21])
    #expect(combined.tableCells.map(\.table) == [9, 10])
    #expect(combined.lines.last?.tableCell?.table == 10)
    #expect(combined.containers == [a, b])
    #expect(combined.lines.last?.boundingBoxNormalized == b)
  }

  @Test
  func isolatedToolbarAndDocumentHaveIndependentOwners() throws {
    let size = CGSize(width: 3424, height: 1060)
    let body = CGRect(x: 1450.0 / 3424, y: 650.0 / 1060, width: 800.0 / 3424, height: 18.0 / 1060)
    let title = CGRect(x: 330.0 / 3424, y: 40.0 / 1060, width: 400.0 / 3424, height: 28.0 / 1060)
    let inputs = OCRDocumentRegion.inputs(
      imageSize: size,
      detectedText: [body, title],
      surfaceBounds: [CGRect(x: 1300, y: 170, width: 1000, height: 880)]
    )
    let bodyOwner = try #require(OCRDocumentRegion.owner(of: body, in: inputs, imageSize: size))
    let titleOwner = try #require(OCRDocumentRegion.owner(of: title, in: inputs, imageSize: size))
    #expect(bodyOwner != titleOwner)
    #expect(inputs[bodyOwner].bounds.contains(CGRect(x: 1450, y: 650, width: 800, height: 18)))
    #expect(inputs[titleOwner].bounds.contains(CGRect(x: 330, y: 40, width: 400, height: 28)))
  }

  @Test
  func cropBudgetDependsOnProjectedGlyphResolution() {
    let rows = Array(repeating: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.018), count: 8)
    #expect(OCRDocumentRegion.needsCropping(imageSize: CGSize(width: 3424, height: 1060), detectedText: rows))
    #expect(!OCRDocumentRegion.needsCropping(imageSize: CGSize(width: 1200, height: 820), detectedText: rows))
    let large = Array(repeating: CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.07), count: 8)
    #expect(!OCRDocumentRegion.needsCropping(imageSize: CGSize(width: 3424, height: 1060), detectedText: large + rows.prefix(1)))
  }

  @Test
  func unknownTextIsNotExcludedByDetectorBlindSpots() throws {
    let size = CGSize(width: 3424, height: 1060)
    let detected = CGRect(x: 0.45, y: 0.4, width: 0.1, height: 0.02)
    let missed = CGRect(x: 0.05, y: 0.8, width: 0.1, height: 0.02)
    let inputs = OCRDocumentRegion.inputs(
      imageSize: size,
      detectedText: [detected],
      surfaceBounds: [CGRect(x: 1300, y: 200, width: 1000, height: 700)]
    )
    let owner = try #require(OCRDocumentRegion.owner(of: missed, in: inputs, imageSize: size))
    #expect(inputs[owner].bounds.contains(CGRect(x: 171.2, y: 848, width: 342.4, height: 21.2)))
    #expect(inputs.allSatisfy { input in input.ownership.allSatisfy { input.bounds.contains($0) } })
  }

  @Test
  func emptyDetectionStillReadsTheWholeCapture() {
    let canvas = CGRect(x: 0, y: 0, width: 3200, height: 1600)
    #expect(OCRDocumentRegion.inputs(imageSize: canvas.size, detectedText: []) == [.init(bounds: canvas, ownership: [canvas])])
  }

  @Test(arguments: [false, true])
  func croppedObservationsRetainAllRawSourceGeometry(_ vertical: Bool) throws {
    let local = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)
    let range = NSRange(location: 0, length: 4)
    var line = OCRResult.Line(
      boundingBoxNormalized: local,
      text: "文章ab",
      rotationRadians: 0.2,
      orientedBox: local,
      imageAspectRatio: 1600.0 / 600,
      recognitionConfidence: 0.9,
      isVerticalBlock: vertical,
      verticalCharScale: 0.125,
      horizontalGlyphScale: 0.125,
      recognitionGroupID: 7,
      replacementPatches: [.init(box: local, clippingBox: local)],
      styleRuns: [.init(range: range, box: local, inkBox: local)],
      spacingAnchors: [.init(range: range, box: local)],
      alignment: .trailing,
      tableCell: .init(table: 2, row: 3, column: 1, box: local),
      recognitionLanguages: ["ja"],
      continuesToNextLine: true
    )
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontSizeScale = 0.08
    appearance.inkHeightScale = 0.06
    line.appearance = appearance
    line.horizontalInkScale = 0.06
    line.horizontalLineAdvanceScale = 0.1
    line.layoutBounds = local
    line.textFlowRegions = [local]
    line.surface = .init(box: local, confidence: 1, clippingBox: local, cornerRadiusFraction: 0.2, clippingRows: [local])
    line.styleRuns[0].appearance = appearance
    line.replacementPatches[0].appearance = appearance
    line.replacementPatches[0].restorationPNG = Data([1, 2, 3])
    line.replacementPatches[0].renderingBox = local.insetBy(dx: -0.0625, dy: -0.0625)
    let mapped = OCRDocumentRegion.remap(
      .init(lines: [line], containers: [local], tableCells: [.init(table: 2, row: 3, column: 1, box: local)]),
      crop: CGRect(x: 800, y: 200, width: 1600, height: 600),
      imageSize: CGSize(width: 3200, height: 1600)
    )
    let result = try #require(mapped.lines.first)
    let expected = CGRect(x: 0.375, y: 0.21875, width: 0.25, height: 0.09375)
    #expect(result.boundingBoxNormalized == expected)
    #expect(result.orientedBox == expected)
    #expect(mapped.containers == [expected])
    #expect(mapped.tableCells == [.init(table: 2, row: 3, column: 1, box: expected)])
    #expect(result.tableCell == mapped.tableCells.first)
    #expect(result.recognitionLanguages == ["ja"])
    #expect(result.continuesToNextLine == true)
    #expect(OCRTableCell.containing(expected, in: mapped.tableCells) == mapped.tableCells.first)
    #expect(result.styleRuns.first?.box == expected)
    #expect(result.styleRuns.first?.inkBox == expected)
    #expect(result.styleRuns.first?.range == range)
    #expect(result.replacementPatches.first?.box == expected)
    #expect(result.replacementPatches.first?.renderingBox == expected.insetBy(dx: -0.03125, dy: -0.0234375))
    #expect(result.replacementPatches.first?.clippingBox == expected)
    #expect(result.spacingAnchors.first?.box == expected)
    #expect(result.horizontalGlyphScale == 0.046875)
    #expect(result.appearance.fontSizeScale * 1600 == appearance.fontSizeScale * 600)
    #expect(result.appearance.inkHeightScale * 1600 == appearance.inkHeightScale * 600)
    #expect(result.horizontalInkScale * 1600 == line.horizontalInkScale * 600)
    #expect(abs(result.horizontalLineAdvanceScale * 1600 - line.horizontalLineAdvanceScale * 600) < 1e-9)
    #expect(result.styleRuns[0].appearance == result.appearance)
    #expect(result.replacementPatches[0].appearance == result.appearance)
    #expect(result.replacementPatches[0].restorationPNG == Data([1, 2, 3]))
    #expect(result.layoutBounds == expected)
    #expect(result.textFlowRegions == [expected])
    #expect(result.surface == .init(
      box: expected,
      confidence: 1,
      clippingBox: expected,
      cornerRadiusFraction: 0.2,
      clippingRows: [expected]
    ))
    #expect(result.verticalCharScale == 0.0625)
    #expect(result.imageAspectRatio == 2)
    #expect(result.rotationRadians == line.rotationRadians)
    #expect(result.recognitionGroupID == 7)
    #expect(result.alignment == .trailing)
    #expect(result.isVerticalBlock == vertical)
  }
}
