// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRTableCell

/// Native document structure, distinct from geometric paragraph/list ownership.
struct OCRTableCell: Equatable, Hashable, Sendable {
  var table: Int
  var row: Int
  var column: Int
  var box: CGRect
  var rowSpan = 1
  var columnSpan = 1

  static func containing(_ box: CGRect, in cells: [Self]) -> Self? {
    guard box.width > 0, box.height > 0 else { return nil }
    // Native grid bounds and text bounds are independent estimates. A final
    // row's glyph box may extend below its cell; its center and horizontal
    // ownership still identify the cell without inventing another table row.
    return cells.filter { cell in
      let overlap = box.intersection(cell.box)
      return cell.box.contains(CGPoint(x: box.midX, y: box.midY)) && !overlap.isNull
        && overlap.width >= box.width * 0.85 && overlap.height >= box.height * 0.5
    }.min { $0.box.width * $0.box.height < $1.box.width * $1.box.height }
  }
}

// MARK: - OCRTableStructure

enum OCRTableStructure {
  /// A value in an established native symbol column remains
  /// reference data even when tiny-font pitch is ambiguous. Headers and prose
  /// outside that exact table/column must not inherit the role.
  static func isSymbolColumnValue(_ line: OCRResult.Line, among lines: [OCRResult.Line]) -> Bool {
    guard
      let cell = line.tableCell, cell.row > 0, cell.rowSpan == 1, cell.columnSpan == 1, (1...40).contains(line.text.count),
      line.text.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
    else { return false }
    let columnValues = lines.filter { other in
      guard let owner = other.tableCell, owner.rowSpan == 1, owner.columnSpan == 1 else { return false }
      return owner.table == cell.table && owner.column == cell.column && owner.row > 0
        && (OCRTextSemantics.isAlphanumericIdentifier(other.text) ||
          (!other.text.isEmpty && other.text.allSatisfy(\.isNumber)))
    }
    return Set(columnValues.compactMap(\.tableCell?.row)).count >= 2
      && columnValues.contains { OCRTextSemantics.isAlphanumericIdentifier($0.text) }
      && columnValues.contains { $0.tableCell!.row != cell.row && abs(cell.row - $0.tableCell!.row) <= 2 }
  }

  /// Establish native symbol-column roles before spelling recovery can remove
  /// the alphanumeric evidence (for example, reading a narrow letter as a digit).
  static func classifyingSymbols(_ result: OCRResult) -> OCRResult {
    OCRResult(lines: result.lines.map { source in
      var line = source
      if isSymbolColumnValue(line, among: result.lines) {
        line.preservesSource = true
        line.preventsJoining = true
      }
      return line
    })
  }

  /// Glyph measurements can resolve membership when a padded recognition box
  /// misses the native cell. Do this before paragraph joining, and require
  /// observed ink for the whole label rather than borrowing a single word.
  static func classifyingObservedCells(_ result: OCRResult, cells: [OCRTableCell]) -> OCRResult {
    guard !cells.isEmpty else { return result }
    let candidates: [OCRTableCell?] = result.lines.map { line in
      if let cell = line.tableCell { return cell }
      guard line.rowCount == 1, !line.isVerticalBlock, !line.styleRuns.isEmpty else { return nil }
      var covered = IndexSet()
      var ink = CGRect.null
      for run in line.styleRuns {
        guard let box = run.inkBox, !box.isEmpty, !box.isNull, Range(run.range, in: line.text) != nil else { return nil }
        covered.insert(integersIn: run.range.location..<NSMaxRange(run.range))
        ink = ink.union(box)
      }
      let text = line.text as NSString
      guard
        (0..<text.length).allSatisfy({ offset in
          if covered.contains(offset) { return true }
          guard let scalar = UnicodeScalar(text.character(at: offset)) else { return false }
          return CharacterSet.whitespacesAndNewlines.contains(scalar)
        })
      else { return nil }
      return OCRTableCell.containing(ink, in: cells)
    }
    var didAssign = false
    let assigned = OCRResult(lines: result.lines.enumerated().map { index, source in
      var line = source
      guard
        line.tableCell == nil, let cell = candidates[index], candidates.count(where: {
          $0.map { $0.table == cell.table && $0.row == cell.row && $0.column == cell.column } == true
        }) == 1, !result.lines.enumerated().contains(where: { otherIndex, other in
          guard otherIndex != index else { return false }
          let overlap = other.boundingBoxNormalized.intersection(cell.box)
          return !overlap.isNull && !overlap.isEmpty
        })
      else { return line }
      line.tableCell = cell
      line.recognitionContainer = cell.box
      didAssign = true
      return line
    })
    return didAssign ? classifyingSymbols(assigned) : result
  }

  /// A symbol established by a table can recur in an inline code chip. Require
  /// that chip's distinct surface as well; ordinary prose with the same word
  /// does not inherit the table's literal role.
  static func protectingInlineSymbols(_ result: OCRResult) -> OCRResult {
    let symbols = Set(result.lines.filter { $0.preservesSource && $0.tableCell != nil }.map(\.text))
    guard !symbols.isEmpty else { return result }
    return OCRResult(lines: result.lines.map { original in
      var line = original
      guard !line.preservesSource else { return line }
      let observedChips = line.styleRuns.filter { run in
        guard let range = Range(run.range, in: line.text) else { return false }
        return symbols.contains(String(line.text[range]))
          && (run.appearance.fontDesign == .monospaced
            || run.appearance.background.distance(to: line.appearance.background) >= 0.025)
      }
      line.styleRuns = line.styleRuns.map { original in
        var run = original
        guard let range = Range(run.range, in: line.text), symbols.contains(String(line.text[range])) else { return run }
        let separation = run.appearance.background.distance(to: line.appearance.background)
        // A second occurrence of the same visual role can be closer to an
        // established chip than to the paragraph surface, even when sampling
        // noise puts it just below the absolute surface threshold.
        let matchesObservedChip = observedChips.contains { chip in
          separation > 0 && run.appearance.fontSizeScale > 0 && chip.appearance.fontSizeScale > 0
            && abs(run.appearance.fontSizeScale / chip.appearance.fontSizeScale - 1) <= 0.15
            && run.appearance.background.distance(to: chip.appearance.background) <= separation * 0.25
            && run.appearance.foreground.distance(to: chip.appearance.foreground) <= 0.1
        }
        if separation >= 0.025 || matchesObservedChip {
          run.appearance.fontDesign = .monospaced
        }
        return run
      }
      return line
    })
  }

}
