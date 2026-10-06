// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Overlay layout engine")
struct OverlayLayoutEngineTests {

  // MARK: Internal

  struct EdgeCase: Sendable, CustomTestStringConvertible {
    let name: String
    let box: CGRect

    var testDescription: String {
      name
    }
  }

  struct PageAlignmentCase: Sendable, CustomTestStringConvertible {
    let name: String
    let box: CGRect
    let expected: OverlayTextAlignment

    var testDescription: String {
      name
    }
  }

  struct NeighborAlignmentCase: Sendable, CustomTestStringConvertible {
    let name: String
    let subject: CGRect
    let neighbor: CGRect
    let fallback: OverlayTextAlignment
    let expected: OverlayTextAlignment

    var testDescription: String {
      name
    }
  }

  @Test(arguments: [false, true])
  func isolatedCenteredHeadingRequiresMeasuredHierarchy(_ heading: Bool) throws {
    var title = translatedLine(
      id: lineID(1),
      box: .init(x: 0.35, y: 0.1, width: 0.3, height: 0.05),
      sourceIsVertical: false,
      text: "작업 공간 개요",
      target: "ko"
    )
    title.source.appearance.fontSizeScale = heading ? 0.05 : 0.03
    title.source.appearance.fontWeight = .semibold
    title.source.appearance.confidence = 1
    title.source.imageAspectRatio = 1
    let peers = [0.05, 0.55].enumerated().map { index, x in
      var peer = translatedLine(
        id: lineID(index + 2),
        box: .init(x: x, y: 0.22, width: 0.3, height: 0.03),
        sourceIsVertical: false,
        text: "프로젝트",
        target: "ko"
      )
      peer.source.appearance.fontSizeScale = 0.03
      return peer
    }
    let placement = try #require(OverlayLayoutEngine.placements(for: [title] + peers, in: CGSize(width: 600, height: 600))
      .first { $0.line.id == title.id })
    #expect(placement.alignment == (heading ? .center : .leading))
  }

  @Test(arguments: [OverlayTextAlignment.leading, .trailing], [CGFloat(1), 2])
  func aPreservedRowMarkerKeepsTheNativeLabelEdge(alignment: OverlayTextAlignment, scale: CGFloat) throws {
    let size = CGSize(width: 400 * scale, height: 200 * scale)
    func box(_ rect: CGRect) -> CGRect {
      let rect = alignment == .leading ? rect : CGRect(x: 400 - rect.maxX, y: rect.minY, width: rect.width, height: rect.height)
      return CGRect(x: rect.minX / 400, y: rect.minY / 200, width: rect.width / 400, height: rect.height / 200)
    }
    let language = Locale.Language(identifier: alignment == .leading ? "en" : "ar")
    var label = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: box(CGRect(x: 45, y: 30, width: 15, height: 18)),
      text: "Label",
      imageAspectRatio: 2,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.07, fontWeight: .regular),
      layoutBounds: CGRect(x: 0, y: 0.15, width: 1, height: 0.09),
      alignment: alignment
    ), language: language))
    label.showTranslation("표시", language: .init(identifier: "ko"))
    var marker = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: box(CGRect(x: 20, y: 30, width: 18, height: 18)),
      text: "〇",
      imageAspectRatio: 2,
      preservesSource: true
    ), language: language))
    let peer = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: box(CGRect(x: 20, y: 60, width: 60, height: 20)),
      text: "O next label",
      imageAspectRatio: 2
    ), language: language))
    func placement() throws -> OverlayPlacement {
      try #require(OverlayLayoutEngine.placements(for: [label, marker, peer], in: size).first)
    }
    #expect(try placement().alignment == alignment)
    marker.source.recognitionContextID = 1
    #expect(try placement().alignment == .center)
    marker.source.recognitionContextID = nil
    label.source.rotationRadians = .pi / 6
    label.source.layoutBounds = nil
    #expect(try placement().alignment == .center)
    label.source.rotationRadians = 0
    marker.source.rotationRadians = .pi / 6
    #expect(try placement().alignment == .center)
    marker.source.rotationRadians = 0
    marker.source.preservesSource = false
    #expect(try placement().alignment == .center)
  }

  @Test(arguments: [CGFloat(18), 20, 22, 24, 26, 28], [
    ("ko", "1.2. 안녕하세요, 세계!"),
    ("de", "1.2. Begrüßung der Welt"),
    ("ar", "1.2. مرحبًا بالعالم!"),
  ])
  func singleRowLabelsCannotBorrowVerifiedWhitespace(height: CGFloat, translation: (String, String)) throws {
    let size = CGSize(width: 950, height: 760)
    let preferred: CGFloat = 11.865585168
    let box = CGRect(x: 22 / size.width, y: 214 / size.height, width: 92 / size.width, height: height / size.height)
    var source = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "1.2. Hello, World!",
      imageAspectRatio: size.width / size.height,
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: preferred / size.height,
        fontWeight: .regular
      ),
      layoutBounds: CGRect(x: 0, y: box.minY, width: 205 / size.width, height: max(26, height) / size.height)
    )
    func placement(_ row: OCRResult.Line) throws -> OverlayPlacement {
      var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
      line.showTranslation(translation.1, language: .init(identifier: translation.0))
      return try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
    }
    let expanded = try placement(source)
    #expect(CaptureQualityMetrics.sourceBoundaryIssues([expanded], canvas: size).isEmpty)
    #expect(expanded.frame.maxX <= 114.001)
    #expect(expanded.isTextLayoutComplete)
    // Whitespace availability cannot change the original text boundary.
    source.layoutBounds = nil
    let bounded = try placement(source)
    #expect(bounded.frame == expanded.frame)
    #expect(bounded.fontSize == expanded.fontSize)
  }

  @Test
  func singleRowExpansionComparesTheFinalArtworkAvoidingLayout() throws {
    let size = CGSize(width: 400, height: 160)
    func box(_ rect: CGRect) -> CGRect {
      CGRect(
        x: rect.minX / size.width,
        y: rect.minY / size.height,
        width: rect.width / size.width,
        height: rect.height / size.height
      )
    }
    var source = OCRResult.Line(
      boundingBoxNormalized: box(CGRect(x: 22, y: 30, width: 92, height: 24)),
      text: "Hello world",
      imageAspectRatio: size.width / size.height,
      layoutExclusions: [box(CGRect(x: 115, y: 30, width: 267, height: 24))],
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: 12 / size.height,
        fontWeight: .regular
      )
    )
    func placement() throws -> OverlayPlacement {
      var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
      line.showTranslation("1.2. 안녕하세요, 세계!", language: .init(identifier: "ko"))
      return try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
    }
    let original = try placement()
    source.layoutBounds = box(CGRect(x: 22, y: 30, width: 360, height: 34))
    let expanded = try placement()
    #expect(expanded.fontSize >= original.fontSize)
    #expect(expanded.frame == original.frame)
  }

  @Test
  func proseCannotBorrowExtraRowsOutsideItsTextBox() throws {
    let size = CGSize(width: 400, height: 200)
    var source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.1, width: 0.425, height: 0.1),
      text: "A prose notice",
      imageAspectRatio: 2,
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: 0.07,
        fontWeight: .regular
      )
    )
    func placement() throws -> OverlayPlacement {
      var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "en")))
      line.showTranslation("이 문서는 인공 지능을 설명합니다. 다른 뜻은 별도 문서를 참고하세요.", language: .init(identifier: "ko"))
      return try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
    }
    let original = try placement()
    source.layoutBounds = CGRect(x: 0.05, y: 0.1, width: 0.425, height: 0.4)
    let expanded = try placement()
    #expect(expanded.frame == original.frame)
    #expect(expanded.fontSize == original.fontSize)
    #expect(CaptureQualityMetrics.sourceBoundaryIssues([expanded], canvas: size).isEmpty)
  }

  @Test
  func establishedNameAndSubtitleKeepTheirMultilineComposition() throws {
    let size = CGSize(width: 620, height: 820)
    let preferred: CGFloat = 22.7809722948
    var source = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 63 / size.width, y: 10 / size.height, width: 122 / size.width, height: 41 / size.height),
      text: "ウィキペディアフリー百科事典",
      imageAspectRatio: size.width / size.height,
      rowCount: 2,
      appearance: .init(
        background: .white,
        foreground: .black,
        confidence: 1,
        fontSizeScale: preferred / size.height,
        fontWeight: .regular
      )
    )
    func placement() throws -> OverlayPlacement {
      var line = OverlayLine(id: UUID(), source: .init(recognized: source, language: .init(identifier: "ja")))
      line.showTranslation("위키피디아 무료 백과사전", language: .init(identifier: "ko"))
      return try #require(OverlayLayoutEngine.placements(for: [line], in: size).first)
    }
    let original = try placement()
    #expect(original.fontSize + 0.25 >= preferred * 0.85)
    #expect(HorizontalTextRenderer.plan(for: original).lines.count == 2)
    source.layoutBounds = CGRect(x: 0, y: 10 / size.height, width: 343 / size.width, height: 61 / size.height)
    let expanded = try placement()
    #expect(expanded.frame == original.frame)
    #expect(expanded.fontSize == original.fontSize)
  }

  @Test(arguments: [("ko", "번역된 제목"), ("de", "Neuer Titel"), ("ar", "عنوان مترجم")], [CGFloat(1), 2])
  func nativeCellsCannotEnlargeHeaderTextBoxes(_ target: (String, String), _ scale: CGFloat) throws {
    let size = CGSize(width: 600 * scale, height: 300 * scale)
    let rows = nativeTableRows()
    let lines = rows.map { row in
      var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
      line.showTranslation(target.1, language: .init(identifier: target.0))
      return line
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: size)
    #expect(placements.count == 2)
    for placement in placements {
      let cell = try #require(placement.line.source.tableCell)
      let bounds = pixelRect(cell.box, canvas: size)
      #expect(bounds.insetBy(dx: -0.001, dy: -0.001).contains(placement.frame))
      #expect(placement.alignment == .center)
      #expect(placement.sourceFrame.contains(placement.frame))
      #expect(CaptureQualityMetrics.sourceBoundaryIssues([placement], canvas: size).isEmpty)
    }
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test(arguments: [OverlayTextAlignment.leading, .center, .trailing], [CGFloat(1), 2])
  func unequalTableLabelsKeepTheirObservedColumnAnchor(_ alignment: OverlayTextAlignment, _ scale: CGFloat) {
    let canvas = CGSize(width: 600 * scale, height: 300 * scale)
    let lines = [CGFloat(0.06), 0.10, 0.15].enumerated().map { row, width in
      let x: CGFloat =
        switch alignment {
        case .leading: 0.205
        case .center: 0.30 - width / 2
        case .trailing: 0.395 - width
        }
      let recognized = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: x, y: 0.2 + CGFloat(row) * 0.1, width: width, height: 0.045),
        text: ["Name", "Document", "Architecture"][row],
        imageAspectRatio: 2,
        appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.05),
        tableCell: .init(
          table: 0,
          row: row,
          column: 0,
          box: CGRect(x: 0.2, y: 0.19 + CGFloat(row) * 0.1, width: 0.2, height: 0.08)
        )
      )
      var line = OverlayLine(id: UUID(), source: .init(recognized: recognized, language: .init(identifier: "en")))
      line.showTranslation("이름", language: .init(identifier: "ko"))
      return line
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    #expect(placements.count == 3)
    for placement in placements {
      #expect(placement.alignment == alignment)
      switch alignment {
      case .leading: #expect(abs(placement.frame.minX - placement.sourceFrame.minX) < 0.01)
      case .trailing: #expect(abs(placement.frame.maxX - placement.sourceFrame.maxX) < 0.01)
      case .center: #expect(abs(placement.frame.midX - placement.sourceFrame.midX) < 0.01)
      }
    }
  }

  @Test
  func independentOwnersInsideOneCellCannotEachBorrowTheWholeCell() {
    var rows = nativeTableRows()
    rows[0].layoutBounds = nil
    rows[1].layoutBounds = nil
    rows[1].tableCell = rows[0].tableCell
    rows[1].boundingBoxNormalized.origin.x = 0.30
    let lines = rows.map { row in
      var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
      line.showTranslation("가", language: .init(identifier: "ko"))
      return line
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: CGSize(width: 600, height: 300))
    #expect(placements.count == 2)
    #expect(placements.allSatisfy { $0.frame.width <= $0.sourceFrame.width + 0.001 })
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test
  func aWideOwnerCrossingOnlyPartOfACellStillPreventsBorrowing() throws {
    var rows = nativeTableRows()
    rows[0].layoutBounds = nil
    rows[1].layoutBounds = nil
    rows[1].tableCell = nil
    rows[1].surface = nil
    rows[1].boundingBoxNormalized = CGRect(x: 0, y: 0.26, width: 0.9, height: 0.03)
    let cell = try #require(rows[0].tableCell)
    let overlap = cell.box.intersection(rows[1].boundingBoxNormalized)
    #expect(overlap.width * overlap.height < rows[1].boundingBoxNormalized.width * rows[1].boundingBoxNormalized.height / 2)
    let lines = rows.map { row in
      var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
      line.showTranslation("가", language: .init(identifier: "ko"))
      return line
    }
    let placement = try #require(OverlayLayoutEngine.placements(for: lines, in: CGSize(width: 600, height: 300)).first)
    #expect(placement.frame.width <= placement.sourceFrame.width + 0.001)
  }

  @Test
  func aCellEstimateCannotShrinkVerifiedTitleSpace() throws {
    var row = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.35, y: 0.2, width: 0.1, height: 0.06),
      text: "Title",
      imageAspectRatio: 2,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 25.0 / 300, fontWeight: .regular),
      layoutBounds: CGRect(x: 0.35, y: 0.2, width: 0.45, height: 0.1)
    )
    func placement(_ row: OCRResult.Line) throws -> OverlayPlacement {
      var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
      line.showTranslation("넓은 공간의 제목", language: .init(identifier: "ko"))
      return try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 600, height: 300)).first)
    }
    let baseline = try placement(row)
    row.tableCell = .init(table: 0, row: 0, column: 0, box: CGRect(x: 0.15, y: 0.19, width: 0.30, height: 0.10))
    let result = try placement(row)
    #expect(result.fontSize >= baseline.fontSize)
    #expect(HorizontalTextRenderer.plan(for: result).lines.count <= HorizontalTextRenderer.plan(for: baseline).lines.count)
  }

  @Test
  func aNativeCellThatSplitsItsOwnLabelIsNotLayoutEvidence() throws {
    var rows = nativeTableRows()
    rows[0].boundingBoxNormalized = CGRect(x: 0.18, y: 0.215, width: 0.16, height: 0.035)
    rows[0].tableCell?.box = CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.08)
    rows[0].layoutBounds = nil
    var line = OverlayLine(id: UUID(), source: .init(recognized: rows[0], language: .init(identifier: "en")))
    line.showTranslation("번역된 제목", language: .init(identifier: "ko"))
    let result = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 600, height: 300)).first)
    #expect(result.frame.width >= result.sourceFrame.width - 0.001)
  }

  @Test
  func nativeCellLayoutSurvivesUnscaledComposition() {
    let originalSize = CGSize(width: 600, height: 300)
    let compositeSize = CGSize(width: 1600, height: 900)
    let crop = CGRect(x: 700, y: 100, width: 600, height: 300)
    let rows = nativeTableRows()
    let mapped = OCRDocumentRegion.remap(
      .init(lines: rows, containers: [], tableCells: rows.compactMap(\.tableCell)),
      crop: crop,
      imageSize: compositeSize
    )
    func placements(_ rows: [OCRResult.Line], size: CGSize) -> [OverlayPlacement] {
      let lines = rows.map { row in
        var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: .init(identifier: "en")))
        line.showTranslation("번역된 제목", language: .init(identifier: "ko"))
        return line
      }
      return OverlayLayoutEngine.placements(for: lines, in: size)
    }
    let original = placements(rows, size: originalSize)
    let composite = placements(mapped.lines, size: compositeSize)
    #expect(original.count == 2 && composite.count == 2)
    for (a, b) in zip(original, composite) {
      #expect(a.alignment == b.alignment)
      #expect(abs(a.fontSize - b.fontSize) < 0.001)
      let expected = a.frame.offsetBy(dx: crop.minX, dy: crop.minY)
      #expect(abs(expected.minX - b.frame.minX) < 0.001)
      #expect(abs(expected.minY - b.frame.minY) < 0.001)
      #expect(abs(expected.width - b.frame.width) < 0.001)
      #expect(abs(expected.height - b.frame.height) < 0.001)
    }
  }

  @Test(arguments: [false, true], [CGSize(width: 2520, height: 900), CGSize(width: 5000, height: 1800)])
  func embeddedContentRetainsItsPhysicalLayout(_ rightToLeft: Bool, _ canvas: CGSize) {
    let size = CGSize(width: 1200, height: 820)
    let offset = CGPoint(x: canvas.width - size.width - 40, y: 40)
    let crop = CGRect(origin: offset, size: size)
    let language = Locale.Language(identifier: rightToLeft ? "ar" : "en")
    let boxes = [
      CGRect(x: 0.001, y: 0.04, width: 0.12, height: 0.035),
      CGRect(x: 0.49, y: 0.017, width: 0.3, height: 0.034),
      CGRect(x: 0.1, y: 0.4, width: 0.3, height: 0.03),
      CGRect(x: 0.13, y: 0.445, width: 0.12, height: 0.03),
      CGRect(x: 0.1, y: 0.49, width: 0.3, height: 0.03),
      CGRect(x: 0.9, y: 0.85, width: 0.099, height: 0.04),
    ]
    let rows = boxes.map { box in
      OCRResult.Line(
        boundingBoxNormalized: box,
        text: "Source label",
        imageAspectRatio: size.width / size.height,
        horizontalGlyphScale: box.height,
        appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.024),
        recognitionContextID: 0,
        recognitionContextBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
      )
    }
    func overlay(_ rows: [OCRResult.Line]) -> [OverlayLine] {
      rows.map { row in
        var line = OverlayLine(id: UUID(), source: .init(recognized: row, language: language))
        line.showTranslation(rightToLeft ? "اختبار الترجمة" : "Translated label", language: language)
        return line
      }
    }
    let original = OverlayLayoutEngine.placements(for: overlay(rows), in: size)
    let mapped = OCRDocumentRegion.remap(.init(lines: rows, containers: []), crop: crop, imageSize: canvas)
    var embeddedLines = overlay(mapped.lines)
    // Nearby unrelated content must not contribute alignment evidence.
    var foreign = mapped.lines[3]
    foreign.boundingBoxNormalized.origin.y -= foreign.boundingBoxNormalized.height * 1.8
    foreign.boundingBoxNormalized.origin.x += foreign.boundingBoxNormalized.width * 0.3
    foreign.recognitionContextID = 1
    embeddedLines += overlay([foreign])
    let embedded = OverlayLayoutEngine.placements(for: embeddedLines, in: canvas)
    #expect(original.count == rows.count)
    #expect(embedded.count == rows.count + 1)
    for (before, after) in zip(original, embedded) {
      #expect(before.alignment == after.alignment)
      #expect(abs(before.fontSize - after.fontSize) < 1e-6)
      let expected = before.frame.offsetBy(dx: offset.x, dy: offset.y)
      #expect(abs(expected.minX - after.frame.minX) < 1e-6)
      #expect(abs(expected.minY - after.frame.minY) < 1e-6)
      #expect(abs(expected.width - after.frame.width) < 1e-6)
      #expect(abs(expected.height - after.frame.height) < 1e-6)
    }
  }

  @Test(arguments: [OverlayTextAlignment.leading, .trailing, .center])
  func aMeasuredSingleRowAlignsToInkInsteadOfPaddedOCRBounds(_ alignment: OverlayTextAlignment) throws {
    let box = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.05)
    let ink = CGRect(x: 0.23, y: 0.2, width: 0.35, height: 0.05)
    var line = OverlayLine(id: UUID(), source: .init(recognized: .init(
      boundingBoxNormalized: box,
      text: "Heading",
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.04),
      styleRuns: [.init(range: NSRange(location: 0, length: 7), box: box, inkBox: ink)],
      alignment: alignment
    ), language: .init(identifier: "en")))
    line.showTranslation("Title", language: .init(identifier: "en"))
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1000, height: 600)).first)
    #expect(placement.sourceFrame.minX == 200)
    #expect(abs(placement.sourceFrame.maxX - 600) < 0.01)
    switch alignment {
    case .leading: #expect(abs(placement.frame.minX - 230) < 0.01)
    case .trailing: #expect(abs(placement.frame.maxX - 580) < 0.01)
    case .center: #expect(abs(placement.frame.midX - 405) < 0.01)
    }
  }

  @Test(arguments: [
    EdgeCase(name: "left", box: CGRect(x: 0.01, y: 0.2, width: 0.06, height: 0.3)),
    EdgeCase(name: "right", box: CGRect(x: 0.93, y: 0.2, width: 0.06, height: 0.3)),
    EdgeCase(name: "top", box: CGRect(x: 0.45, y: 0.01, width: 0.06, height: 0.3)),
    EdgeCase(name: "bottom", box: CGRect(x: 0.45, y: 0.69, width: 0.06, height: 0.3)),
  ])
  func translationUsesOriginalFrameAtCanvasEdges(_ testCase: EdgeCase) throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let line = translatedLine(
      box: testCase.box,
      sourceIsVertical: true,
      text: "Sorry for dropping by so suddenly, Yukie-san.",
      target: "en-US"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    let safe = CGRect(origin: .zero, size: canvas).insetBy(dx: 4, dy: 4)
    #expect(safe.contains(placement.sourceFrame))
    #expect(safe.contains(placement.frame))
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
    #expect(placement.fontSize >= 4)
  }

  @Test
  func rightEdgeTranslationDoesNotExpandTowardTheInterior() throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let box = CGRect(x: 0.89, y: 0.04, width: 0.07, height: 0.2)
    let line = translatedLine(
      box: box,
      sourceIsVertical: true,
      text: "I have something important to tell you today.",
      target: "en-US"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.frame.maxX <= canvas.width - 4)
  }

  @Test
  func longTranslationStaysInsideDetectedSourceSurface() throws {
    let canvas = CGSize(width: 1_024, height: 1_536)
    var line = translatedLine(
      box: CGRect(x: 0.06, y: 0.04, width: 0.07, height: 0.23),
      sourceIsVertical: true,
      text: "Sorry for dropping by so suddenly, Yukie-san.",
      target: "en-US"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.025, y: 0.02, width: 0.115, height: 0.27),
      confidence: 0.9
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    let surface = pixelRect(line.source.surface!.box, canvas: canvas)

    #expect(surface.contains(placement.frame))
    #expect(placement.placementBounds.contains(placement.frame))
    #expect(CoreTextTypesetter.horizontalWordsFit(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      constrainedToWidth: placement.frame.width
    ))
  }

  @Test(arguments: ["Translated text.", "Readable translated sentence."])
  func tinyHorizontalSourceOnlyReplacesTextThatActuallyFits(_ text: String) throws {
    let canvas = CGSize(width: 1_024, height: 480)
    let box = CGRect(x: 0.1, y: 0.1, width: 0.03, height: 0.025)
    let line = translatedLine(
      box: box,
      sourceIsVertical: false,
      text: text,
      target: "en-US"
    )
    let placements = OverlayLayoutEngine.placements(for: [line], in: canvas)
    if text == "Readable translated sentence." {
      #expect(placements.isEmpty)
      #expect(!OverlayLayoutEngine.protectedSourceFrames(for: [line], placements: placements, in: canvas, displayScale: 1)
        .isEmpty)
      return
    }
    let placement = try #require(placements.first)
    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.fontSize <= 8)
    #expect(placement.fontSize > 0)
    #expect(HorizontalTextRenderer.plan(for: placement).fits(placement.frame.size))
  }

  @Test
  func shorterHorizontalTranslationKeepsOriginalSourceRowWidth() throws {
    let canvas = CGSize(width: 1_000, height: 500)
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.5, height: 0.06),
      sourceIsVertical: false,
      text: "짧음",
      target: "ko"
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
  }

  @Test
  func compactControlCannotEnlargeItsSourceTextBox() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.40, y: 0.40, width: 0.10, height: 0.03),
      sourceIsVertical: false,
      text: "안정된 상태",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.39, y: 0.385, width: 0.14, height: 0.06),
      confidence: 0.8
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.sourceFrame.contains(placement.frame))
    #expect(CaptureQualityMetrics.sourceBoundaryIssues([placement], canvas: canvas).isEmpty)
    #expect(placement.frame.contains(
      CGPoint(x: placement.sourceFrame.midX, y: placement.sourceFrame.midY)
    ))
  }

  @Test
  func compactControlInfersCenterAlignmentFromItsSurfaceMargins() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3227, y: 0.3605, width: 0.0363, height: 0.0163),
      text: "Stable",
      horizontalGlyphScale: 0.0163,
      alignment: .leading,
      surface: OverlaySourceSurface(
        box: CGRect(x: 0.3212, y: 0.3500, width: 0.0426, height: 0.0333),
        confidence: 0.8
      )
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("안정된", language: Locale.Language(identifier: "ko-KR"))
    let surfaceFrame = pixelRect(line.source.surface!.box, canvas: canvas)

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.alignment == .center)
    #expect(abs(placement.frame.midX - placement.sourceFrame.midX) < 0.01)
    #expect(placement.sourceFrame.contains(placement.frame))
    #expect(surfaceFrame.contains(placement.frame))
  }

  @Test
  func leadingCompactControlRetainsItsVisualPadding() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.102, y: 0.40, width: 0.05, height: 0.03),
      text: "Status",
      horizontalGlyphScale: 0.03,
      alignment: .leading,
      surface: OverlaySourceSurface(
        box: CGRect(x: 0.10, y: 0.385, width: 0.10, height: 0.06),
        confidence: 0.8
      )
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("상태", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.alignment == .leading)
    #expect(placement.frame.minX == placement.sourceFrame.minX)
  }

  @Test(arguments: [
    PageAlignmentCase(
      name: "left edge label",
      box: CGRect(x: 0.01, y: 0.25, width: 0.12, height: 0.04),
      expected: .leading
    ),
    PageAlignmentCase(
      name: "right edge label",
      box: CGRect(x: 0.87, y: 0.25, width: 0.12, height: 0.04),
      expected: .trailing
    ),
  ])
  func pageGeometryOverridesIncorrectVisionAlignment(_ testCase: PageAlignmentCase) throws {
    var line = translatedLine(
      box: testCase.box,
      sourceIsVertical: false,
      text: "짧은 번역",
      target: "ko-KR"
    )
    line.source.alignment = .leading

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_000, height: 600)).first
    )

    #expect(placement.alignment == testCase.expected)
  }

  @Test
  func wideListRowsDoNotInventCenterAlignment() {
    var title = translatedLine(
      id: lineID(22),
      box: CGRect(x: 0.06384, y: 0.58941, width: 0.89040, height: 0.06547),
      sourceIsVertical: false,
      text: "SwiftUI 목록을 자동으로 스크롤하는 방법",
      target: "ko-KR"
    )
    var detail = translatedLine(
      id: lineID(23),
      box: CGRect(x: 0.06051, y: 0.65625, width: 0.89136, height: 0.06175),
      sourceIsVertical: false,
      sourceRows: 2,
      text: "검색 결과의 상세 설명",
      target: "ko-KR"
    )
    title.source.alignment = nil
    detail.source.alignment = .leading

    let placements = OverlayLayoutEngine.placements(
      for: [title, detail],
      in: CGSize(width: 1_438, height: 1_232)
    )

    #expect(placements.first { $0.line.id == title.id }?.alignment == .leading)
    #expect(placements.first { $0.line.id == detail.id }?.alignment == .leading)
  }

  @Test(arguments: [
    NeighborAlignmentCase(
      name: "nearby rows share a center axis",
      subject: CGRect(x: 0.19186, y: 0.77907, width: 0.15407, height: 0.02558),
      neighbor: CGRect(x: 0.07558, y: 0.83721, width: 0.38227, height: 0.05832),
      fallback: .leading,
      expected: .center
    ),
    NeighborAlignmentCase(
      name: "nearby rows share a trailing edge",
      subject: CGRect(x: 0.78757, y: 0.42456, width: 0.14286, height: 0.03331),
      neighbor: CGRect(x: 0.56686, y: 0.48333, width: 0.36483, height: 0.05853),
      fallback: .leading,
      expected: .trailing
    ),
    NeighborAlignmentCase(
      name: "left aligned hero rows override a centered Vision result",
      subject: CGRect(x: 0.22075, y: 0.10162, width: 0.51934, height: 0.05437),
      neighbor: CGRect(x: 0.21799, y: 0.17438, width: 0.57130, height: 0.02946),
      fallback: .center,
      expected: .leading
    ),
  ])
  func neighboringBlockGeometryOverridesIncorrectVisionAlignment(
    _ testCase: NeighborAlignmentCase
  ) throws {
    var subject = translatedLine(
      id: lineID(20),
      box: testCase.subject,
      sourceIsVertical: false,
      text: "주요 번역",
      target: "ko-KR"
    )
    let neighbor = translatedLine(
      id: lineID(21),
      box: testCase.neighbor,
      sourceIsVertical: false,
      sourceRows: 2,
      text: "주변 번역 문단",
      target: "ko-KR"
    )
    subject.source.alignment = testCase.fallback

    let placement = try #require(
      OverlayLayoutEngine
        .placements(for: [subject, neighbor], in: CGSize(width: 1_600, height: 1_000))
        .first { $0.line.id == subject.id }
    )

    #expect(placement.alignment == testCase.expected)
  }

  @Test
  func inlineControlLabelPreservesItsLeadingAnchor() throws {
    var heading = translatedLine(
      id: lineID(30),
      box: CGRect(x: 0.52735, y: 0.60399, width: 0.19822, height: 0.03265),
      sourceIsVertical: false,
      text: "본문 옆으로 전환",
      target: "ko-KR"
    )
    var label = translatedLine(
      id: lineID(31),
      box: CGRect(x: 0.56977, y: 0.66250, width: 0.14680, height: 0.02396),
      sourceIsVertical: false,
      text: "자동 번역",
      target: "ko-KR"
    )
    var body = translatedLine(
      id: lineID(32),
      box: CGRect(x: 0.52616, y: 0.71117, width: 0.36054, height: 0.05654),
      sourceIsVertical: false,
      sourceRows: 2,
      text: "스위치 그래픽과 보조 문장은 별도로 유지되어야 합니다.",
      target: "ko-KR"
    )
    heading.source.alignment = .leading
    label.source.alignment = nil
    body.source.alignment = .leading

    let placement = try #require(
      OverlayLayoutEngine
        .placements(
          for: [heading, label, body],
          in: CGSize(width: 1_600, height: 1_000)
        )
        .first { $0.line.id == label.id }
    )

    #expect(placement.alignment == .leading)
  }

  @Test
  func pageCenteredHeroDoesNotCenterAVisuallySeparateCardColumn() {
    var eyebrow = translatedLine(
      id: lineID(0),
      box: CGRect(x: 0.45, y: 0.07, width: 0.10, height: 0.03),
      sourceIsVertical: false,
      text: "프로필",
      target: "ko-KR"
    )
    var hero = translatedLine(
      id: lineID(1),
      box: CGRect(x: 0.14, y: 0.13, width: 0.72, height: 0.08),
      sourceIsVertical: false,
      text: "한 번에 전체 설정을 변경하세요.",
      target: "ko-KR"
    )
    var cardBody = translatedLine(
      id: lineID(2),
      box: CGRect(x: 0.40, y: 0.65, width: 0.20, height: 0.16),
      sourceIsVertical: false,
      sourceRows: 4,
      text: "카드 본문은 원본의 왼쪽 정렬을 유지합니다.",
      target: "ko-KR"
    )
    eyebrow.source.alignment = .leading
    hero.source.alignment = .leading
    cardBody.source.alignment = .leading

    let placements = OverlayLayoutEngine.placements(
      for: [eyebrow, hero, cardBody],
      in: CGSize(width: 1_000, height: 600)
    )

    #expect(placements.first { $0.line.id == eyebrow.id }?.alignment == .center)
    #expect(placements.first { $0.line.id == hero.id }?.alignment == .center)
    #expect(placements.first { $0.line.id == cardBody.id }?.alignment == .leading)
  }

  @Test
  func largeCardSurfaceDoesNotOverrideParagraphAlignment() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.18, y: 0.30, width: 0.20, height: 0.15),
      sourceIsVertical: false,
      sourceRows: 3,
      text: "원본 카드 본문의 왼쪽 정렬을 유지합니다.",
      target: "ko-KR"
    )
    line.source.alignment = .leading
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.08, y: 0.20, width: 0.40, height: 0.35),
      confidence: 0.8
    )

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: canvas).first
    )

    #expect(placement.alignment == .leading)
  }

  @Test
  func heroTitleCanExceedTheOldFixedFontCap() throws {
    let canvas = CGSize(width: 2_170, height: 1_352)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1424, y: 0.1329, width: 0.7384, height: 0.0746),
      text: "Switch your whole setup at once.",
      horizontalGlyphScale: 0.0740,
      horizontalInkScale: 0.0580,
      alignment: .center
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "한 번에 전체 설정을 변경하세요.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize > 72)
    #expect(HorizontalTextRenderer.plan(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      fontSize: placement.fontSize,
      appearance: placement.line.source.appearance,
      styles: placement.line.displayedStyleRuns,
      width: placement.frame.width,
      lineHeightMultiple: placement.lineHeightMultiple
    ).fits(placement.frame.size))
  }

  @Test
  func horizontalCardTitleDoesNotExpandToTheWholeCardSurface() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.12, y: 0.20, width: 0.20, height: 0.05),
      sourceIsVertical: false,
      text: "번역된 카드 제목",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.08, y: 0.10, width: 0.40, height: 0.70),
      confidence: 0.8
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
  }

  @Test
  func horizontalControlUsesWordGlyphHeightInsteadOfIconInflatedLineBox() throws {
    let canvas = CGSize(width: 1_196, height: 610)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.67, y: 0.72, width: 0.18, height: 0.076),
      text: "+ Add bypass",
      horizontalGlyphScale: 0.07,
      horizontalInkScale: 0.034
    )
    var line = OverlayLine(
      id: UUID(0),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en")
      ),
      initialContent: .pending
    )
    line.showTranslation("+ 우회 추가", language: Locale.Language(identifier: "ko"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize < 33)
    #expect(placement.fontSize > 26)
  }

  @Test
  func multilineWebBodyUsesItsVisionRowScaleInsteadOfThinInkHeight() throws {
    let canvas = CGSize(width: 2_172, height: 1_216)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0756, y: 0.6551, width: 0.2358, height: 0.1816),
      text: "Pull a workspace to the top, bottom, left, or right. The two blocks tile beside each other with separate BSP layouts, and windows stay on their own side.",
      rowCount: 5,
      horizontalGlyphScale: 0.0279,
      horizontalInkScale: 0.0150,
      horizontalLineAdvanceScale: 0.036
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "작업 공간을 위쪽, 아래쪽, 왼쪽 또는 오른쪽으로 당기십시오. 두 개의 블록은 별도의 BSP 레이아웃으로 나란히 타일링되며, 창문은 각각 다른 쪽에 유지됩니다.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 31)
    #expect(placement.fontSize <= 33)
    #expect(placement.lineHeightMultiple > 1)
    #expect(placement.lineHeightMultiple <= 1.6)
    #expect(CoreTextTypesetter.fits(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      flow: placement.flow,
      fontSize: placement.fontSize,
      in: placement.frame.size,
      lineHeightMultiple: placement.lineHeightMultiple
    ))
  }

  @Test
  func smallLowContrastFooterTrustsItsVisionGlyphBox() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.06, y: 0.87, width: 0.15, height: 0.021),
      text: "Last updated five minutes ago",
      horizontalGlyphScale: 0.0184,
      horizontalInkScale: 0.00625
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation("마지막 업데이트는 5분 전입니다", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 17)
    #expect(placement.fontSize <= 18)
  }

  @Test
  func smallMultilineTableCellBalancesLineBoxAndInkScale() throws {
    let canvas = CGSize(width: 1_600, height: 1_000)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.55, y: 0.46, width: 0.30, height: 0.045),
      text: "Use one balanced body frame without absorbing the next table row.",
      rowCount: 2,
      horizontalGlyphScale: 0.0212,
      horizontalInkScale: 0.007
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "en-US")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "다음 표 행을 흡수하지 않고 균형 잡힌 본문 프레임을 사용하십시오.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 16)
    #expect(placement.fontSize <= 18)
  }

  @Test
  func compactBoldLabelDoesNotInflateItsPointSize() throws {
    let canvas = CGSize(width: 1_880, height: 1_438)
    func makeLine(weight: OverlayFontWeight) -> OverlayLine {
      var appearance = OverlaySourceAppearance.fallback
      appearance.fontWeight = weight
      let recognized = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.12, y: 0.45, width: 0.04, height: 0.019),
        text: "Tool",
        horizontalGlyphScale: 0.019,
        appearance: appearance
      )
      var line = OverlayLine(
        id: UUID(),
        source: OverlayLine.Source(
          recognized: recognized,
          language: Locale.Language(identifier: "en-US")
        ),
        initialContent: .pending
      )
      line.showTranslation("도구", language: Locale.Language(identifier: "ko-KR"))
      return line
    }

    let regular = try #require(OverlayLayoutEngine.placements(for: [makeLine(weight: .regular)], in: canvas).first)
    let bold = try #require(OverlayLayoutEngine.placements(for: [makeLine(weight: .bold)], in: canvas).first)

    #expect(bold.fontSize <= regular.fontSize + 0.5)
    #expect(bold.fontSize >= 20)
  }

  @Test
  func compactTranslationRetainsTheSourceGlyphScale() throws {
    let canvas = CGSize(width: 1_024, height: 1_536)
    var appearance = OverlaySourceAppearance.fallback
    appearance.fontWeight = .medium
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.75625, y: 0.8125, width: 0.15625, height: 0.01042),
      text: "明日また会いましょう",
      horizontalGlyphScale: 16 / canvas.height,
      appearance: appearance
    )
    var line = OverlayLine(
      id: UUID(0),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP")
      ),
      initialContent: .pending
    )
    line.showTranslation("내일 다시 만나요.", language: Locale.Language(identifier: "ko-KR"))

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 13)
  }

  @Test
  func furiganaInflatedBodyUsesTheBaseGlyphScale() throws {
    let canvas = CGSize(width: 1_314, height: 1_898)
    let recognized = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.045, y: 0.546, width: 0.437, height: 0.102),
      text: "木のぼうの先にくくりつけて、動物や魚をとるためのやりとして使われた。",
      rowCount: 3,
      horizontalGlyphScale: 0.0355,
      horizontalInkScale: 0.0101
    )
    var line = OverlayLine(
      id: UUID(),
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja-JP")
      ),
      initialContent: .pending
    )
    line.showTranslation(
      "나무 막대 끝에 묶어 동물이나 물고기를 잡는 창으로 사용되었습니다.",
      language: Locale.Language(identifier: "ko-KR")
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.fontSize >= 32)
    #expect(placement.fontSize <= 38)
    #expect(CoreTextTypesetter.fits(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      flow: placement.flow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
  }

  @Test
  func verticalSourceKeepsNarrowRestorationBleedNearBubbleEdges() {
    let canvas = CGSize(width: 1_000, height: 1_000)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.2))
    let horizontal = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      in: canvas,
      displayScale: 1
    )
    let vertical = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .vertical(characterScale: 0.04, progression: .rightToLeft),
      in: canvas,
      displayScale: 1
    )

    #expect(horizontal.minX < vertical.minX)
    #expect(horizontal.minY == 199)
    #expect(vertical.minY == 198)
    #expect(vertical.width <= 106)
    #expect(horizontal.width >= 128)
  }

  @Test
  func multilineHorizontalPatchGetsOnlyVerticalAntialiasingBleed() {
    let canvas = CGSize(width: 2_000, height: 1_200)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.025))
    let singleLine = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      in: canvas,
      displayScale: 2
    )
    let multiline = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 5),
      in: canvas,
      displayScale: 2
    )

    #expect(singleLine.minY >= 719)
    #expect(singleLine.maxY <= 751)
    #expect(multiline.minY < singleLine.minY)
    #expect(multiline.maxY > singleLine.maxY)
    #expect(multiline.minY >= 717)
    #expect(multiline.maxY <= 753)
  }

  @Test
  func compactSurfaceRestorationCoversTheFullSourceGlyphHeight() {
    let canvas = CGSize(width: 1_000, height: 500)
    let patch = OverlaySourcePatch(box: CGRect(x: 0.2, y: 0.4, width: 0.1, height: 0.04))
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.195, y: 0.38, width: 0.11, height: 0.08),
      confidence: 0.35,
      clippingBox: CGRect(x: 0.19, y: 0.37, width: 0.12, height: 0.10)
    )

    let ordinary = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      in: canvas,
      displayScale: 1
    )
    let clippedControl = OverlayLayoutEngine.replacementFrame(
      for: patch,
      sourceLayout: .horizontal(rows: 1),
      sourceSurface: surface,
      in: canvas,
      displayScale: 1
    )

    #expect(clippedControl.minY < ordinary.minY)
    #expect(clippedControl.maxY > ordinary.maxY)
    #expect(clippedControl.minY == 186)
    #expect(clippedControl.maxY == 234)
  }

  @Test
  func horizontalTranslationKeepsTheSourceTopEdge() throws {
    let canvas = CGSize(width: 2_178, height: 1_228)
    let line = translatedLine(
      box: CGRect(x: 0.38808, y: 0.675, width: 0.22674, height: 0.1317),
      sourceIsVertical: false,
      sourceRows: 4,
      text: "Conservative, Balanced, Fast 중에서 선택하고 Amado가 급격한 신호 손실을 걸러내게 하십시오.",
      target: "ko-KR"
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(abs(placement.frame.minY - placement.sourceFrame.minY) < 0.5)
  }

  @Test
  func tallerHorizontalTranslationShrinksInsideSource() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.36, y: 0.42, width: 0.16, height: 0.035),
      sourceIsVertical: false,
      text: "번역문이 원문보다 여러 줄 길어지면 추가된 높이만큼 위와 아래로 나누어 확장합니다.",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.25, y: 0.25, width: 0.40, height: 0.40),
      confidence: 0.9
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
  }

  @Test
  func widerVerticalTranslationShrinksInsideSource() throws {
    let canvas = CGSize(width: 1_000, height: 600)
    var line = translatedLine(
      box: CGRect(x: 0.44, y: 0.25, width: 0.05, height: 0.28),
      sourceIsVertical: true,
      text: "번역문이 길어져 세로쓰기 열이 늘어나더라도 원문의 중심 위치를 유지합니다.",
      target: "ko-KR"
    )
    line.source.surface = OverlaySourceSurface(
      box: CGRect(x: 0.28, y: 0.18, width: 0.38, height: 0.42),
      confidence: 0.9
    )

    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)

    #expect(placement.frame == placement.sourceFrame)
    #expect(placement.placementBounds == placement.sourceFrame)
  }

  @Test
  func pendingVerticalSourceDoesNotCreateAReplacementChip() {
    let canvas = CGSize(width: 1_024, height: 480)
    let line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .pending
    )
    #expect(line.textFlow == .vertical(.rightToLeft))
    #expect(OverlayLayoutEngine.placements(for: [line], in: canvas).isEmpty)
  }

  @Test
  func fixedTranslationFrameDoesNotCoverPendingSourceText() throws {
    let canvas = CGSize(width: 2_178, height: 1_228)
    let pending = sourceLine(
      id: UUID(1),
      box: CGRect(x: 0.43605, y: 0.07474, width: 0.13663, height: 0.03359),
      sourceIsVertical: false,
      initialContent: .pending
    )
    let heading = translatedLine(
      id: UUID(2),
      box: CGRect(x: 0.16555, y: 0.13639, width: 0.68491, height: 0.09125),
      sourceIsVertical: false,
      text: "걸어 나가세요. 귀하의 Mac이 종료됩니다.",
      target: "ko-KR"
    )

    let placement = try #require(
      OverlayLayoutEngine.placements(for: [pending, heading], in: canvas).first
    )
    let pendingFrame = pixelRect(pending.source.box, canvas: canvas)
    let intersection = placement.frame.intersection(pendingFrame)

    #expect(intersection.isNull || intersection.isEmpty)
  }

  @Test
  func sameWritingSystemSourceLeavesOriginalPixelsUntouched() {
    let line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .source
    )
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_024, height: 480)).isEmpty)
  }

  @Test
  func verticalTranslationUsesCoreTextFrameThatFits() throws {
    let canvas = CGSize(width: 600, height: 600)
    let line = translatedLine(
      box: CGRect(x: 0.4, y: 0.1, width: 0.16, height: 0.55),
      sourceIsVertical: true,
      text: "2026年8月27日です。OKなら今すぐ始めよう。",
      target: "ja"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: canvas).first)
    #expect(placement.line.textFlow == .vertical(.rightToLeft))
    #expect(CoreTextTypesetter.fits(
      text: line.displayedText,
      language: line.displayedLanguage,
      flow: line.textFlow,
      fontSize: placement.fontSize,
      in: placement.frame.size
    ))
    let image = CoreTextTypesetter.verticalGlyphImage(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      size: placement.frame.size,
      scale: 2,
      progression: .rightToLeft
    )
    #expect(image != nil)
  }

  @Test
  func horizontalAccessibilityPreferenceReflowsVerticalTranslation() throws {
    let line = translatedLine(
      box: CGRect(x: 0.4, y: 0.1, width: 0.16, height: 0.55),
      sourceIsVertical: true,
      text: "今日は晴れです",
      target: "ja"
    )
    let placement = try #require(
      OverlayLayoutEngine.placements(
        for: [line],
        in: CGSize(width: 600, height: 600),
        prefersHorizontalTextLayout: true
      ).first
    )
    #expect(placement.flow == .horizontal(.leftToRight))
    #expect(placement.fontSize > 0)
  }

  @Test
  func arabicGlyphDirectionKeepsTheHorizontalSourceReadingEdge() throws {
    var line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.1),
      sourceIsVertical: false,
      text: "لدي شيء مهم لأخبرك به",
      target: "ar"
    )
    // The source is Japanese horizontal text. RTL shaping does not move its
    // physical leading edge; source alignment and target bidi are independent.
    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 400)).first
    )
    #expect(placement.line.textFlow == .horizontal(.rightToLeft))
    #expect(placement.alignment == .leading)
    line.source.text = "لدي شيء مهم لأخبرك به"
    line.source.language = Locale.Language(identifier: "ar")
    line.showTranslation("알려드릴 중요한 이야기가 있습니다", language: Locale.Language(identifier: "ko"))
    let reversed = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 400)).first)
    #expect(reversed.line.textFlow == .horizontal(.leftToRight))
    #expect(reversed.alignment == .trailing)
  }

  @Test
  func verticalOriginHorizontalTranslationIsCentered() throws {
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.08, height: 0.3),
      sourceIsVertical: true,
      text: "A horizontal translation",
      target: "en-US"
    )
    let placement = try #require(
      OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 800, height: 400)).first
    )
    #expect(placement.alignment == .center)
  }

  @Test
  func adjacentSourceFramesRemainSeparate() {
    let canvas = CGSize(width: 1_000, height: 500)
    let first = translatedLine(
      id: UUID(1),
      box: CGRect(x: 0.40, y: 0.2, width: 0.06, height: 0.28),
      sourceIsVertical: true,
      text: "The first translated sentence is readable.",
      target: "en-US"
    )
    let second = translatedLine(
      id: UUID(2),
      box: CGRect(x: 0.54, y: 0.2, width: 0.06, height: 0.28),
      sourceIsVertical: true,
      text: "The second translated sentence is readable.",
      target: "en-US"
    )
    let placements = OverlayLayoutEngine.placements(for: [first, second], in: canvas)
    #expect(placements.count == 2)
    let intersection = placements[0].frame.intersection(placements[1].frame)
    #expect(intersection.isNull || intersection.isEmpty)
  }

  @Test
  func observedProblemMatrixHasSixContainedNonOverlappingLabels() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let rows: [(CGRect, String)] = [
      (CGRect(x: 0.89375, y: 0.03958, width: 0.06875, height: 0.19167), "I have something important to tell you today."),
      (CGRect(x: 0.05937, y: 0.03750, width: 0.06563, height: 0.22708), "Sorry for dropping by so suddenly, Yukie-san."),
      (CGRect(x: 0.58750, y: 0.38333, width: 0.05938, height: 0.12083), "I still cannot believe it."),
      (CGRect(x: 0.42187, y: 0.38125, width: 0.06250, height: 0.11458), "Is that really true?"),
      (CGRect(x: 0.40625, y: 0.68125, width: 0.05625, height: 0.10417), "If that is OK, let us start right now."),
      (CGRect(x: 0.06250, y: 0.68125, width: 0.05625, height: 0.10833), "It is August 27, 2026."),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: true,
        text: row.1,
        target: "en-US"
      )
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    let safeBounds = CGRect(origin: .zero, size: canvas).insetBy(dx: 4, dy: 4)

    #expect(placements.count == 6)
    #expect(placements.allSatisfy { safeBounds.contains($0.frame) && safeBounds.contains($0.sourceFrame) })
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
    #expect(placements.allSatisfy { placement in
      centerDistance(placement.frame, placement.sourceFrame)
        <= max(24, placement.sourceFrame.width / 2)
    })
    #expect(placements.allSatisfy { $0.fontSize >= 4 })
    let adjacentDistances = placements[2...3].map {
      centerDistance($0.frame, $0.sourceFrame)
    }
    #expect(
      adjacentDistances.allSatisfy { $0 <= 30 },
      "Adjacent center distances: \(adjacentDistances)"
    )
    #expect(
      abs(adjacentDistances[0] - adjacentDistances[1]) < 1,
      "Adjacent center distances: \(adjacentDistances)"
    )
    #expect(placements.allSatisfy { placement in
      CoreTextTypesetter.fits(
        text: placement.line.displayedText,
        language: placement.line.displayedLanguage,
        flow: placement.flow,
        fontSize: placement.fontSize,
        in: placement.frame.size
      )
    })
  }

  @Test
  func observedTamilProblemMatrixKeepsAdjacentLabelsSeparate() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let sentence = "இது தெளிவாக வாசிக்கக்கூடிய சோதனை வாக்கியம்."
    let rows: [(CGRect, String)] = [
      (CGRect(x: 0.89375, y: 0.03958, width: 0.06875, height: 0.19167), sentence),
      (CGRect(x: 0.05937, y: 0.03750, width: 0.06563, height: 0.22708), "\(sentence) \(sentence)"),
      (CGRect(x: 0.58750, y: 0.38333, width: 0.05938, height: 0.12083), sentence),
      (CGRect(x: 0.42187, y: 0.38125, width: 0.06250, height: 0.11458), "ஆம்."),
      (CGRect(x: 0.40625, y: 0.68125, width: 0.05625, height: 0.10417), "OK · \(sentence)"),
      (CGRect(x: 0.06250, y: 0.68125, width: 0.05625, height: 0.10833), "2026 · \(sentence)"),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: true,
        text: row.1,
        target: "ta-Taml-IN"
      )
    }

    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)

    #expect(placements.count == 6)
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test
  func observedNormalMatrixHasFourNonOverlappingLabelsAfterCoalescing() {
    let canvas = CGSize(width: 1_024, height: 1_536)
    let rows: [(CGRect, Bool, String)] = [
      (CGRect(x: 0.11562, y: 0.04792, width: 0.06875, height: 0.20833), true, "The weather is nice today."),
      (
        CGRect(x: 0.09030, y: 0.44436, width: 0.34095, height: 0.07231),
        false,
        "The weather is nice today. Let us meet here again next weekend."
      ),
      (CGRect(x: 0.60000, y: 0.64792, width: 0.06250, height: 0.11875), true, "Yes, I am looking forward to it."),
      (CGRect(x: 0.38750, y: 0.64583, width: 0.05938, height: 0.14167), true, "Let us meet again tomorrow."),
    ]
    let lines = rows.enumerated().map { index, row in
      translatedLine(
        id: lineID(index),
        box: row.0,
        sourceIsVertical: row.1,
        sourceRows: index == 1 ? 3 : 1,
        text: row.2,
        target: "en-US"
      )
    }
    let placements = OverlayLayoutEngine.placements(for: lines, in: canvas)
    #expect(placements.count == 4)
    #expect(pairwiseNonOverlapping(placements.map(\.frame)))
  }

  @Test
  func unavailableTranslationAlsoLeavesSourceUntouched() {
    var line = sourceLine(
      box: CGRect(x: 0.4, y: 0.2, width: 0.06, height: 0.3),
      sourceIsVertical: true,
      initialContent: .pending
    )
    line.showUnavailable()
    #expect(line.isUnavailable)
    #expect(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 1_024, height: 480)).isEmpty)
  }

  @Test
  func degenerateCanvasDoesNotClaimUnrenderableText() {
    let line = translatedLine(
      box: CGRect(x: -2, y: 4, width: 10, height: 0),
      sourceIsVertical: false,
      text: "Text",
      target: "en-US"
    )
    let canvas = CGSize(width: 3, height: 2)
    let placements = OverlayLayoutEngine.placements(for: [line], in: canvas)
    #expect(placements.isEmpty, "A two-pixel canvas cannot contain complete text; its source must not be erased")
  }

  @Test
  func verticalEmergencyWrappingReachesTheRenderer() throws {
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3),
      sourceIsVertical: true,
      text: "가나다라마바사아자차카타파하가나다라마바사아자차카타파하",
      target: "ko"
    )
    let placement = try #require(OverlayLayoutEngine.placements(for: [line], in: CGSize(width: 200, height: 300)).first)
    #expect(placement.verticalWrapping == .characters)
    #expect(placement.isTextLayoutComplete)
    #expect(CaptureQualityMetrics.layoutIssues(
      [placement],
      canvas: CGSize(width: 200, height: 300),
      minimumFontRatio: 0
    ).isEmpty)
    #expect(CoreTextTypesetter.verticalGlyphImage(
      text: line.displayedText,
      language: line.displayedLanguage,
      fontSize: placement.fontSize,
      size: placement.frame.size,
      scale: 2,
      progression: .rightToLeft,
      wrapping: placement.verticalWrapping
    ) != nil)
  }

  @Test
  func impossibleVerticalTranslationRetainsItsSourceInsteadOfErasingIt() {
    let line = translatedLine(
      box: CGRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
      sourceIsVertical: true,
      text: String(repeating: "가", count: 800),
      target: "ko"
    )
    let size = CGSize(width: 200, height: 300)
    let placements = OverlayLayoutEngine.placements(for: [line], in: size)
    #expect(placements.isEmpty)
    #expect(!OverlayLayoutEngine.protectedSourceFrames(for: [line], placements: placements, in: size, displayScale: 2).isEmpty)
  }

  // MARK: Private

  private func translatedLine(
    id: UUID = UUID(0),
    box: CGRect,
    sourceIsVertical: Bool,
    sourceRows: Int = 1,
    text: String,
    target: String
  ) -> OverlayLine {
    var line = sourceLine(
      id: id,
      box: box,
      sourceIsVertical: sourceIsVertical,
      sourceRows: sourceRows,
      initialContent: .pending
    )
    line.showTranslation(text, language: Locale.Language(identifier: target))
    return line
  }

  private func sourceLine(
    id: UUID = UUID(0),
    box: CGRect,
    sourceIsVertical: Bool,
    sourceRows: Int = 1,
    initialContent: OverlayLine.InitialContent
  ) -> OverlayLine {
    let recognized = OCRResult.Line(
      boundingBoxNormalized: box,
      text: "今日は大切な話があります",
      rowCount: sourceIsVertical ? 2 : sourceRows,
      isVerticalBlock: sourceIsVertical,
      verticalCharScale: sourceIsVertical ? max(0.018, box.width / 2) : 0
    )
    return OverlayLine(
      id: id,
      source: OverlayLine.Source(
        recognized: recognized,
        language: Locale.Language(identifier: "ja")
      ),
      initialContent: initialContent
    )
  }

  private func nativeTableRows() -> [OCRResult.Line] {
    [CGFloat(0.2), 0.5].enumerated().map { column, x in
      var row = OCRResult.Line(
        boundingBoxNormalized: CGRect(x: x + 0.06, y: 0.215, width: 0.04, height: 0.035),
        text: column == 0 ? "Title" : "Next",
        imageAspectRatio: 2,
        appearance: .init(background: .white, foreground: .black, confidence: 1, fontSizeScale: 0.05, fontWeight: .regular),
        layoutBounds: CGRect(x: 0, y: 0, width: 1, height: 1),
        surface: .init(box: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.08), confidence: 1),
        tableCell: .init(table: 0, row: 0, column: column, box: CGRect(x: x, y: 0.2, width: 0.16, height: 0.08)),
        recognitionContextID: 0,
        recognitionContextBounds: CGRect(x: 0, y: 0, width: 1, height: 1)
      )
      row.horizontalGlyphScale = 0.035
      return row
    }
  }

  private func pixelRect(_ normalized: CGRect, canvas: CGSize) -> CGRect {
    CGRect(
      x: normalized.minX * canvas.width,
      y: normalized.minY * canvas.height,
      width: normalized.width * canvas.width,
      height: normalized.height * canvas.height
    )
  }

  private func pairwiseNonOverlapping(_ frames: [CGRect]) -> Bool {
    for lhs in frames.indices {
      for rhs in frames.indices where rhs > lhs {
        let intersection = frames[lhs].intersection(frames[rhs])
        if !intersection.isNull, !intersection.isEmpty { return false }
      }
    }
    return true
  }

  private func centerDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
    hypot(lhs.midX - rhs.midX, lhs.midY - rhs.midY)
  }

  private func lineID(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index + 1))!
  }
}
