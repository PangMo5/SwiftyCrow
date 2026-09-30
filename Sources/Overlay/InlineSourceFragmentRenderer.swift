// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText

/// Collapse source literals before shaping: a run delegate applies its width
/// per glyph, so a multi-character OCR range must become one object character.
enum InlineSourceFragmentRenderer {

  // MARK: Internal

  struct Content {
    var text: String
    var styles: [OverlayTextStyleRun]
    var changed: Bool
    var isValid = true
  }

  static func collapsed(text: String, styles: [OverlayTextStyleRun]) -> Content {
    let fragments = styles.filter { $0.sourceFragment != nil }.sorted { $0.range.location < $1.range.location }
    guard !fragments.isEmpty else { return Content(text: text, styles: styles, changed: false) }
    let original = text as NSString
    var cursor = 0
    var result = ""
    var mapped = [OverlayTextStyleRun]()
    var replacements = [(source: NSRange, target: NSRange)]()
    for fragment in fragments {
      guard fragment.range.location >= cursor, fragment.range.length > 0, Range(fragment.range, in: text) != nil else {
        // Malformed fragment ownership cannot produce a partially collapsed line.
        return Content(text: "", styles: [], changed: false, isValid: false)
      }
      result += original.substring(with: NSRange(location: cursor, length: fragment.range.location - cursor))
      let range = NSRange(location: result.utf16.count, length: 1)
      replacements.append((fragment.range, range))
      var style = fragment
      style.range = range
      mapped.append(style)
      result += "\u{FFFC}"
      cursor = NSMaxRange(fragment.range)
    }
    result += original.substring(from: cursor)
    for style in styles where style.sourceFragment == nil {
      guard Range(style.range, in: text) != nil else { continue }
      var segments = [style.range]
      for replacement in replacements {
        segments = segments.flatMap { range -> [NSRange] in
          guard NSIntersectionRange(range, replacement.source).length > 0 else { return [range] }
          var pieces = [NSRange]()
          if range.location < replacement.source.location {
            pieces.append(NSRange(location: range.location, length: replacement.source.location - range.location))
          }
          if NSMaxRange(range) > NSMaxRange(replacement.source) {
            pieces.append(NSRange(
              location: NSMaxRange(replacement.source),
              length: NSMaxRange(range) - NSMaxRange(replacement.source)
            ))
          }
          return pieces
        }
      }
      for segment in segments {
        let shift = replacements.filter { NSMaxRange($0.source) <= segment.location }.reduce(0) { $0 + $1.source.length - 1 }
        var run = style
        run.range = NSRange(location: segment.location - shift, length: segment.length)
        mapped.append(run)
      }
    }
    return Content(text: result, styles: mapped.sorted { $0.range.location < $1.range.location }, changed: true)
  }

  static func apply(
    _ fragment: OverlayInlineSourceFragment,
    to text: NSMutableAttributedString,
    range: NSRange,
    fontSize: CGFloat
  ) -> Bool {
    guard range.length == 1, fontSize.isFinite, fontSize > 0 else { return false }
    let run = Run(fragment, fontSize: fontSize)
    var callbacks = CTRunDelegateCallbacks(
      version: kCTRunDelegateVersion1,
      dealloc: { Unmanaged<Run>.fromOpaque($0).release() },
      getAscent: { Unmanaged<Run>.fromOpaque($0).takeUnretainedValue().ascent },
      getDescent: { Unmanaged<Run>.fromOpaque($0).takeUnretainedValue().descent },
      getWidth: { Unmanaged<Run>.fromOpaque($0).takeUnretainedValue().width }
    )
    let pointer = Unmanaged.passRetained(run).toOpaque()
    guard let delegate = CTRunDelegateCreate(&callbacks, pointer) else {
      Unmanaged<Run>.fromOpaque(pointer).release()
      return false
    }
    text.addAttributes([
      fragmentKey: run,
      NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 0),
      .underlineStyle: 0,
    ], range: range)
    text.removeAttribute(.backgroundColor, range: range)
    return true
  }

  static func bounds(in line: CTLine) -> CGRect {
    fragments(in: line).reduce(CGRect.null) { $0.union($1.rect) }
  }

  static func draw(in line: CTLine, baseline: CGPoint, context: CGContext) {
    let pixelX = hypot(context.ctm.a, context.ctm.b)
    let pixelY = hypot(context.ctm.c, context.ctm.d)
    guard pixelX > 0, pixelY > 0 else { return }
    for item in fragments(in: line) {
      guard let image = item.run.fragment.image else { continue }
      var rect = item.rect.offsetBy(dx: baseline.x, dy: baseline.y)
      rect.origin.x = (rect.minX * pixelX).rounded() / pixelX
      rect.origin.y = (rect.minY * pixelY).rounded() / pixelY
      context.saveGState()
      context.interpolationQuality = abs(item.run.scale - 1) < 0.001 ? .none : .high
      context.draw(image, in: rect)
      context.restoreGState()
    }
  }

  // MARK: Private

  private final class Run {

    // MARK: Lifecycle

    init(_ fragment: OverlayInlineSourceFragment, fontSize: CGFloat) {
      self.fragment = fragment
      scale = fontSize / fragment.referenceFontSize
    }

    // MARK: Internal

    let fragment: OverlayInlineSourceFragment
    let scale: CGFloat

    var width: CGFloat {
      CGFloat(fragment.width) * scale
    }

    var ascent: CGFloat {
      (CGFloat(fragment.height) - fragment.descent) * scale
    }

    var descent: CGFloat {
      fragment.descent * scale
    }
  }

  private static let fragmentKey = NSAttributedString.Key("SwiftyCrowSourceFragment")

  private static func fragments(in line: CTLine) -> [(run: Run, rect: CGRect)] {
    (CTLineGetGlyphRuns(line) as! [CTRun]).compactMap { glyphRun in
      let attributes = CTRunGetAttributes(glyphRun) as NSDictionary
      guard let run = attributes[fragmentKey] as? Run, CTRunGetGlyphCount(glyphRun) == 1 else { return nil }
      var position = CGPoint.zero
      CTRunGetPositions(glyphRun, CFRange(location: 0, length: 1), &position)
      return (run, CGRect(x: position.x, y: position.y - run.descent, width: run.width, height: run.ascent + run.descent))
    }
  }
}
