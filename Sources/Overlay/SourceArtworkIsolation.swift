// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Vision can include adjacent artwork in a word rectangle without including
/// it in the transcript. Remove that ownership before measuring or erasing ink.
enum SourceArtworkIsolation {

  // MARK: Internal

  static func refine(
    _ line: OCRResult.Line,
    width: Int,
    height: Int,
    background: OverlayColor,
    sample: (Int, Int) -> OverlayColor?
  ) -> OCRResult.Line {
    let line = excludingOutlinedAccessory(line, width: width, height: height, background: background, sample: sample)
    guard
      !line.isVerticalBlock, line.rowCount == 1, abs(line.rotationRadians) < 0.1,
      line.text.count <= 40, line.text.split(whereSeparator: \.isWhitespace).count <= 3,
      line.text.unicodeScalars.allSatisfy(\.isASCII)
    else { return line }
    let source = CGRect(
      x: line.boundingBoxNormalized.minX * CGFloat(width),
      y: line.boundingBoxNormalized.minY * CGFloat(height),
      width: line.boundingBoxNormalized.width * CGFloat(width),
      height: line.boundingBoxNormalized.height * CGFloat(height)
    ).integral
      .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !source.isEmpty, !source.isNull else { return line }
    var neutral = CGRect.null
    var colored = CGRect.null
    var neutralCount = 0
    var coloredCount = 0
    for y in Int(source.minY) ..< Int(source.maxY) {
      for x in Int(source.minX) ..< Int(source.maxX) {
        guard let color = sample(x, y) else { continue }
        let contrast = max(
          abs(color.red - background.red),
          abs(color.green - background.green),
          abs(color.blue - background.blue)
        )
        guard contrast > 0.3 else { continue }
        let chroma = max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue)
        let pixel = CGRect(x: x, y: y, width: 1, height: 1)
        if chroma < 0.12 { neutral = neutral.union(pixel)
          neutralCount += 1
        }
        if chroma > 0.3 { colored = colored.union(pixel)
          coloredCount += 1
        }
      }
    }
    guard
      neutralCount >= 20, coloredCount >= 8,
      colored.maxX + max(2, neutral.height * 0.18) < neutral.minX,
      colored.height > neutral.height * 1.15,
      colored.width < source.width * 0.45,
      colored.minX < source.minX + source.width * 0.15,
      neutral.width > source.width * 0.35
    else { return line }
    // A separately recognized colored word is text, not an unrecognized logo.
    guard !line.styleRuns.contains(where: { $0.box.maxX * CGFloat(width) <= colored.maxX + 1 }) else { return line }
    let pixels = neutral.insetBy(dx: -1, dy: -1).intersection(source)
    let textBox = CGRect(
      x: pixels.minX / CGFloat(width),
      y: pixels.minY / CGFloat(height),
      width: pixels.width / CGFloat(width),
      height: pixels.height / CGFloat(height)
    )
    return restricting(line, to: textBox)
  }

  // MARK: Private

  /// Empty radio/checkbox outlines can be absent from Vision's transcript while
  /// still enlarging its sole word box. A separated, taller closed outline is
  /// artwork; a same-sized O, an open stroke or a recognized word is not.
  private static func excludingOutlinedAccessory(
    _ line: OCRResult.Line,
    width: Int,
    height: Int,
    background: OverlayColor,
    sample: (Int, Int) -> OverlayColor?
  ) -> OCRResult.Line {
    let words = line.text.split(whereSeparator: \.isWhitespace)
    guard
      !line.isVerticalBlock, line.rowCount == 1, abs(line.rotationRadians) < 0.1,
      line.text.count >= 2, line.text.count <= 40,
      words.count <= 3, line.text.contains(where: \.isLetter),
      !(words.count > 1 && (words.first?.count == 1 || words.last?.count == 1))
    else { return line }
    let original = CGRect(
      x: line.boundingBoxNormalized.minX * CGFloat(width),
      y: line.boundingBoxNormalized.minY * CGFloat(height),
      width: line.boundingBoxNormalized.width * CGFloat(width),
      height: line.boundingBoxNormalized.height * CGFloat(height)
    )
    // Vision's rectangle can cut off the top of the ring. This bounded halo is
    // for proving closure only; the resulting text owner stays inside original.
    let search = original.insetBy(dx: -1, dy: -original.height * 0.3).integral
      .intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !search.isNull, !search.isEmpty else { return line }
    let x0 = Int(search.minX)
    let y0 = Int(search.minY)
    let columns = Int(search.width)
    let rows = Int(search.height)
    var ink = [Bool](repeating: false, count: columns * rows)
    var bands = [CGRect]()
    var band = CGRect.null
    for x in 0..<columns {
      var occupied = false
      for y in 0..<rows {
        guard let color = sample(x0 + x, y0 + y), color.distance(to: background) > 0.16 else { continue }
        ink[y * columns + x] = true
        occupied = true
        band = band.union(CGRect(x: x0 + x, y: y0 + y, width: 1, height: 1))
      }
      if !occupied, !band.isNull { bands.append(band)
        band = .null
      }
    }
    if !band.isNull { bands.append(band) }
    guard bands.count >= 2 else { return line }
    for trailing in [false, true] {
      let outline = trailing ? bands.last! : bands.first!
      let label = (trailing ? Array(bands.dropLast()) : Array(bands.dropFirst())).reduce(CGRect.null) { $0.union($1) }
      let gap = trailing ? outline.minX - label.maxX : label.minX - outline.maxX
      guard
        outline.width >= outline.height * 0.8, outline.width <= outline.height * 1.25,
        outline.height >= label.height * 1.3, gap >= label.height * 0.35,
        outline.width < original.width * 0.45, label.width > outline.width * 0.5,
        abs(outline.midY - label.midY) < outline.height * 0.3,
        !line.styleRuns.contains(where: { run in
          let box = CGRect(
            x: run.box.minX * CGFloat(width),
            y: run.box.minY * CGFloat(height),
            width: run.box.width * CGFloat(width),
            height: run.box.height * CGFloat(height)
          )
          return trailing ? box.minX >= label.maxX : box.maxX <= label.minX
        })
      else { continue }
      let cx = Int(outline.midX) - x0
      let cy = Int(outline.midY) - y0
      guard !ink[cy * columns + cx] else { continue }
      var visited = Set<Int>([cy * columns + cx])
      var queue = [cy * columns + cx]
      var cursor = 0
      var open = false
      while cursor < queue.count {
        let point = queue[cursor]
        cursor += 1
        let x = point % columns
        let y = point / columns
        if x == 0 || y == 0 || x == columns - 1 || y == rows - 1 { open = true
          break
        }
        for next in [point - 1, point + 1, point - columns, point + columns] {
          if !ink[next], visited.insert(next).inserted { queue.append(next) }
        }
      }
      guard !open, CGFloat(queue.count) >= outline.width * outline.height * 0.35 else { continue }
      let pixels = label.insetBy(dx: -1, dy: -1).intersection(original)
      let textBox = CGRect(
        x: pixels.minX / CGFloat(width),
        y: pixels.minY / CGFloat(height),
        width: pixels.width / CGFloat(width),
        height: pixels.height / CGFloat(height)
      )
      var result = restricting(line, to: textBox)
      result.alignment = trailing ? .trailing : .leading
      result.preventsJoining = true
      return result
    }
    return line
  }

  private static func restricting(_ line: OCRResult.Line, to textBox: CGRect) -> OCRResult.Line {
    var result = line
    result.boundingBoxNormalized = textBox
    result.orientedBox = nil
    result.horizontalGlyphScale = textBox.height
    result.replacementPatches = [.init(box: textBox)]
    result.styleRuns = line.styleRuns.map { run in
      var run = run
      run.box = run.box.intersection(textBox)
      run.inkBox = run.inkBox.map { $0.intersection(textBox) }
      return run
    }.filter { !$0.box.isNull && !$0.box.isEmpty }
    result.spacingAnchors = []
    return result
  }
}
