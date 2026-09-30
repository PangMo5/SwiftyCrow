// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import NaturalLanguage
@testable import SwiftyCrow

/// Output checks with explicit fixture expectations. A successful API response
/// does not establish that the composited capture is usable.
enum CaptureQualityMetrics {
  static func sourceFragmentIssues(lines: [OverlayLine], expected: [CaptureSourceFragmentExpectation]) -> [String] {
    expected.compactMap { expectation in
      let values = expectation.region
      guard
        values.count == 4, values.allSatisfy(\.isFinite), values[0] >= 0, values[1] >= 0,
        values[2] > 0, values[3] > 0, values[0] + values[2] <= 1, values[1] + values[3] <= 1,
        !expectation.sourcePrefix.isEmpty
      else { return "Invalid source-fragment expectation" }
      let bounds = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      let owners = lines.filter { $0.source.text.hasPrefix(expectation.sourcePrefix) }
      guard
        owners.count == 1, let line = owners.first, line.shouldReplaceSourcePixels,
        line.source.styleRuns.contains(where: { run in
          guard
            let fragment = run.sourceFragment, let ink = run.inkBox,
            ink.insetBy(dx: -1e-9, dy: -1e-9).contains(bounds)
          else { return false }
          return line.displayedStyleRuns.contains { $0.sourceFragment == fragment }
        })
      else { return "Required source pixels not displayed: \(expectation.sourcePrefix) at \(values)" }
      return nil
    }
  }

  static func restoredBackgroundIssues(_ image: CGImage, expected: [CaptureBackgroundExpectation]) -> [String] {
    expected.flatMap { item -> [String] in
      guard
        item.region.count == 4, item.color.count == 3,
        item.color.allSatisfy({ (0...255).contains($0) }), item.maximumChannelError >= 0,
        item.region[0] >= 0, item.region[1] >= 0, item.region[2] > 0, item.region[3] > 0,
        item.region[0] <= image.width, item.region[1] <= image.height,
        item.region[2] <= image.width - item.region[0], item.region[3] <= image.height - item.region[1]
      else { return ["Invalid restored-background expectation"] }
      let region = CGRect(x: item.region[0], y: item.region[1], width: item.region[2], height: item.region[3])
      guard
        let crop = image.cropping(to: region),
        let context = CGContext(
          data: nil,
          width: crop.width,
          height: crop.height,
          bitsPerComponent: 8,
          bytesPerRow: crop.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ),
        let bytes = context.data?.assumingMemoryBound(to: UInt8.self)
      else { return ["Could not inspect restored background"] }
      context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
      var changed = 0
      var maximum = 0
      for index in 0..<crop.width * crop.height {
        let error = (0..<3).map { abs(Int(bytes[index * 4 + $0]) - item.color[$0]) }.max()!
        maximum = max(maximum, error)
        if error > item.maximumChannelError { changed += 1 }
      }
      return changed == 0 ? [] : ["Restored background differs in \(changed) pixels; maximum channel error \(maximum)"]
    }
  }

  /// Hide target paint without changing its range ownership or layout metrics.
  /// Rebuilding a plain translation would discard required source-fragment links.
  static func hidingTargetInk(_ source: OverlayLine) -> OverlayLine {
    var line = source
    line.source.appearance.foreground.alpha = 0
    line.source.styleRuns = line.source.styleRuns.map { sourceRun in
      var run = sourceRun
      run.appearance.foreground.alpha = 0
      run.appearance.background.alpha = 0
      if let fragment = run.sourceFragment {
        run.sourceFragment = OverlayInlineSourceFragment(
          pixels: Data(count: fragment.pixels.count),
          width: fragment.width,
          height: fragment.height,
          descent: fragment.descent,
          referenceFontSize: fragment.referenceFontSize
        )
      }
      return run
    }
    return line
  }

  static func translationIssues(_ lines: [OverlayLine], expected: [CaptureTranslationExpectation]) -> [String] {
    expected.flatMap { item -> [String] in
      guard
        !item.sourcePrefix.isEmpty, !(item.targetIncludes + item.targetExcludes).isEmpty,
        (item.targetIncludes + item.targetExcludes).allSatisfy({ !$0.isEmpty })
      else { return ["Invalid translation expectation"] }
      let matching = lines.filter { $0.source.text.hasPrefix(item.sourcePrefix) }
      guard !matching.isEmpty else { return ["Missing translation subject: \(item.sourcePrefix)"] }
      return matching.flatMap { line -> [String] in
        guard
          let target = line.translatedText,
          !line.isUnavailable
        else { return ["Missing required translation: \(item.sourcePrefix)"] }
        return item.targetIncludes.filter { !target.localizedCaseInsensitiveContains($0) }
          .map { "Required target term missing: \($0) in \(item.sourcePrefix)" }
          + item.targetExcludes.filter { target.localizedCaseInsensitiveContains($0) }
          .map { "Forbidden target term: \($0) in \(item.sourcePrefix)" }
      }
    }
  }

  static func lineCountIssues(_ placements: [OverlayPlacement], expected: [CaptureLineCountExpectation]) -> [String] {
    expected.flatMap { expectation -> [String] in
      guard !expectation.source.isEmpty, expectation.maximum > 0 else { return ["Invalid line-count expectation"] }
      let owners = placements.filter { $0.line.source.text.contains(expectation.source) }
      guard !owners.isEmpty else { return ["Missing line-count subject: \(expectation.source)"] }
      return owners.compactMap { placement in
        guard case .horizontal = placement.flow else { return "Expected horizontal line-count subject: \(expectation.source)" }
        let count = HorizontalTextRenderer.plan(for: placement).lines.count
        return count <= expectation.maximum
          ? nil
          : "Line count \(count) exceeds \(expectation.maximum): \(placement.line.source.text)"
      }
    }
  }

  /// Bounds come from a reviewed source fixture, not the OCR size under test.
  static func fontScaleIssues(
    _ placements: [OverlayPlacement],
    canvas: CGSize,
    expected: [CaptureFontExpectation]
  ) -> [String] {
    expected.flatMap { expectation -> [String] in
      guard
        canvas.height > 0, !expectation.source.isEmpty,
        expectation.minimum > 0, expectation.maximum >= expectation.minimum,
        expectation.maximum.isFinite
      else { return ["Invalid font-scale expectation"] }
      let owners = placements.filter { $0.line.source.text.contains(expectation.source) }
      guard !owners.isEmpty else { return ["Missing font-scale subject: \(expectation.source)"] }
      return owners.compactMap { placement in
        let scale = placement.fontSize / canvas.height
        return (expectation.minimum...expectation.maximum).contains(scale)
          ? nil
          : "Font scale \(scale) outside \(expectation.minimum)...\(expectation.maximum): \(placement.line.source.text)"
      }
    }
  }

  static func proseIssues(lines: [OverlayLine], expected: [String]) -> [String] {
    expected.flatMap { token -> [String] in
      guard !token.isEmpty else { return ["Empty prose expectation"] }
      let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: token) + #"(?![\p{L}\p{N}_])"#
      let expression = try! NSRegularExpression(pattern: pattern)
      func contains(_ text: String) -> Bool {
        expression.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
      }
      let owners = lines.filter { contains($0.source.text) }
      guard !owners.isEmpty else { return ["Missing prose subject: \(token)"] }
      return owners.compactMap { line in
        let protected: Bool =
          if line.source.isProtectedLiteral { true }
          else if let attributed = line.source.attributedTextForTranslation() {
            attributed.runs.contains {
              $0.inlinePresentationIntent?.contains(.code) == true && contains(String(attributed.characters[$0.range]))
            }
          } else { false }
        return protected ? "Ordinary prose was protected as literal: \(token) in \(line.source.text)" : nil
      }
    }
  }

  static func alignmentIssues(_ placements: [OverlayPlacement], expected: [CaptureAlignmentExpectation]) -> [String] {
    expected.flatMap { expectation -> [String] in
      let owners = placements.filter { $0.line.source.text.contains(expectation.source) }
      guard !owners.isEmpty else { return ["Missing alignment subject: \(expectation.source)"] }
      return owners.compactMap { placement in
        let actual = String(describing: placement.alignment)
        return actual == expectation.alignment
          ? nil
          : "Alignment \(actual), expected \(expectation.alignment): \(expectation.source)"
      }
    }
  }

  static func literalIssues(lines: [OverlayLine], expected: [String]) -> [String] {
    expected.flatMap { literal -> [String] in
      guard !literal.isEmpty else { return ["Empty literal expectation"] }
      let pattern = #"(?<![\p{L}\p{N}_])"# + NSRegularExpression.escapedPattern(for: literal) + #"(?![\p{L}\p{N}_])"#
      let expression = try! NSRegularExpression(pattern: pattern)
      func count(_ text: String) -> Int {
        expression.numberOfMatches(in: text, range: NSRange(location: 0, length: text.utf16.count))
      }
      let owners = lines.filter { count($0.source.text) > 0 }
      guard !owners.isEmpty else { return ["Missing literal source: \(literal)"] }
      return owners.compactMap { line -> String? in
        if line.source.isProtectedLiteral && !line.isPending && !line.isUnavailable && !line.shouldReplaceSourcePixels {
          return nil
        }
        let occurrences = count(line.source.text)
        let classified: Int =
          if let attributed = line.source.attributedTextForTranslation() {
            attributed.runs.reduce(0) { total, run in
              total + (run.inlinePresentationIntent?.contains(.code) == true
                ? count(String(attributed.characters[run.range]))
                : 0)
            }
          } else { 0 }
        guard classified >= occurrences else { return "Literal was not classified: \(literal) in \(line.source.text)" }
        let retained = line.displayedStyleRuns.reduce(0) { total, run in
          guard let range = Range(run.range, in: line.displayedText) else { return total }
          return total + count(String(line.displayedText[range]))
        }
        return line.translatedText != nil && retained >= occurrences
          ? nil
          : "Protected literal was changed or missing: \(literal) in \(line.source.text)"
      }
    }
  }

  /// Unlike a rectangle-overlap score, inspect the actual translation pixels.
  /// Text belonging to the declared container may render inside it; outside
  /// paragraphs must flow around it, including inline style backgrounds.
  static func foreignRegionIssues(_ placements: [OverlayPlacement], canvas: CGSize, regions: [CGRect]) -> [String] {
    var issues = [String]()
    for (index, normalizedRegion) in regions.enumerated() {
      let region = normalizedRegion.intersection(CGRect(origin: .zero, size: canvas))
      guard !region.isNull, !region.isEmpty else { continue }
      for placement in placements where !region.insetBy(dx: -1, dy: -1).contains(placement.sourceFrame) {
        let overlap = placement.frame.intersection(region.applying(placement.transform.inverted()))
        guard
          !overlap.isNull, !overlap.isEmpty, case .horizontal = placement.flow,
          !placement.visualFrame.intersection(region).isNull
        else { continue }
        guard let image = HorizontalTextRenderer.image(for: placement, scale: 1) else {
          issues.append("Cannot inspect foreign region \(index): \(placement.line.source.text)")
          continue
        }
        let cropBounds = overlap.offsetBy(dx: -placement.frame.minX, dy: -placement.frame.minY).integral
          .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard
          let crop = image.cropping(to: cropBounds),
          let context = CGContext(
            data: nil,
            width: crop.width,
            height: crop.height,
            bitsPerComponent: 8,
            bytesPerRow: crop.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let data = context.data
        else { issues.append("Cannot inspect foreign region \(index): \(placement.line.source.text)")
          continue
        }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let painted = (0..<crop.width * crop.height).count { i in
          guard pixels[i * 4 + 3] > 2 else { return false }
          let local = CGPoint(
            x: placement.frame.minX + cropBounds.minX + CGFloat(i % crop.width) + 0.5,
            y: placement.frame.minY + cropBounds.minY + CGFloat(i / crop.width) + 0.5
          )
          return region.contains(local.applying(placement.transform))
        }
        if
          painted >
          0 { issues.append("\(painted) translation pixels crossed foreign region \(index): \(placement.line.source.text)") }
      }
    }
    return issues
  }

  static func styleIssues(lines: [OverlayLine], expected: [CaptureStyleExpectation]) -> [String] {
    expected.compactMap { expectation in
      guard
        let line = lines.first(where: { $0.source.text.contains(expectation.source) }),
        let range = line.displayedText.range(of: expectation.target)
      else { return "Missing styled text: \(expectation.source) -> \(expectation.target)" }
      let utf16 = NSRange(range, in: line.displayedText)
      let retained = (utf16.location..<NSMaxRange(utf16)).allSatisfy { location in
        let appearance = line.displayedStyleRuns.last(where: { NSLocationInRange(location, $0.range) })?.appearance
          ?? line.source.appearance
        switch expectation.kind {
        case "color":
          let color = appearance.foreground
          return max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue) >= 0.2

        case "weight": return appearance.fontWeight.rawValue >= OverlayFontWeight.semibold.rawValue

        case "plain":
          let color = appearance.foreground
          return appearance.fontWeight == .regular
            && max(color.red, color.green, color.blue) - min(color.red, color.green, color.blue) < 0.1

        default: return false
        }
      }
      return retained ? nil : "Lost \(expectation.kind) style: \(expectation.target) in \(expectation.source)"
    }
  }

  static func paragraphIssues(texts: [String], expected: [String]) -> [String] {
    func normalized(_ text: String) -> String {
      text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        .decomposedStringWithCanonicalMapping
        .unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) && !CharacterSet.nonBaseCharacters.contains($0) }
        .map(String.init).joined()
    }
    let units = texts.map(normalized)
    var owners = Set<Int>()
    var issues = [String]()
    for paragraph in expected {
      let tokenizer = NLTokenizer(unit: .sentence)
      tokenizer.string = paragraph
      let sentences = tokenizer.tokens(for: paragraph.startIndex..<paragraph.endIndex).map { String(paragraph[$0]) }
      var paragraphOwners = Set<Int>()
      for sentence in sentences {
        let value = normalized(sentence)
        guard !value.isEmpty else { continue }
        guard let owner = units.firstIndex(where: { $0.contains(value) }) else {
          issues.append("Sentence split or incomplete: \(sentence)")
          continue
        }
        paragraphOwners.insert(owner)
      }
      if !owners.isDisjoint(with: paragraphOwners) { issues.append("Independent paragraphs merged: \(paragraph)") }
      owners.formUnion(paragraphOwners)
    }
    return issues
  }

  static func missingSourceText(_ text: String, requiredText: [String], requiredWords: [String], language: String) -> [String] {
    let locale = Locale(identifier: language)
    let comparison = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    return requiredText.filter { !text.localizedCaseInsensitiveContains($0) }
      + requiredWords
      .filter { !comparison.contains($0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)) }
  }

  static func layoutIssues(_ placements: [OverlayPlacement], canvas: CGSize, minimumFontRatio: CGFloat) -> [String] {
    var issues = [String]()
    for placement in placements {
      let line = placement.line
      if case .horizontal = placement.flow {
        let plan = HorizontalTextRenderer.plan(for: placement)
        if !plan.fits(placement.frame.size) { issues.append("Incomplete or clipped text: \(line.source.text)") }
      } else if
        !CoreTextTypesetter.fits(
          text: line.displayedText,
          language: line.displayedLanguage,
          flow: placement.flow,
          fontSize: placement.fontSize,
          fontWeight: line.source.appearance.fontWeight,
          fontDesign: line.source.appearance.fontDesign,
          in: placement.frame.size,
          verticalWrapping: placement.verticalWrapping,
          styles: line.displayedStyleRuns,
          isUnderlined: line.source.appearance.isUnderlined
        )
      {
        issues.append("Incomplete or clipped vertical text: \(line.source.text)")
      }
      let sourceSize: CGFloat =
        if case .vertical(let characterScale, _) = line.source.layout {
          characterScale * canvas.width
        } else {
          line.source.appearance.fontSizeScale > 0
            ? line.source.appearance.fontSizeScale * canvas.height
            : line.source.horizontalGlyphScale * canvas.height
        }
      if sourceSize > 0, placement.fontSize / sourceSize < minimumFontRatio {
        issues.append("Excessive font reduction: \(line.source.text)")
      }
    }
    return issues + ownerOverlapIssues(placements)
  }

  /// A shaped paragraph can surround another owner without occupying its
  /// space. Compare allocated corridors, not their enclosing rectangle.
  static func ownerOverlapIssues(_ placements: [OverlayPlacement]) -> [String] {
    func regions(_ placement: OverlayPlacement) -> [CGRect] {
      guard !placement.textFlowRegions.isEmpty else { return [placement.visualFrame] }
      return placement.textFlowRegions.map {
        $0.offsetBy(dx: placement.frame.minX, dy: placement.frame.minY).intersection(placement.frame)
          .applying(placement.transform)
      }.filter { !$0.isNull && !$0.isEmpty }
    }
    func isAxisAligned(_ placement: OverlayPlacement) -> Bool {
      let turns = placement.rotationRadians / (.pi / 2)
      return abs(turns - turns.rounded()) * (.pi / 2) < 0.025
    }
    var issues = [String]()
    for (index, first) in placements.enumerated() where isAxisAligned(first) {
      for second in placements.dropFirst(index + 1) where isAxisAligned(second) {
        guard first.visualFrame.intersects(second.visualFrame) else { continue }
        let a = regions(first)
        let b = regions(second)
        let area = min(a.reduce(0) { $0 + $1.width * $1.height }, b.reduce(0) { $0 + $1.width * $1.height })
        let overlap = a.reduce(CGFloat.zero) { sum, region in
          sum + b.reduce(CGFloat.zero) { value, other in
            let shared = region.intersection(other)
            return value + (shared.isNull ? 0 : shared.width * shared.height)
          }
        }
        if area > 0, overlap / area > 0.45 {
          issues.append("Overlapping text owners: \(first.line.source.text) / \(second.line.source.text)")
        }
      }
    }
    return issues
  }

  static func protectedPixelChanges(original: CGImage, rendered: CGImage, rectangles: [CGRect]) -> Int {
    guard !rectangles.isEmpty else { return 0 }
    guard original.width == rendered.width, original.height == rendered.height else { return Int.max }
    func pixels(_ image: CGImage) -> [UInt8]? {
      guard
        let context = CGContext(
          data: nil,
          width: image.width,
          height: image.height,
          bitsPerComponent: 8,
          bytesPerRow: image.width * 4,
          space: CGColorSpace(name: CGColorSpace.sRGB)!,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
      else { return nil }
      context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
      guard let data = context.data else { return nil }
      return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    guard let before = pixels(original), let after = pixels(rendered) else { return Int.max }
    var changed = 0
    for rect in rectangles {
      let x0 = max(0, Int(rect.minX * CGFloat(original.width)))
      let x1 = min(original.width, Int(rect.maxX * CGFloat(original.width)))
      let y0 = max(0, Int(rect.minY * CGFloat(original.height)))
      let y1 = min(original.height, Int(rect.maxY * CGFloat(original.height)))
      guard x1 > x0, y1 > y0 else { continue }
      for y in y0..<y1 { for x in x0..<x1 {
        let offset = (y * original.width + x) * 4
        if (0..<3).contains(where: { abs(Int(before[offset + $0]) - Int(after[offset + $0])) > 3 }) { changed += 1 }
      }}
    }
    return changed
  }
}
