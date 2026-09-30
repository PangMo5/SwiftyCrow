// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreText
import Synchronization

/// Compare the same glyphs, rather than assuming all words have equal ink
/// density. "ill", "workspace", and Korean text have very different coverage
/// even when their weight is identical.
enum SourceTypography {

  // MARK: Internal

  struct Measurement: Sendable {
    var weight: OverlayFontWeight
    var pointSize: CGFloat
  }

  /// Font-independent evidence requires agreement across the reference faces.
  /// Layout/raster objects remain local, while immutable fonts are shared.
  static func glyphTopologies(text: String) -> Set<OCRGlyphTopology.Signature> {
    guard (1...16).contains(text.count), text.unicodeScalars.allSatisfy(\.isASCII) else { return [] }
    if let cached = topologyCache.withLock({ $0[text] }) { return cached }
    let values = fonts.pitch.compactMap { reference -> OCRGlyphTopology.Signature? in
      let line = CTLineCreateWithAttributedString(NSAttributedString(
        string: text,
        attributes: [.font: reference.font, .foregroundColor: NSColor.black]
      ))
      let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).integral
      let width = Int(bounds.width) + 4
      let height = Int(bounds.height) + 4
      guard
        width > 4, height > 4, width * height <= 65_536,
        let context = CGContext(
          data: nil,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return nil }
      context.setFillColor(CGColor(gray: 1, alpha: 1))
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
      context.textPosition = CGPoint(x: 2 - bounds.minX, y: 2 - bounds.minY)
      CTLineDraw(line, context)
      guard let image = context.makeImage() else { return nil }
      return OCRGlyphTopology.signature(image: image, background: .init(red: 1, green: 1, blue: 1, alpha: 1))
    }
    // A failed face must not silently turn disagreement into unanimous support.
    let result = values.count == fonts.pitch.count ? Set(values) : []
    topologyCache.withLock {
      if $0.count >= 512 { $0.removeAll(keepingCapacity: true) }
      $0[text] = result
    }
    return result
  }

  static func measure(text: String, inkSize: CGSize, coverage: CGFloat) -> Measurement? {
    guard
      !text.isEmpty, text.count <= 80, inkSize.height >= 7,
      inkSize.width >= 4, coverage > 0, !text.contains("\n"), text.contains(where: { $0.isLetter || $0.isNumber })
    else { return nil }
    let key = ReferenceKey(text: text, height: inkSize.height)
    let references: [Reference]
    if let cached = cache.withLock({ $0[key] }) {
      references = cached
    } else {
      references = makeReferences(text: text, height: inkSize.height)
      cache.withLock {
        if $0.count >= 2048 { $0.removeAll(keepingCapacity: true) }
        $0[key] = references
      }
    }
    return references.min { abs($0.density - coverage) < abs($1.density - coverage) }?.measurement
  }

  /// Require actual fixed-pitch evidence and a margin over proportional fonts.
  /// Similar-width words are ambiguous; a colored label alone is not code.
  static func isMonospaced(text: String, inkColumns: [CGFloat]) -> Bool {
    guard
      (4...40).contains(text.count),
      text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) && $0.isASCII }),
      let peak = inkColumns.max(), peak > 0
    else { return false }
    var ranges = [ClosedRange<Int>]()
    for (x, ink) in inkColumns.enumerated() where ink >= peak * 0.6 {
      if let previous = ranges.last, previous.upperBound == x - 1 {
        ranges[ranges.count - 1] = previous.lowerBound...x
      } else { ranges.append(x...x) }
    }
    guard ranges.count == text.count else { return false }
    // Strong ink separates glyphs; faint antialiasing still contributes their
    // actual extent. Split touching soft edges at the weakest inter-glyph column
    // instead of shifting each center according to its darkest stem.
    let dividers = zip(ranges, ranges.dropFirst()).map { left, right in
      (left.upperBound + 1..<right.lowerBound).min { inkColumns[$0] < inkColumns[$1] }!
    }
    let glyphBounds = ranges.enumerated().map { index, range -> ClosedRange<Int> in
      let leftLimit = index == 0 ? 0 : dividers[index - 1] + 1
      let rightLimit = index == ranges.count - 1 ? inkColumns.count - 1 : dividers[index] - 1
      var lower = range.lowerBound
      var upper = range.upperBound
      while lower > leftLimit, inkColumns[lower - 1] >= peak * 0.2 { lower -= 1 }
      while upper < rightLimit, inkColumns[upper + 1] >= peak * 0.2 { upper += 1 }
      return lower...upper
    }
    let centers = glyphBounds.map { CGFloat($0.lowerBound + $0.upperBound) / 2 }
    let span = centers.last! - centers.first!
    let widths = glyphBounds.map { CGFloat($0.count) / span }
    guard let observed = normalizedCenters(centers), centers.last! - centers.first! >= 15 else { return false }
    let references: [PitchReference]
    if let cached = pitchCache.withLock({ $0[text] }) { references = cached }
    else {
      references = pitchReferences(text: text)
      pitchCache.withLock {
        if $0.count >= 1024 { $0.removeAll(keepingCapacity: true) }
        $0[text] = references
      }
    }
    func spacingError(_ reference: PitchReference) -> CGFloat {
      guard reference.centers.count == observed.count else { return .infinity }
      return sqrt(zip(reference.centers, observed).reduce(0) { $0 + pow($1.0 - $1.1, 2) } / CGFloat(observed.count))
    }
    let monoSpacing = references.filter(\.monospaced).map(spacingError).min() ?? .infinity
    let proportionalSpacing = references.filter { !$0.monospaced }.map(spacingError).min() ?? .infinity
    // Shape agreement must not compensate for ambiguous spacing (for example a
    // bold proportional heading). Require both pieces of evidence independently.
    guard
      monoSpacing <= 0.025, proportionalSpacing - monoSpacing >= 0.008,
      monoSpacing < proportionalSpacing * 0.65
    else { return false }
    func error(_ reference: PitchReference) -> CGFloat {
      guard reference.centers.count == observed.count else { return .infinity }
      let spacing = zip(reference.centers, observed).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
      let shape = zip(reference.widths, widths).reduce(0) { $0 + pow($1.0 - $1.1, 2) }
      return sqrt((spacing + shape * 0.5) / CGFloat(observed.count))
    }
    let mono = references.filter(\.monospaced).map(error).min() ?? .infinity
    let proportional = references.filter { !$0.monospaced }.map(error).min() ?? .infinity
    return mono <= 0.04 && proportional - mono >= 0.008 && mono < proportional * 0.8
  }

  // MARK: Private

  private struct PitchReference: Sendable {
    var monospaced: Bool
    var centers: [CGFloat]
    var widths: [CGFloat]
  }

  private struct ReferenceKey: Hashable, Sendable {
    var text: String
    var height: CGFloat
  }

  private struct Reference: Sendable {
    var density: CGFloat
    var measurement: Measurement
  }

  /// Core Text fonts are immutable and shareable; layout objects are not.
  /// Initialize the AppKit-derived descriptors once, then keep only native
  /// Core Text fonts so parallel cache misses never repeat font-factory work.
  private final class FontCatalog: @unchecked Sendable {

    // MARK: Lifecycle

    init() {
      func native(_ font: NSFont) -> CTFont {
        CTFontCreateWithFontDescriptor(CTFontCopyFontDescriptor(font as CTFont), 32, nil)
      }
      weights = [OverlayFontWeight.regular, .semibold, .bold].map {
        ($0, native(NSFont.systemFont(ofSize: 32, weight: $0.nsFontWeight)))
      }
      pitch = [
        (native(NSFont.monospacedSystemFont(ofSize: 32, weight: .regular)), true),
        (weights[0].font, false),
      ] + ["Menlo", "Courier", "Arial", "Times New Roman", "Georgia", "Verdana"].compactMap { name in
        NSFont(name: name, size: 32).map { (native($0), name == "Menlo" || name == "Courier") }
      }
    }

    // MARK: Internal

    let pitch: [(font: CTFont, monospaced: Bool)]
    let weights: [(weight: OverlayFontWeight, font: CTFont)]

  }

  private static let fonts = FontCatalog()

  private static let pitchCache = Mutex<[String: [PitchReference]]>([:])
  private static let topologyCache = Mutex<[String: Set<OCRGlyphTopology.Signature>]>([:])

  /// Cache glyph templates, not inferred weights: each source sample still
  /// chooses its weight from its own measured coverage. Exact heights keep
  /// calibration unchanged, while repeated words avoid three bitmap renders.
  private static let cache = Mutex<[ReferenceKey: [Reference]]>([:])

  private static func normalizedCenters(_ values: [CGFloat]) -> [CGFloat]? {
    guard let first = values.first, let last = values.last, last > first else { return nil }
    return values.map { ($0 - first) / (last - first) }
  }

  private static func pitchReferences(text: String) -> [PitchReference] {
    fonts.pitch.compactMap { font, monospaced in
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]))
      var centers = [CGFloat]()
      var widths = [CGFloat]()
      for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(), &glyphs)
        CTRunGetPositions(run, CFRange(), &positions)
        let actualFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        var bounds = [CGRect](repeating: .zero, count: count)
        CTFontGetBoundingRectsForGlyphs(actualFont, .horizontal, glyphs, &bounds, count)
        centers += zip(positions, bounds).map { $0.x + $1.midX }
        widths += bounds.map(\.width)
      }
      guard centers.count == text.count, let normalized = normalizedCenters(centers) else { return nil }
      return PitchReference(
        monospaced: monospaced,
        centers: normalized,
        widths: widths.map { $0 / (centers.last! - centers.first!) }
      )
    }
  }

  private static func makeReferences(text: String, height inkHeight: CGFloat) -> [Reference] {
    var candidates = [Reference]()
    for (weight, font) in fonts.weights {
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font
      ]))
      let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
      guard bounds.width > 0, bounds.height > 0 else { continue }
      let scale = inkHeight / bounds.height
      let width = max(1, Int(ceil(bounds.width * scale)))
      let height = max(1, Int(ceil(inkHeight)))
      guard
        width < 4096, height < 256,
        let context = CGContext(
          data: nil,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { continue }
      context.scaleBy(x: scale, y: scale)
      context.textPosition = CGPoint(x: -bounds.minX, y: -bounds.minY)
      CTLineDraw(line, context)
      guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { continue }
      var total: CGFloat = 0
      for index in 0 ..< width * height { total += CGFloat(pixels[index * 4 + 3]) / 255 }
      let density = total / CGFloat(width * height)
      candidates.append(Reference(density: density, measurement: Measurement(weight: weight, pointSize: 32 * scale)))
    }
    return candidates
  }
}
