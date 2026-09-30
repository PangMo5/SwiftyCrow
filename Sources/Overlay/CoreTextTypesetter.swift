// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import CoreText
import Foundation

// MARK: - CoreTextTypesetter

/// Core Text is the source of truth for measurement and vertical glyph layout.
/// The SwiftUI layer only presents the resulting metrics/image, so the text we
/// measure and the text we draw share the same locale-aware line breaking,
/// fallback fonts, and vertical OpenType features.
enum CoreTextTypesetter {

  // MARK: Internal

  enum VerticalWrapping: Equatable, Sendable {
    case words
    case characters
  }

  struct FittedLayout {
    let fontSize: CGFloat
    let verticalWrapping: VerticalWrapping
    let isComplete: Bool
  }

  struct VerticalLayoutPlan: Equatable {
    let columns: [NSRange]
    let glyphExtent: CGFloat
    let columnAdvance: CGFloat
    let requiredWidth: CGFloat
    let fitsHeight: Bool

    var columnGap: CGFloat {
      columnAdvance - glyphExtent
    }
  }

  static func suggestedHorizontalSize(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedToWidth width: CGFloat
  ) -> CGSize {
    guard !text.isEmpty, width > 0 else { return .zero }
    let attributed = attributedString(
      text: text,
      language: language,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontDesign: fontDesign,
      vertical: false
    )
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let size = CTFramesetterSuggestFrameSizeWithConstraints(
      framesetter,
      CFRange(location: 0, length: attributed.length),
      nil,
      CGSize(width: width, height: 100_000),
      nil
    )
    return CGSize(width: ceil(size.width), height: ceil(size.height))
  }

  static func fittedLayout(
    text: String,
    language: Locale.Language,
    flow: OverlayTextFlow,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedTo size: CGSize,
    preferred: CGFloat,
    minimum: CGFloat,
    lineHeightMultiple: CGFloat = 1,
    styles: [OverlayTextStyleRun] = [],
    isUnderlined: Bool = false
  ) -> FittedLayout {
    guard
      preferred.isFinite, minimum.isFinite, size.width.isFinite, size.height.isFinite,
      preferred < CGFloat(Int.max / 4), minimum < CGFloat(Int.max / 4)
    else { return FittedLayout(fontSize: 0, verticalWrapping: .words, isComplete: false) }
    guard !text.isEmpty, size.width > 0, size.height > 0 else {
      return FittedLayout(fontSize: minimum, verticalWrapping: .words, isComplete: text.isEmpty)
    }
    let lowerBound = max(1, min(minimum, preferred))
    let upperBound = max(lowerBound, preferred)
    func fits(_ fontSize: CGFloat, wrapping: VerticalWrapping) -> Bool {
      Self.fits(
        text: text,
        language: language,
        flow: flow,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        in: size,
        lineHeightMultiple: lineHeightMultiple,
        verticalWrapping: wrapping,
        styles: styles,
        isUnderlined: isUnderlined
      )
    }
    if fits(upperBound, wrapping: .words) {
      return FittedLayout(fontSize: upperBound, verticalWrapping: .words, isComplete: true)
    }
    var wrapping = VerticalWrapping.words
    // Word priority is preferred at a readable size. Only when no word layout
    // fits even at the minimum do we explicitly choose emergency cluster breaks.
    if !fits(lowerBound, wrapping: .words) {
      guard case .vertical = flow else {
        return FittedLayout(fontSize: lowerBound, verticalWrapping: .words, isComplete: false)
      }
      wrapping = .characters
      if fits(upperBound, wrapping: wrapping) {
        return FittedLayout(fontSize: upperBound, verticalWrapping: wrapping, isComplete: true)
      }
      guard fits(lowerBound, wrapping: wrapping) else {
        return FittedLayout(fontSize: lowerBound, verticalWrapping: wrapping, isComplete: false)
      }
    }
    // Output is quantized to quarter points. Search that grid directly instead
    // of shaping sub-quarter trials which are discarded by final rounding.
    var low = Int(floor(lowerBound * 4))
    var high = Int(floor(upperBound * 4))
    while low < high {
      let candidate = low + (high - low + 1) / 2
      if fits(CGFloat(candidate) / 4, wrapping: wrapping) { low = candidate } else { high = candidate - 1 }
    }
    return FittedLayout(fontSize: max(lowerBound, CGFloat(low) / 4), verticalWrapping: wrapping, isComplete: true)
  }

  static func fits(
    text: String,
    language: Locale.Language,
    flow: OverlayTextFlow,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    in size: CGSize,
    lineHeightMultiple: CGFloat = 1,
    verticalWrapping: VerticalWrapping = .words,
    styles: [OverlayTextStyleRun] = [],
    isUnderlined: Bool = false
  ) -> Bool {
    guard !text.isEmpty else { return true }
    guard size.width > 0, size.height > 0, fontSize > 0 else { return false }
    if case .vertical = flow {
      let plan = verticalLayoutPlan(
        text: text,
        language: language,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        constrainedToHeight: size.height,
        wrapping: verticalWrapping,
        styles: styles,
        isUnderlined: isUnderlined
      )
      return !plan.columns.isEmpty && plan.fitsHeight && plan.requiredWidth <= size.width + 0.5
    }
    return HorizontalTextRenderer.plan(
      text: text,
      language: language,
      fontSize: fontSize,
      appearance: .init(background: .white, foreground: .black, confidence: 1, fontWeight: fontWeight, fontDesign: fontDesign),
      styles: styles,
      width: size.width,
      lineHeightMultiple: lineHeightMultiple,
      inlineDirection: flow.inlineDirection
    ).fits(size)
  }

  static func lineHeight(
    fontSize: CGFloat,
    language: Locale.Language,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard
  ) -> CGFloat {
    let font = localizedSystemFont(
      size: fontSize,
      language: language,
      weight: fontWeight,
      design: fontDesign
    )
    return ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
  }

  static func lineSpacing(
    fontSize: CGFloat,
    language: Locale.Language,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    lineHeightMultiple: CGFloat
  ) -> CGFloat {
    let natural = lineHeight(
      fontSize: fontSize,
      language: language,
      fontWeight: fontWeight,
      fontDesign: fontDesign
    )
    return max(0, natural * (max(1, lineHeightMultiple) - 1))
  }

  static func horizontalWordFittedFontSize(
    text: String,
    language: Locale.Language,
    constrainedToWidth width: CGFloat,
    preferred: CGFloat,
    minimum: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard
  ) -> CGFloat {
    guard width > 0, preferred > 0 else { return minimum }
    guard !usesCharacterWrapping(language) else { return preferred }
    let words = horizontalTokens(in: text, language: language)
    let tokens = fontDesign == .monospaced ? words : HorizontalHyphenation.pieces(in: words, language: language)
    guard !tokens.isEmpty else { return preferred }

    func longestWidth(at fontSize: CGFloat) -> CGFloat {
      tokens.reduce(0) { result, token in
        max(
          result,
          suggestedHorizontalSize(
            text: token,
            language: language,
            fontSize: fontSize,
            fontWeight: fontWeight,
            fontDesign: fontDesign,
            constrainedToWidth: 100_000
          ).width
        )
      }
    }

    let preferredWidth = longestWidth(at: preferred)
    guard preferredWidth > width else { return preferred }
    var fitted = max(minimum, floor(preferred * width / preferredWidth * 4) / 4)
    while fitted > minimum, longestWidth(at: fitted) > width {
      fitted = max(minimum, fitted - 0.25)
    }
    return fitted
  }

  static func horizontalWordsFit(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedToWidth width: CGFloat
  ) -> Bool {
    guard width > 0, fontSize > 0 else { return false }
    guard !usesCharacterWrapping(language) else { return true }
    let words = horizontalTokens(in: text, language: language)
    let tokens = fontDesign == .monospaced ? words : HorizontalHyphenation.pieces(in: words, language: language)
    return tokens.allSatisfy { token in
      suggestedHorizontalSize(
        text: token,
        language: language,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        constrainedToWidth: 100_000
      ).width <= width + 0.5
    }
  }

  static func verticalColumnsPreserveWords(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedToHeight height: CGFloat
  ) -> Bool {
    guard !usesCharacterWrapping(language) else { return true }
    let boundaries = Set(verticalLayoutPlan(
      text: text,
      language: language,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontDesign: fontDesign,
      constrainedToHeight: height
    ).columns.dropLast().map { $0.location + $0.length })
    return wrappingWordRanges(in: text).allSatisfy { token in
      !boundaries.contains(where: { $0 > token.location && $0 < token.location + token.length })
    }
  }

  static func verticalGlyphImage(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    size: CGSize,
    scale: CGFloat,
    progression: OverlayColumnProgression,
    wrapping: VerticalWrapping = .words,
    foreground: OverlayColor = .init(red: 1, green: 1, blue: 1, alpha: 1),
    baseBackground: OverlayColor = .white,
    styles: [OverlayTextStyleRun] = [],
    isUnderlined: Bool = false
  ) -> CGImage? {
    guard !text.isEmpty, size.width > 0, size.height > 0, scale > 0 else { return nil }
    let pixelWidth = max(1, Int(ceil(size.width * scale)))
    let pixelHeight = max(1, Int(ceil(size.height * scale)))
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }

    context.scaleBy(x: scale, y: scale)
    context.textMatrix = .identity
    context.setShouldAntialias(true)
    context.setAllowsFontSmoothing(true)
    let attributed = attributedString(
      text: text,
      language: language,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontDesign: fontDesign,
      vertical: true,
      styles: styles,
      isUnderlined: isUnderlined
    )
    // Paint monochrome glyphs with their actual color. Preserve intrinsic
    // color-font glyphs; a template tint would turn emoji into solid silhouettes.
    attributed.addAttribute(
      NSAttributedString.Key(kCTForegroundColorAttributeName as String),
      value: CGColor(colorSpace: colorSpace, components: [foreground.red, foreground.green, foreground.blue, foreground.alpha])!,
      range: NSRange(location: 0, length: attributed.length)
    )
    var hasDecorations = isUnderlined
    for style in validStyles(styles, length: attributed.length) {
      hasDecorations = hasDecorations || style.appearance.isUnderlined
      let color = style.appearance.foreground
      attributed.addAttribute(
        NSAttributedString.Key(kCTForegroundColorAttributeName as String),
        value: CGColor(colorSpace: colorSpace, components: [color.red, color.green, color.blue, color.alpha])!,
        range: style.range
      )
      if style.appearance.background.distance(to: baseBackground) > 0.025 {
        hasDecorations = true
        let background = style.appearance.background
        attributed.addAttribute(verticalBackgroundKey, value: NSColor(
          srgbRed: background.red,
          green: background.green,
          blue: background.blue,
          alpha: background.alpha
        ), range: style.range)
      } else {
        attributed.removeAttribute(verticalBackgroundKey, range: style.range)
      }
    }
    let colors = foregroundRanges(in: attributed)
    let uniformAlpha = colors.first?.color.alpha ?? 1
    let uniformOpacity = colors.allSatisfy { $0.color.alpha == uniformAlpha }
    if uniformOpacity {
      for item in colors {
        attributed.addAttribute(
          NSAttributedString.Key(kCTForegroundColorAttributeName as String),
          value: item.color.copy(alpha: 1)!,
          range: item.range
        )
      }
      context.setAlpha(uniformAlpha)
    }
    let plan = verticalLayoutPlan(
      attributed: attributed,
      language: language,
      fontSize: fontSize,
      constrainedToHeight: size.height,
      wrapping: wrapping
    )
    guard !plan.columns.isEmpty, plan.fitsHeight, plan.requiredWidth <= size.width + 0.5 else { return nil }

    let direction: CGFloat = progression == .rightToLeft ? -1 : 1
    let firstCenter = size.width / 2 - direction * CGFloat(plan.columns.count - 1) * plan.columnAdvance / 2
    let pathWidth = max(plan.glyphExtent, ceil(fontSize * 3.25))
    for (index, range) in plan.columns.enumerated() {
      let centerX = firstCenter + direction * CGFloat(index) * plan.columnAdvance
      let frame = makeFrame(
        attributed: attributed,
        range: CFRange(location: range.location, length: range.length),
        rect: CGRect(
          x: centerX - pathWidth / 2,
          y: 0,
          width: pathWidth,
          height: size.height
        ),
        progression: progression
      )
      let visible = CTFrameGetVisibleStringRange(frame)
      guard visible.location == range.location, visible.length >= range.length else { return nil }
      var baseline = CGPoint.zero
      CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 1), &baseline)
      let nativeCenter = CTFrameGetPath(frame).boundingBoxOfPath.minX + baseline.x
      // Frame origins include the base font's vertical metrics, which differ
      // greatly for proportional and monospaced fonts. Center the actual column.
      context.saveGState()
      context.translateBy(x: centerX - nativeCenter, y: 0)
      if hasDecorations {
        drawVerticalDecorations(
          in: frame,
          fontSize: fontSize,
          scale: scale,
          foregroundAlpha: uniformOpacity ? uniformAlpha : 1,
          context: context
        )
      }
      if uniformOpacity {
        CTFrameDraw(frame, context)
      } else {
        // Color fonts honor zero foreground alpha but ignore fractional alpha.
        // Paint native runs in their native order, applying each run's absolute
        // opacity once at the context. Uniform-opacity text keeps one draw.
        for line in CTFrameGetLines(frame) as! [CTLine] {
          for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTForegroundColorAttributeName] else { continue }
            let color = value as! CGColor
            guard color.alpha > 0 else { continue }
            let visibleRange = CTRunGetStringRange(run)
            let pass = NSMutableAttributedString(attributedString: attributed)
            pass.addAttribute(
              NSAttributedString.Key(kCTForegroundColorAttributeName as String),
              value: CGColor(gray: 0, alpha: 0),
              range: NSRange(location: 0, length: pass.length)
            )
            pass.addAttribute(
              NSAttributedString.Key(kCTForegroundColorAttributeName as String),
              value: color.copy(alpha: 1)!,
              range: NSRange(location: visibleRange.location, length: visibleRange.length)
            )
            let painted = makeFrame(
              attributed: pass,
              range: CFRange(location: range.location, length: range.length),
              rect: CGRect(x: centerX - pathWidth / 2, y: 0, width: pathWidth, height: size.height),
              progression: progression
            )
            context.saveGState()
            context.setAlpha(color.alpha)
            CTFrameDraw(painted, context)
            context.restoreGState()
          }
        }
      }
      context.restoreGState()
    }
    return context.makeImage()
  }

  static func verticalLayoutPlan(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedToHeight height: CGFloat,
    wrapping: VerticalWrapping = .words,
    styles: [OverlayTextStyleRun] = [],
    isUnderlined: Bool = false
  ) -> VerticalLayoutPlan {
    verticalLayoutPlan(
      attributed: attributedString(
        text: text,
        language: language,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        vertical: true,
        styles: styles,
        isUnderlined: isUnderlined
      ),
      language: language,
      fontSize: fontSize,
      constrainedToHeight: height,
      wrapping: wrapping
    )
  }

  static func horizontalInVerticalRanges(in text: String) -> [NSRange] {
    guard
      let expression = try? NSRegularExpression(
        pattern: "(?<![A-Za-z0-9])[A-Za-z0-9]{1,4}(?![A-Za-z0-9])"
      )
    else { return [] }
    let range = NSRange(text.startIndex ..< text.endIndex, in: text)
    return expression.matches(in: text, range: range).map(\.range)
  }

  static func usesCharacterWrapping(_ language: Locale.Language) -> Bool {
    switch language.script?.identifier {
    case "Hans",
         "Hant",
         "Jpan": true
    default: false
    }
  }

  /// Physical wrapping units keep attached punctuation and no-break spaces.
  /// Linguistic word tokens remain separate for dictionary hyphenation: their
  /// boundaries can split a Korean ending or quoted phrase that belongs together.
  static func wrappingWordRanges(in text: String) -> [NSRange] {
    wrappingWordPattern.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).map(\.range)
  }

  // MARK: Private

  private static let ellipsisPattern = try! NSRegularExpression(pattern: #"(?<!\.)\.{3}(?!\.)"#)

  private static let wrappingWordPattern = try! NSRegularExpression(pattern: #"(?:[^\s\u200B]|[\u00A0\u2007\u202F])+"#)

  private static let verticalBackgroundKey = NSAttributedString.Key("SwiftyCrowVerticalBackground")
  private static let verticalUnderlineKey = NSAttributedString.Key("SwiftyCrowVerticalUnderline")

  private static func drawVerticalDecorations(
    in frame: CTFrame,
    fontSize: CGFloat,
    scale: CGFloat,
    foregroundAlpha: CGFloat,
    context: CGContext
  ) {
    let lines = CTFrameGetLines(frame) as! [CTLine]
    var origins = [CGPoint](repeating: .zero, count: lines.count)
    CTFrameGetLineOrigins(frame, CFRange(), &origins)
    let pathOrigin = CTFrameGetPath(frame).boundingBoxOfPath.origin
    var fills = [(color: NSColor, path: CGMutablePath)]()
    var underlines = [(color: NSColor, path: CGMutablePath)]()
    func add(_ rect: CGRect, color: NSColor, to paths: inout [(color: NSColor, path: CGMutablePath)]) {
      if let match = paths.firstIndex(where: { $0.color.isEqual(color) }) { paths[match].path.addRect(rect) }
      else { let path = CGMutablePath()
        path.addRect(rect)
        paths.append((color, path))
      }
    }
    for (index, line) in lines.enumerated() {
      let origin = CGPoint(x: pathOrigin.x + origins[index].x, y: pathOrigin.y + origins[index].y)
      let ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      // Vertical cells use one em across the column, extended for actual ink.
      // A fallback font's global typographic ascent can be several em wide.
      let lower = ink.isNull ? -fontSize / 2 : min(-fontSize / 2, ink.minY)
      let upper = ink.isNull ? fontSize / 2 : max(fontSize / 2, ink.maxY)
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let bounds = typographicRunBounds(run, in: line) else { continue }
        // Core Text supplies logical advances and native line origins; only
        // the decoration rectangle is mapped into the vertical coordinate system.
        let rect = CGRect(
          x: origin.x + lower,
          y: origin.y - bounds.maxX,
          width: upper - lower,
          height: bounds.width
        )
        if let color = attributes[verticalBackgroundKey] as? NSColor { add(rect, color: color, to: &fills) }
        if
          attributes[verticalUnderlineKey] as? Bool == true,
          let foreground = attributes[kCTForegroundColorAttributeName]
        {
          let color = foreground as! CGColor
          let font = attributes[kCTFontAttributeName] as! CTFont
          let thickness = max(1 / scale, CTFontGetUnderlineThickness(font))
          let underline = CGRect(x: rect.minX - thickness, y: rect.minY, width: thickness, height: rect.height)
          add(underline, color: NSColor(cgColor: color.copy(alpha: color.alpha * foregroundAlpha)!)!, to: &underlines)
        }
      }
    }
    guard !fills.isEmpty || !underlines.isEmpty else { return }
    context.saveGState()
    context.setAlpha(1)
    for fill in fills + underlines {
      context.setFillColor(fill.color.cgColor)
      context.addPath(fill.path)
      context.drawPath(using: .fill)
    }
    context.restoreGState()
  }

  private static func typographicRunBounds(_ run: CTRun, in line: CTLine) -> CGRect? {
    var ascent: CGFloat = 0
    var descent: CGFloat = 0
    let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(), &ascent, &descent, nil))
    guard width.isFinite, width > 0, ascent.isFinite, descent.isFinite else { return nil }
    let range = CTRunGetStringRange(run)
    var secondaryStart: CGFloat = 0
    var secondaryEnd: CGFloat = 0
    let start = CTLineGetOffsetForStringIndex(line, range.location, &secondaryStart)
    let end = CTLineGetOffsetForStringIndex(line, range.location + range.length, &secondaryEnd)
    let candidates = [(start, end), (start, secondaryEnd), (secondaryStart, end), (secondaryStart, secondaryEnd)]
    guard let interval = candidates.min(by: { abs(abs($0.1 - $0.0) - width) < abs(abs($1.1 - $1.0) - width) }) else { return nil }
    return CGRect(x: min(interval.0, interval.1), y: -descent, width: abs(interval.1 - interval.0), height: ascent + descent)
  }

  private static func foregroundRanges(in text: NSAttributedString) -> [(range: NSRange, color: CGColor)] {
    var result = [(range: NSRange, color: CGColor)]()
    text.enumerateAttribute(
      NSAttributedString.Key(kCTForegroundColorAttributeName as String),
      in: NSRange(location: 0, length: text.length)
    ) { value, range, _ in
      if let value { result.append((range, value as! CGColor)) }
    }
    return result
  }

  private static func validStyles(_ styles: [OverlayTextStyleRun], length: Int) -> [OverlayTextStyleRun] {
    styles.filter { $0.range.location >= 0 && $0.range.location <= length && $0.range.length > 0
      && $0.range.length <= length - $0.range.location
    }
  }

  private static func attributedString(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight,
    fontDesign: OverlayFontDesign,
    vertical: Bool,
    lineHeightMultiple: CGFloat = 1,
    styles: [OverlayTextStyleRun] = [],
    isUnderlined: Bool = false
  ) -> NSMutableAttributedString {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): localizedSystemFont(
        size: fontSize,
        language: language,
        weight: fontWeight,
        design: fontDesign
      ),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
        red: 1,
        green: 1,
        blue: 1,
        alpha: 1
      ),
      NSAttributedString.Key(kCTLanguageAttributeName as String): language.maximalIdentifier,
    ]
    let attributed = NSMutableAttributedString(string: text, attributes: attributes)
    let wholeRange = NSRange(location: 0, length: attributed.length)
    let resolvedStyles = validStyles(styles, length: attributed.length)
    let underlineKey = vertical ? verticalUnderlineKey : .underlineStyle
    let underlineValue = vertical
      ? NSNumber(value: isUnderlined)
      : NSNumber(value: isUnderlined ? NSUnderlineStyle.single.rawValue : 0)
    attributed.addAttribute(underlineKey, value: underlineValue, range: wholeRange)
    for style in resolvedStyles {
      attributed.addAttributes([
        NSAttributedString.Key(kCTFontAttributeName as String): localizedSystemFont(
          size: fontSize,
          language: language,
          weight: style.appearance.fontWeight,
          design: style.appearance.fontDesign
        ),
        underlineKey: vertical
          ? NSNumber(value: style.appearance.isUnderlined)
          : NSNumber(value: style.appearance.isUnderlined ? NSUnderlineStyle.single.rawValue : 0),
      ], range: style.range)
    }
    if !vertical, lineHeightMultiple > 1 {
      attributed.addAttribute(
        NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
        value: wordWrappingParagraphStyle(
          lineSpacingAdjustment: lineSpacing(
            fontSize: fontSize,
            language: language,
            fontWeight: fontWeight,
            fontDesign: fontDesign,
            lineHeightMultiple: lineHeightMultiple
          )
        ),
        range: wholeRange
      )
      return attributed
    }
    guard vertical else { return attributed }

    attributed.addAttribute(
      NSAttributedString.Key(kCTVerticalFormsAttributeName as String),
      value: true,
      range: wholeRange
    )
    attributed.addAttribute(
      NSAttributedString.Key(kCTParagraphStyleAttributeName as String),
      value: wordWrappingParagraphStyle(),
      range: wholeRange
    )
    for range in horizontalInVerticalRanges(in: text) {
      attributed.addAttribute(
        NSAttributedString.Key(kCTHorizontalInVerticalFormsAttributeName as String),
        value: NSNumber(value: range.length),
        range: range
      )
    }
    for match in ellipsisPattern.matches(in: text, range: wholeRange) {
      let monospaced = (match.range.location..<NSMaxRange(match.range)).contains { offset in
        let design = resolvedStyles.last { NSLocationInRange(offset, $0.range) }?
          .appearance.fontDesign ?? fontDesign
        return design == .monospaced
      }
      if !monospaced {
        let dots = CTLineCreateWithAttributedString(attributed.attributedSubstring(from: match.range))
        let advance = CTLineGetTypographicBounds(dots, nil, nil, nil)
        if advance.isFinite, advance > fontSize {
          // Three ASCII periods represent one ellipsis. Keep the original
          // string/ranges/glyphs and tighten their vertical advance to one em.
          attributed.addAttribute(
            NSAttributedString.Key(kCTKernAttributeName as String),
            value: (fontSize - advance) / CGFloat(match.range.length),
            range: match.range
          )
        }
      }
    }
    return attributed
  }

  private static func verticalLayoutPlan(
    attributed: NSAttributedString,
    language: Locale.Language,
    fontSize: CGFloat,
    constrainedToHeight height: CGFloat,
    wrapping: VerticalWrapping
  ) -> VerticalLayoutPlan {
    guard attributed.length > 0, height > 0 else {
      return VerticalLayoutPlan(columns: [], glyphExtent: 0, columnAdvance: 0, requiredWidth: 0, fitsHeight: false)
    }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let text = attributed.string as NSString
    let words = wrapping == .characters || usesCharacterWrapping(language) ? [] : wrappingWordRanges(in: attributed.string)
    var columns = [NSRange]()
    var fitsHeight = true
    var glyphExtent = ceil(fontSize * 1.2)
    var offset = 0
    while offset < attributed.length {
      let suggested = CTTypesetterSuggestLineBreak(typesetter, offset, height)
      var length = adjustedToWordBoundary(
        proposedLength: suggested,
        offset: offset,
        words: words
      )
      if length <= 0 {
        length = CTTypesetterSuggestClusterBreak(typesetter, offset, height)
      }
      if length <= 0 {
        length = text.rangeOfComposedCharacterSequence(at: offset).length
      }
      length = min(max(1, length), attributed.length - offset)
      // An overfull word remains one column. Fitting must lower the font;
      // splitting it here would falsely report that the preferred size fits.
      let column = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
      let ink = CTLineGetBoundsWithOptions(column, [.useGlyphPathBounds])
      if !ink.isNull {
        var lower = ink.minY
        var upper = ink.maxY
        for run in CTLineGetGlyphRuns(column) as! [CTRun] {
          let attributes = CTRunGetAttributes(run) as NSDictionary
          if attributes[verticalUnderlineKey] as? Bool == true {
            let font = attributes[kCTFontAttributeName] as! CTFont
            // Reserve the one-point stroke needed at 1x as well as native
            // font thickness. Measurement is independent of display scale.
            lower = min(lower, min(-fontSize / 2, ink.minY) - max(1, CTFontGetUnderlineThickness(font)))
            upper = max(upper, fontSize / 2)
          }
        }
        glyphExtent = max(glyphExtent, ceil(2 * max(-lower, upper)))
      }
      fitsHeight = fitsHeight && length <= suggested && ink.maxX <= height + 0.5
      columns.append(NSRange(location: offset, length: length))
      offset += length
    }

    // A closing syllable/particle plus punctuation should not occupy a column
    // by itself. Move the last legal break slightly earlier, using Core Text's
    // CJK break rules, without changing text or crossing an explicit newline.
    if
      fontSize.isFinite, fontSize > 0, height.isFinite,
      usesCharacterWrapping(language), columns.count >= 2, let last = columns.last
    {
      func letters(_ range: NSRange) -> Int {
        text.substring(with: range).unicodeScalars.count(where: CharacterSet.alphanumerics.contains)
      }
      let previous = columns[columns.count - 2]
      let tail = NSUnionRange(previous, last)
      if letters(last) <= 1, text.rangeOfCharacter(from: .newlines, options: [], range: tail).location == NSNotFound {
        var available = height - fontSize
        while available > fontSize * 2 {
          let length = CTTypesetterSuggestLineBreak(typesetter, previous.location, available)
          guard length > 0 else { break }
          let first = NSRange(location: previous.location, length: length)
          let second = NSRange(location: NSMaxRange(first), length: NSMaxRange(last) - NSMaxRange(first))
          if
            length < previous.length, letters(first) >= 3, letters(second) >= 3,
            CTTypesetterSuggestLineBreak(typesetter, second.location, height) >= second.length
          {
            columns[columns.count - 2] = first
            columns[columns.count - 1] = second
            break
          }
          available -= fontSize
        }
      }
    }

    let columnAdvance = glyphExtent + ceil(max(1, fontSize * 0.1))
    let requiredWidth = glyphExtent + CGFloat(max(0, columns.count - 1)) * columnAdvance
    return VerticalLayoutPlan(
      columns: columns,
      glyphExtent: glyphExtent,
      columnAdvance: columnAdvance,
      requiredWidth: requiredWidth,
      fitsHeight: fitsHeight
    )
  }

  private static func wordWrappingParagraphStyle(
    lineSpacingAdjustment: CGFloat = 0
  ) -> CTParagraphStyle {
    var lineBreakMode = CTLineBreakMode.byWordWrapping
    var lineSpacingAdjustment = max(0, lineSpacingAdjustment)
    return withUnsafePointer(to: &lineBreakMode) { pointer in
      withUnsafePointer(to: &lineSpacingAdjustment) { spacingPointer in
        let settings = [
          CTParagraphStyleSetting(
            spec: .lineBreakMode,
            valueSize: MemoryLayout<CTLineBreakMode>.size,
            value: UnsafeRawPointer(pointer)
          ),
          CTParagraphStyleSetting(
            spec: .lineSpacingAdjustment,
            valueSize: MemoryLayout<CGFloat>.size,
            value: UnsafeRawPointer(spacingPointer)
          ),
        ]
        return settings.withUnsafeBufferPointer {
          CTParagraphStyleCreate($0.baseAddress!, $0.count)
        }
      }
    }
  }

  private static func adjustedToWordBoundary(
    proposedLength: Int,
    offset: Int,
    words: [NSRange]
  ) -> Int {
    let proposedEnd = offset + proposedLength
    for word in words {
      let end = NSMaxRange(word)
      guard proposedEnd >= word.location, proposedEnd < end, offset < end else { continue }
      if word.location > offset { return word.location - offset }
      return end - offset
    }
    return proposedLength
  }

  private static func localizedSystemFont(
    size: CGFloat,
    language _: Locale.Language,
    weight: OverlayFontWeight,
    design: OverlayFontDesign
  ) -> CTFont {
    switch design {
    case .standard:
      NSFont.systemFont(ofSize: max(1, size), weight: weight.nsFontWeight) as CTFont
    case .monospaced:
      NSFont.monospacedSystemFont(ofSize: max(1, size), weight: weight.nsFontWeight) as CTFont
    }
  }

  private static func horizontalTokens(
    in text: String,
    language: Locale.Language
  ) -> [String] {
    horizontalTokenRanges(in: text, language: language).compactMap { range in
      Range(range, in: text).map { String(text[$0]) }
    }
  }

  private static func horizontalTokenRanges(
    in text: String,
    language: Locale.Language
  ) -> [NSRange] {
    HorizontalHyphenation.wordRanges(in: text, language: language)
  }

  private static func makeFrame(
    attributed: NSAttributedString,
    size: CGSize,
    progression: OverlayColumnProgression?
  ) -> CTFrame {
    makeFrame(
      attributed: attributed,
      range: CFRange(location: 0, length: attributed.length),
      rect: CGRect(origin: .zero, size: size),
      progression: progression
    )
  }

  private static func makeFrame(
    attributed: NSAttributedString,
    range: CFRange,
    rect: CGRect,
    progression: OverlayColumnProgression?
  ) -> CTFrame {
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: rect, transform: nil)
    let attributes: CFDictionary? = progression.map { progression in
      let value: UInt32 =
        switch progression {
        case .rightToLeft: CTFrameProgression.rightToLeft.rawValue
        case .leftToRight: CTFrameProgression.leftToRight.rawValue
        }
      return [
        kCTFrameProgressionAttributeName as String: NSNumber(value: value)
      ] as CFDictionary
    }
    return CTFramesetterCreateFrame(
      framesetter,
      range,
      path,
      attributes
    )
  }
}

extension OverlayFontWeight {
  var nsFontWeight: NSFont.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
}
