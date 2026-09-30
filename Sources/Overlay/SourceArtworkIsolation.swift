// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Vision can include a publisher's colored emblem in the word rectangle even
/// though its transcript contains only the name. Separate observed artwork
/// from neutral text ink before sampling colors or constructing erasure masks.
enum SourceArtworkIsolation {
  static func refine(
    _ line: OCRResult.Line,
    width: Int,
    height: Int,
    background: OverlayColor,
    sample: (Int, Int) -> OverlayColor?
  ) -> OCRResult.Line {
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
    var result = line
    result.boundingBoxNormalized = textBox
    result.orientedBox = nil
    result.horizontalGlyphScale = textBox.height
    result.replacementPatches = [.init(box: textBox)]
    result.styleRuns = line.styleRuns.map { run in
      var run = run
      run.box = run.box.intersection(textBox)
      return run
    }.filter { !$0.box.isNull && !$0.box.isEmpty }
    return result
  }
}
