// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

/// Reference values need evidence without dictionary correction. Only revisit
/// ambiguous numeric/word columns beside an established symbol column, and only
/// accept role evidence when the native row/column structure agrees exactly.
enum OCRTableRecovery {

  // MARK: Internal

  static func requiresReferenceEvidence(_ lines: [OCRResult.Line]) -> Bool {
    let symbols = lines.filter {
      OCRTextSemantics.isAlphanumericIdentifier($0.text) && OCRTableStructure.isSymbolColumnValue($0, among: lines)
    }
    guard !symbols.isEmpty else { return false }
    let knownColumns = Set(symbols.compactMap(\.tableCell?.column))
    let columns = Dictionary(grouping: lines.filter {
      guard let cell = $0.tableCell else { return false }
      return cell.row > 0 && cell.rowSpan == 1 && cell.columnSpan == 1
    }, by: { $0.tableCell!.column })
    return columns.contains { column, values in
      !knownColumns.contains(column)
        && values.count(where: { !$0.text.isEmpty && $0.text.allSatisfy(\.isNumber) }) >= 2
        && values
        .contains { !$0.text.isEmpty && $0.text.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.letters.contains($0) } }
    }
  }

  static func refine(
    _ document: VisionTextRecognizer.Document,
    image: CGImage,
    language: Language
  ) async throws -> VisionTextRecognizer.Document {
    var result = document
    let size = CGSize(width: image.width, height: image.height)
    let tables = Dictionary(grouping: document.lines.filter { $0.tableCell != nil }, by: { $0.tableCell!.table })
    var requests = 0
    for table in tables.keys.sorted() {
      let lines = tables[table]!
      guard requiresReferenceEvidence(lines) else { continue }
      let cells = document.tableCells.filter { $0.table == table }
      let expected = Set(cells.map(CellKey.init))
      let bounds = (cells.map(\.box) + lines.map(\.boundingBoxNormalized)).reduce(CGRect.null) { $0.union($1) }
      let crop = CGRect(
        x: bounds.minX * size.width,
        y: bounds.minY * size.height,
        width: bounds.width * size.width,
        height: bounds.height * size.height
      )
      .insetBy(dx: -8, dy: -8).integral.intersection(CGRect(origin: .zero, size: size))
      let scale = max(1, min(2, 1800 / max(crop.width, crop.height)))
      guard
        let source = image.cropping(to: crop),
        let context = CGContext(
          data: nil,
          width: Int(ceil(crop.width * scale)),
          height: Int(ceil(crop.height * scale)),
          bitsPerComponent: 8,
          bytesPerRow: 0,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { throw CocoaError(.coderInvalidValue) }
      context.interpolationQuality = .high
      context.draw(source, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
      guard let input = context.makeImage() else { throw CocoaError(.coderInvalidValue) }
      try Task.checkCancellation()
      let reread = OCRDocumentRegion.remap(
        try await VisionTextRecognizer.document(in: input, language: language, usesLanguageCorrection: false),
        crop: crop,
        imageSize: size
      )
      requests += 1
      let grids = Dictionary(grouping: reread.tableCells, by: \.table)
        .filter { Set($0.value.map(CellKey.init)) == expected }
      if grids.count == 1, let identity = grids.keys.first {
        let candidates = reread.lines.filter { $0.tableCell?.table == identity }
        let literalKeys = Set(candidates.filter { OCRTableStructure.isSymbolColumnValue($0, among: candidates) }
          .compactMap { $0.tableCell.map(CellKey.init) })
        result.lines = result.lines.map { source in
          var line = source
          if let cell = line.tableCell, cell.table == table, literalKeys.contains(CellKey(cell)) {
            line.preservesSource = true
            line.preventsJoining = true
          }
          return line
        }
      } else {
        Log.ocr.debug("Rejected reference-table evidence with changed native grid")
      }
      if requests == 2 { break }
    }
    return result
  }

  // MARK: Private

  private struct CellKey: Hashable {
    init(_ cell: OCRTableCell) {
      row = cell.row
      column = cell.column
      rowSpan = cell.rowSpan
      columnSpan = cell.columnSpan
    }

    let row: Int
    let column: Int
    let rowSpan: Int
    let columnSpan: Int

  }

}
