// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText

/// One layout for both fitting and drawing. OCR boxes describe visible ink,
/// not a font's ascent/leading rectangle. SwiftUI Text previously fitted again
/// after Core Text, shrinking or truncating a result that had already been fitted.
enum HorizontalTextRenderer {

  // MARK: Internal

  struct Plan {
    let lines: [CTLine]
    let origins: [CGPoint]
    let inkBounds: CGRect
    let complete: Bool
    var usesContainerCoordinates = false
    var hyphens = [Int: CTLine]()

    func ink(for index: Int) -> CGRect {
      HorizontalTextRenderer.ink(lines[index], hyphen: hyphens[index])
    }

    func fits(_ size: CGSize) -> Bool {
      complete && inkBounds.width <= size.width + 0.00001 && inkBounds.height <= size.height + 0.00001
        && (!usesContainerCoordinates || (inkBounds.minX >= -0.5 && inkBounds.minY >= -0.5
            && inkBounds.maxX <= size.width + 0.5 && inkBounds.maxY <= size.height + 0.5))
    }
  }

  static func plan(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    appearance: OverlaySourceAppearance,
    styles: [OverlayTextStyleRun],
    width: CGFloat,
    lineHeightMultiple: CGFloat,
    regions: [CGRect] = [],
    height: CGFloat? = nil,
    alignment: OverlayTextAlignment = .leading,
    wordBreaks: [NSRange: [HorizontalHyphenation.Boundary]]? = nil,
    inlineDirection: OverlayInlineDirection? = nil
  ) -> Plan {
    let content = InlineSourceFragmentRenderer.collapsed(text: text, styles: styles)
    guard content.isValid else { return Plan(lines: [], origins: [], inkBounds: .zero, complete: false) }
    let text = content.text
    let styles = content.styles
    let attributed = NSMutableAttributedString(string: text, attributes: attributes(
      appearance,
      fontSize: fontSize,
      language: language
    ))
    for style in styles where style.range.location >= 0 && NSMaxRange(style.range) <= attributed.length {
      attributed.addAttributes(attributes(style.appearance, fontSize: fontSize, language: language), range: style.range)
      if colorDistance(style.appearance.background, appearance.background) > 0.025 {
        attributed.addAttribute(
          .backgroundColor,
          value: NSColor(cgColor: cgColor(style.appearance.background))!,
          range: style.range
        )
      }
      if let fragment = style.sourceFragment {
        guard InlineSourceFragmentRenderer.apply(fragment, to: attributed, range: style.range, fontSize: fontSize) else {
          return Plan(lines: [], origins: [], inkBounds: .zero, complete: false)
        }
      }
    }
    let paragraph = NSMutableParagraphStyle()
    let direction = inlineDirection ?? OverlayTextFlowResolver.horizontalDirection(text: text, language: language)
    paragraph.baseWritingDirection = direction == .rightToLeft ? .rightToLeft : .leftToRight
    // Physical alignment is applied by our drawing plan. Core Text should
    // shape the chosen bidi paragraph without also choosing a screen edge.
    paragraph.alignment = .left
    paragraph.lineBreakMode = .byWordWrapping
    paragraph.lineBreakStrategy = .hangulWordPriority
    if OCRTextSemantics.beginsListItem(text) {
      paragraph.headIndent = fontSize * 0.85
    }
    paragraph.lineSpacing = CoreTextTypesetter.lineSpacing(
      fontSize: fontSize,
      language: language,
      fontWeight: appearance.fontWeight,
      fontDesign: appearance.fontDesign,
      isItalic: appearance.isItalic,
      lineHeightMultiple: lineHeightMultiple
    )
    attributed.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: attributed.length))
    let hyphenation = hyphenation(
      in: attributed,
      width: regions.isEmpty ? width : 0,
      boundaries: (content.changed ? nil : wordBreaks) ?? HorizontalHyphenation.wordBreaks(in: text, language: language)
    )
    if !regions.isEmpty, let height {
      return shapedPlan(
        attributed,
        size: CGSize(width: width, height: height),
        regions: regions,
        alignment: alignment,
        paragraph: paragraph,
        keepsWords: !CoreTextTypesetter.usesCharacterWrapping(language),
        hyphenation: hyphenation
      )
    }
    if language.languageCode?.identifier == "ko" || !hyphenation.isEmpty {
      return wordPlan(
        attributed,
        width: width,
        paragraph: paragraph,
        keepsWords: !CoreTextTypesetter.usesCharacterWrapping(language),
        hyphenation: hyphenation
      )
    }
    let frame = CTFramesetterCreateFrame(
      CTFramesetterCreateWithAttributedString(attributed),
      CFRange(location: 0, length: attributed.length),
      CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: 100_000), transform: nil),
      nil
    )
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
    var bounds = CGRect.null
    for (line, origin) in zip(lines, origins) {
      let ink = ink(line, hyphen: nil)
      if !ink.isEmpty { bounds = bounds.union(ink.offsetBy(dx: origin.x, dy: origin.y)) }
    }
    let visible = CTFrameGetVisibleStringRange(frame)
    return Plan(
      lines: lines,
      origins: origins,
      inkBounds: bounds.isNull ? .zero : bounds,
      complete: visible.location == 0 && visible.length == attributed.length
    )
  }

  static func fittedLayout(
    line: OverlayLine,
    in size: CGSize,
    preferred: CGFloat,
    lineHeightMultiple: CGFloat,
    regions: [CGRect] = [],
    alignment: OverlayTextAlignment = .leading,
    maximumLineCount: Int? = nil,
    inlineDirection: OverlayInlineDirection? = nil
  ) -> CoreTextTypesetter.FittedLayout {
    let wordBreaks = HorizontalHyphenation.wordBreaks(in: line.displayedText, language: line.displayedLanguage)
    let direction = inlineDirection ?? OverlayTextFlowResolver.horizontalDirection(
      text: line.displayedText,
      language: line.displayedLanguage
    )
    func fits(_ fontSize: CGFloat) -> Bool {
      let result = plan(
        text: line.displayedText,
        language: line.displayedLanguage,
        fontSize: fontSize,
        appearance: line.source.appearance,
        styles: line.displayedStyleRuns,
        width: size.width,
        lineHeightMultiple: lineHeightMultiple,
        regions: regions,
        height: size.height,
        alignment: alignment,
        wordBreaks: wordBreaks,
        inlineDirection: direction
      )
      return result.fits(size) && (maximumLineCount.map { result.lines.count <= $0 } ?? true)
    }
    if fits(preferred) { return .init(fontSize: preferred, verticalWrapping: .words, isComplete: true) }
    var low: CGFloat = min(4, preferred)
    var high = max(low, preferred)
    for _ in 0 ..< 10 {
      let candidate = (low + high) / 2
      if fits(candidate) { low = candidate } else { high = candidate }
    }
    // Core Text's optical metrics/line-break choices are not monotonic across
    // every fractional size. A valid binary-search sample can stop fitting
    // after size quantization. Validate the size actually drawn.
    var fitted = floor(low * 64) / 64
    var complete = fits(fitted)
    while fitted > min(4, preferred), !complete {
      fitted -= 1 / 64
      complete = fits(fitted)
    }
    return .init(fontSize: fitted, verticalWrapping: .words, isComplete: complete)
  }

  static func image(for placement: OverlayPlacement, scale: CGFloat) -> CGImage? {
    let size = placement.frame.size
    guard size.width > 0, size.height > 0, scale > 0 else { return nil }
    let plan = plan(for: placement)
    guard plan.fits(size) else { return nil }
    guard
      let context = CGContext(
        data: nil,
        width: Int(ceil(size.width * scale)),
        height: Int(ceil(size.height * scale)),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.scaleBy(x: scale, y: scale)
    guard draw(placement, in: context) else { return nil }
    return context.makeImage()
  }

  /// Draw into the final pixel grid. An intermediate ceil-sized bitmap would
  /// resample small glyphs when stretched back into fractional layout bounds.
  @discardableResult
  static func draw(_ placement: OverlayPlacement, in context: CGContext) -> Bool {
    let size = placement.frame.size
    let plan = plan(for: placement)
    guard plan.fits(size) else { return false }
    context.saveGState()
    defer { context.restoreGState() }
    if !placement.textFlowRegions.isEmpty {
      context.addRects(placement.textFlowRegions.map {
        CGRect(x: $0.minX, y: size.height - $0.maxY, width: $0.width, height: $0.height)
      })
      context.clip()
    }
    for (index, line) in plan.lines.enumerated() {
      let baseline = drawingOrigin(for: index, plan: plan, placement: placement)
      draw(line, at: baseline, in: context)
      if let hyphen = plan.hyphens[index] {
        draw(hyphen, at: CGPoint(x: baseline.x + CTLineGetTypographicBounds(line, nil, nil, nil), y: baseline.y), in: context)
      }
    }
    return true
  }

  /// Uses the compositor's exact baseline/alignment calculation. Decorative
  /// runs include their typographic envelope so backgrounds/underlines cannot
  /// be overlooked when checking retained source content.
  static func paintedBounds(for placement: OverlayPlacement) -> [CGRect] {
    let plan = plan(for: placement)
    return plan.lines.indices.map { index in
      let line = plan.lines[index]
      var ink = plan.ink(for: index)
      let decorated = (CTLineGetGlyphRuns(line) as! [CTRun]).contains { run in
        let attributes = CTRunGetAttributes(run) as NSDictionary
        return (attributes[NSAttributedString.Key.underlineStyle] as? Int ?? 0) != 0
          || attributes[NSAttributedString.Key.backgroundColor] != nil
      }
      if decorated {
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        ink = ink.union(CGRect(x: 0, y: -descent, width: width, height: ascent + descent))
      }
      let origin = drawingOrigin(for: index, plan: plan, placement: placement)
      ink = ink.offsetBy(dx: origin.x, dy: origin.y)
      return CGRect(
        x: placement.frame.minX + ink.minX,
        y: placement.frame.maxY - ink.maxY,
        width: ink.width,
        height: ink.height
      )
    }
  }

  static func plan(for placement: OverlayPlacement) -> Plan {
    plan(
      text: placement.line.displayedText,
      language: placement.line.displayedLanguage,
      fontSize: placement.fontSize,
      appearance: placement.line.source.appearance,
      styles: placement.line.displayedStyleRuns,
      width: placement.frame.width,
      lineHeightMultiple: placement.lineHeightMultiple,
      regions: placement.textFlowRegions,
      height: placement.frame.height,
      alignment: placement.alignment,
      inlineDirection: placement.flow.inlineDirection
    )
  }

  // MARK: Private

  private static func drawingOrigin(for index: Int, plan: Plan, placement: OverlayPlacement) -> CGPoint {
    let size = placement.frame.size
    let yOffset: CGFloat =
      if plan.usesContainerCoordinates { 0 }
      else if case .horizontal(let rows) = placement.line.source.layout, rows > 1 {
        size.height - plan.inkBounds.maxY
      } else {
        (size.height - plan.inkBounds.height) / 2 - plan.inkBounds.minY
      }
    let origin = plan.origins[index]
    let ink = plan.ink(for: index)
    let x: CGFloat =
      if plan.usesContainerCoordinates { origin.x }
      else { switch placement.alignment {
      case .leading: origin.x - ink.minX
      case .center: (size.width - ink.width) / 2 - ink.minX
      case .trailing: size.width - ink.maxX
      } }
    return CGPoint(x: x, y: origin.y + yOffset)
  }

  /// Core Text retains shaping/bidi/cluster ownership. Source corridors only
  /// supply the available width; fitting and drawing consume this exact plan.
  private static func shapedPlan(
    _ attributed: NSAttributedString,
    size: CGSize,
    regions: [CGRect],
    alignment: OverlayTextAlignment,
    paragraph: NSParagraphStyle,
    keepsWords: Bool,
    hyphenation: [NSRange: [HorizontalHyphenation.Boundary]]
  ) -> Plan {
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let reference = CTLineCreateWithAttributedString(attributed)
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    var leading: CGFloat = 0
    _ = CTLineGetTypographicBounds(reference, &ascent, &descent, &leading)
    let extent = max(1, ascent + descent)
    let advance = max(1, extent + leading + paragraph.lineSpacing)
    let text = attributed.string as NSString
    let words = keepsWords
      ? CoreTextTypesetter.wrappingWordRanges(in: attributed.string)
      : []
    let regions = regions.sorted { $0.minY < $1.minY }
    var lines = [CTLine]()
    var hyphens = [Int: CTLine]()
    var origins = [CGPoint]()
    var bounds = CGRect.null
    var offset = 0
    var top: CGFloat = 0
    while offset < text.length, top + extent <= size.height + 0.5 {
      let bands = regions.filter { $0.maxY > top + 0.01 && $0.minY < top + extent - 0.01 }
      var covered = top
      for band in bands where band.minY <= covered + 0.5 { covered = max(covered, band.maxY) }
      let left = bands.map(\.minX).max() ?? 0
      let right = bands.map(\.maxX).min() ?? 0
      let startsParagraph = offset == 0 || text.character(at: offset - 1) == 10
      let indent = startsParagraph ? paragraph.firstLineHeadIndent : paragraph.headIndent
      let width = right - left - indent
      guard covered >= top + extent - 0.5, width > 1 else { top += advance
        continue
      }
      let next = nextLine(
        attributed,
        typesetter: typesetter,
        offset: offset,
        width: width,
        words: words,
        hyphenation: hyphenation
      )
      let length = next.length
      guard length > 0 else { break }
      let line = next.line
      let ink = ink(line, hyphen: next.hyphen)
      guard ink.width <= width + 0.5 else { break }
      let x: CGFloat =
        switch alignment {
        case .leading: left + indent - ink.minX
        case .center: (left + right - ink.width) / 2 - ink.minX
        case .trailing: right - indent - ink.maxX
        }
      let origin = CGPoint(x: x, y: size.height - top - ascent)
      if !ink.isEmpty { bounds = bounds.union(ink.offsetBy(dx: origin.x, dy: origin.y)) }
      hyphens[lines.count] = next.hyphen
      lines.append(line)
      origins.append(origin)
      offset += length
      top += advance
    }
    return Plan(
      lines: lines,
      origins: origins,
      inkBounds: bounds.isNull ? .zero : bounds,
      complete: offset == text.length,
      usesContainerCoordinates: true,
      hyphens: hyphens
    )
  }

  /// Core Text's frame API can split Hangul syllables despite the paragraph's
  /// word-priority setting. Keep words intact unless a native dictionary permits
  /// a visible hyphen; an overfull syllable/word makes fitting reduce the font.
  private static func wordPlan(
    _ attributed: NSAttributedString,
    width: CGFloat,
    paragraph: NSParagraphStyle,
    keepsWords: Bool,
    hyphenation: [NSRange: [HorizontalHyphenation.Boundary]]
  ) -> Plan {
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let text = attributed.string as NSString
    let words = keepsWords
      ? CoreTextTypesetter.wrappingWordRanges(in: attributed.string)
      : []
    var lines = [CTLine]()
    var hyphens = [Int: CTLine]()
    var origins = [CGPoint]()
    var bounds = CGRect.null
    var offset = 0
    var baseline: CGFloat = 0
    var previousDescent: CGFloat = 0
    var previousLeading: CGFloat = 0
    while offset < text.length {
      let startsParagraph = offset == 0 || text.character(at: offset - 1) == 10
      let indent = startsParagraph ? paragraph.firstLineHeadIndent : paragraph.headIndent
      let next = nextLine(
        attributed,
        typesetter: typesetter,
        offset: offset,
        width: max(1, width - indent),
        words: words,
        hyphenation: hyphenation
      )
      let length = next.length
      guard length > 0 else { break }
      let line = next.line
      var ascent: CGFloat = 0
      var descent: CGFloat = 0
      var leading: CGFloat = 0
      _ = CTLineGetTypographicBounds(line, &ascent, &descent, &leading)
      if !lines.isEmpty { baseline -= previousDescent + ascent + max(previousLeading, leading) + paragraph.lineSpacing }
      let origin = CGPoint(x: indent, y: baseline)
      let ink = ink(line, hyphen: next.hyphen)
      if !ink.isEmpty { bounds = bounds.union(ink.offsetBy(dx: origin.x, dy: origin.y)) }
      hyphens[lines.count] = next.hyphen
      lines.append(line)
      origins.append(origin)
      previousDescent = descent
      previousLeading = leading
      offset += length
    }
    return Plan(
      lines: lines,
      origins: origins,
      inkBounds: bounds.isNull ? .zero : bounds,
      complete: offset == text.length,
      hyphens: hyphens
    )
  }

  private static func draw(_ line: CTLine, at baseline: CGPoint, in context: CGContext) {
    // CTLineDraw paints native backgrounds, including RTL geometry and alpha.
    // A manual rectangle here would composite translucent highlights twice.
    context.textPosition = baseline
    CTLineDraw(line, context)
    InlineSourceFragmentRenderer.draw(in: line, baseline: baseline, context: context)
  }

  private static func ink(_ line: CTLine, hyphen: CTLine?) -> CGRect {
    // Outlines alone omit the antialias fringe. Reserve it inside the original
    // owner so final clipping cannot shave the bottom of a fitted glyph.
    var bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).union(InlineSourceFragmentRenderer.bounds(in: line))
    let hasGlyphs = (CTLineGetGlyphRuns(line) as! [CTRun]).contains {
      (CTRunGetAttributes($0) as NSDictionary)[kCTRunDelegateAttributeName] == nil && CTRunGetGlyphCount($0) > 0
    }
    if hasGlyphs { bounds = bounds.insetBy(dx: -0.5, dy: -0.5) }
    guard let hyphen else { return bounds }
    return bounds.union(CTLineGetBoundsWithOptions(hyphen, [.useGlyphPathBounds]).offsetBy(
      dx: CTLineGetTypographicBounds(line, nil, nil, nil),
      dy: 0
    ))
  }

  private static func hyphenation(
    in attributed: NSAttributedString,
    width: CGFloat,
    boundaries: [NSRange: [HorizontalHyphenation.Boundary]]
  ) -> [NSRange: [HorizontalHyphenation.Boundary]] {
    var result = [NSRange: [HorizontalHyphenation.Boundary]]()
    for (range, points) in boundaries {
      var monospaced = false
      attributed.enumerateAttribute(.font, in: range) { value, _, _ in
        if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.monoSpace) { monospaced = true }
      }
      guard !monospaced else { continue }
      if width > 0 {
        let line = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: range))
        guard CTLineGetTypographicBounds(line, nil, nil, nil) > width else { continue }
      }
      result[range] = points
    }
    return result
  }

  private static func nextLine(
    _ attributed: NSAttributedString,
    typesetter: CTTypesetter,
    offset: Int,
    width: CGFloat,
    words: [NSRange],
    hyphenation: [NSRange: [HorizontalHyphenation.Boundary]]
  ) -> (line: CTLine, hyphen: CTLine?, length: Int) {
    var length = CTTypesetterSuggestLineBreak(typesetter, offset, Double(width))
    let end = offset + length
    var suffix: CTLine?
    if let (word, points) = hyphenation.first(where: { $0.key.location < end && NSMaxRange($0.key) > end }) {
      // Dictionary tokens omit attached punctuation and no-break spaces.
      // Move the complete wrapping unit, or hyphenate inside it while keeping
      // its prefix on this line; never create a break at a glued word start.
      let unit = words.first { $0.location <= word.location && NSMaxRange($0) >= NSMaxRange(word) } ?? word
      if unit.location > offset {
        length = unit.location - offset
      } else {
        // Only dictionary boundaries may split this word. If even its smallest
        // syllable cannot fit, retain the overfull line so font fitting rejects it.
        let candidates = points.filter { word.location + $0.offset > offset }
        if let first = candidates.first {
          var chosen = first
          for point in candidates {
            let count = word.location + point.offset - offset
            let line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: count))
            let hyphen = CTLineCreateWithAttributedString(NSAttributedString(
              string: point.hyphen,
              attributes: attributed.attributes(at: offset + count - 1, effectiveRange: nil)
            ))
            if ink(line, hyphen: hyphen).width <= width + 0.5 { chosen = point }
          }
          length = word.location + chosen.offset - offset
          suffix = CTLineCreateWithAttributedString(NSAttributedString(
            string: chosen.hyphen,
            attributes: attributed.attributes(at: offset + length - 1, effectiveRange: nil)
          ))
        } else {
          length = NSMaxRange(unit) - offset
        }
      }
    } else if let word = words.first(where: { $0.location < end && NSMaxRange($0) > end }) {
      length = word.location > offset ? word.location - offset : NSMaxRange(word) - offset
    }
    return (CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length)), suffix, length)
  }

  private static func attributes(
    _ appearance: OverlaySourceAppearance,
    fontSize: CGFloat,
    language: Locale.Language
  ) -> [NSAttributedString.Key: Any] {
    let font = OverlayTypography.font(
      size: fontSize,
      weight: appearance.fontWeight,
      design: appearance.fontDesign,
      isItalic: appearance.isItalic
    )
    return [
      .font: font,
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): cgColor(appearance.foreground),
      NSAttributedString.Key(kCTLanguageAttributeName as String): language.maximalIdentifier,
      .underlineStyle: appearance.isUnderlined ? NSUnderlineStyle.single.rawValue : 0,
    ]
  }

  private static func cgColor(_ color: OverlayColor) -> CGColor {
    CGColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
  }

  private static func colorDistance(_ lhs: OverlayColor, _ rhs: OverlayColor) -> CGFloat {
    max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue))
  }
}
