// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import CoreText
import Foundation
import NaturalLanguage

// MARK: - CoreTextTypesetter

/// Core Text is the source of truth for measurement and vertical glyph layout.
/// The SwiftUI layer only presents the resulting metrics/image, so the text we
/// measure and the text we draw share the same locale-aware line breaking,
/// fallback fonts, and vertical OpenType features.
enum CoreTextTypesetter {

  // MARK: Internal

  struct VerticalLayoutPlan: Equatable {
    let columns: [NSRange]
    let glyphExtent: CGFloat
    let columnAdvance: CGFloat
    let requiredWidth: CGFloat

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

  static func fittedFontSize(
    text: String,
    language: Locale.Language,
    flow: OverlayTextFlow,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedTo size: CGSize,
    preferred: CGFloat,
    minimum: CGFloat,
    lineHeightMultiple: CGFloat = 1
  ) -> CGFloat {
    guard !text.isEmpty, size.width > 0, size.height > 0 else { return minimum }
    let lowerBound = max(1, min(minimum, preferred))
    let upperBound = max(lowerBound, preferred)
    if
      fits(
        text: text,
        language: language,
        flow: flow,
        fontSize: upperBound,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        in: size,
        lineHeightMultiple: lineHeightMultiple
      )
    {
      return upperBound
    }
    guard
      fits(
        text: text,
        language: language,
        flow: flow,
        fontSize: lowerBound,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        in: size,
        lineHeightMultiple: lineHeightMultiple
      )
    else {
      return lowerBound
    }

    var low = lowerBound
    var high = upperBound
    for _ in 0 ..< 10 {
      let candidate = (low + high) / 2
      if
        fits(
          text: text,
          language: language,
          flow: flow,
          fontSize: candidate,
          fontWeight: fontWeight,
          fontDesign: fontDesign,
          in: size,
          lineHeightMultiple: lineHeightMultiple
        )
      {
        low = candidate
      } else {
        high = candidate
      }
    }
    return floor(low * 4) / 4
  }

  static func fits(
    text: String,
    language: Locale.Language,
    flow: OverlayTextFlow,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    in size: CGSize,
    lineHeightMultiple: CGFloat = 1
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
        constrainedToHeight: size.height
      )
      return !plan.columns.isEmpty && plan.requiredWidth <= size.width + 0.5
    }
    let vertical: Bool
    let progression: OverlayColumnProgression
    switch flow {
    case .horizontal:
      vertical = false
      progression = .rightToLeft

    case .vertical(let value):
      vertical = true
      progression = value
    }
    let attributed = attributedString(
      text: text,
      language: language,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontDesign: fontDesign,
      vertical: vertical,
      lineHeightMultiple: lineHeightMultiple
    )
    let frame = makeFrame(attributed: attributed, size: size, progression: vertical ? progression : nil)
    let visible = CTFrameGetVisibleStringRange(frame)
    return visible.location == 0 && visible.length >= attributed.length
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

  static func horizontalLineCount(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    in size: CGSize,
    lineHeightMultiple: CGFloat = 1
  ) -> Int {
    guard !text.isEmpty, size.width > 0, size.height > 0 else { return 0 }
    let attributed = attributedString(
      text: text,
      language: language,
      fontSize: fontSize,
      fontWeight: fontWeight,
      fontDesign: fontDesign,
      vertical: false,
      lineHeightMultiple: lineHeightMultiple
    )
    let frame = makeFrame(attributed: attributed, size: size, progression: nil)
    return CFArrayGetCount(CTFrameGetLines(frame))
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
    let tokens = horizontalTokens(in: text, language: language)
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
    return horizontalTokens(in: text, language: language).allSatisfy { token in
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
    return horizontalTokenRanges(in: text, language: language).allSatisfy { token in
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
    progression: OverlayColumnProgression
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
      vertical: true
    )
    let plan = verticalLayoutPlan(
      attributed: attributed,
      language: language,
      fontSize: fontSize,
      constrainedToHeight: size.height
    )
    guard !plan.columns.isEmpty, plan.requiredWidth <= size.width + 0.5 else { return nil }

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
      CTFrameDraw(frame, context)
    }
    return context.makeImage()
  }

  static func verticalLayoutPlan(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight = .semibold,
    fontDesign: OverlayFontDesign = .standard,
    constrainedToHeight height: CGFloat
  ) -> VerticalLayoutPlan {
    verticalLayoutPlan(
      attributed: attributedString(
        text: text,
        language: language,
        fontSize: fontSize,
        fontWeight: fontWeight,
        fontDesign: fontDesign,
        vertical: true
      ),
      language: language,
      fontSize: fontSize,
      constrainedToHeight: height
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

  // MARK: Private

  private static func attributedString(
    text: String,
    language: Locale.Language,
    fontSize: CGFloat,
    fontWeight: OverlayFontWeight,
    fontDesign: OverlayFontDesign,
    vertical: Bool,
    lineHeightMultiple: CGFloat = 1
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
    return attributed
  }

  private static func verticalLayoutPlan(
    attributed: NSAttributedString,
    language: Locale.Language,
    fontSize: CGFloat,
    constrainedToHeight height: CGFloat
  ) -> VerticalLayoutPlan {
    guard attributed.length > 0, height > 0 else {
      return VerticalLayoutPlan(columns: [], glyphExtent: 0, columnAdvance: 0, requiredWidth: 0)
    }
    let typesetter = CTTypesetterCreateWithAttributedString(attributed)
    let text = attributed.string as NSString
    var columns = [NSRange]()
    var offset = 0
    while offset < attributed.length {
      var length = CTTypesetterSuggestLineBreak(typesetter, offset, height)
      length = adjustedToWordBoundary(
        proposedLength: length,
        offset: offset,
        text: attributed.string,
        language: language
      )
      if length <= 0 {
        length = CTTypesetterSuggestClusterBreak(typesetter, offset, height)
      }
      if length <= 0 {
        length = text.rangeOfComposedCharacterSequence(at: offset).length
      }
      length = min(max(1, length), attributed.length - offset)
      columns.append(NSRange(location: offset, length: length))
      offset += length
    }

    let glyphExtent = ceil(fontSize * 1.2)
    let columnAdvance = glyphExtent + ceil(max(1, fontSize * 0.1))
    let requiredWidth = glyphExtent + CGFloat(max(0, columns.count - 1)) * columnAdvance
    return VerticalLayoutPlan(
      columns: columns,
      glyphExtent: glyphExtent,
      columnAdvance: columnAdvance,
      requiredWidth: requiredWidth
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
    text: String,
    language: Locale.Language
  ) -> Int {
    guard proposedLength > 0, !usesCharacterWrapping(language) else { return proposedLength }
    let proposedEnd = offset + proposedLength
    for token in horizontalTokenRanges(in: text, language: language) {
      let tokenEnd = token.location + token.length
      guard proposedEnd > token.location, proposedEnd < tokenEnd else { continue }
      let adjusted = token.location - offset
      return adjusted > 0 ? adjusted : proposedLength
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

  private static func usesCharacterWrapping(_ language: Locale.Language) -> Bool {
    switch language.script?.identifier {
    case "Hans",
         "Hant",
         "Jpan": true
    default: false
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
    let tokenizer = NLTokenizer(unit: .word)
    tokenizer.string = text
    if let code = language.languageCode?.identifier {
      tokenizer.setLanguage(NLLanguage(rawValue: code))
    }
    return tokenizer.tokens(for: text.startIndex ..< text.endIndex).map { NSRange($0, in: text) }
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
  fileprivate var nsFontWeight: NSFont.Weight {
    switch self {
    case .regular: .regular
    case .medium: .medium
    case .semibold: .semibold
    case .bold: .bold
    }
  }
}
