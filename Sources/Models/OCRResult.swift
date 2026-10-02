// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - OCRResult

struct OCRResult: Equatable, Sendable {

  // MARK: Internal

  /// A single recognized line with its position on the captured frame.
  struct Line: Equatable, Sendable, Hashable {
    /// Top-left origin, 0–1 normalized to the captured frame.
    var boundingBoxNormalized: CGRect
    var text: String
    var rotationRadians: CGFloat = 0
    var orientedBox: CGRect?
    var imageAspectRatio: CGFloat = 1
    /// How many source rows this line spans. >1 after wrapped lines are
    /// stitched into one sentence, so the renderer can size the font to a
    /// single row and wrap the text instead of stretching it.
    var preventsJoining = false
    var preservesSource = false
    var needsReview = false
    var recognitionConfidence: Float = 1
    var rowCount = 1
    /// True when this is a block of vertical (top-to-bottom) CJK columns stitched
    /// together. The renderer lays the translation out vertically over the box.
    var isVerticalBlock = false
    /// For a vertical block, the source character size (a column's width, 0–1
    /// normalized) — lets the renderer match the original font scale so titles
    /// stay large and annotations small, preserving the page's text hierarchy.
    var verticalCharScale: CGFloat = 0
    /// Median Vision word-box height for horizontal text, normalized to the
    /// captured image. Line boxes can include icons or control chrome (for
    /// example "+ Add bypass") and substantially overstate the glyph size.
    var horizontalGlyphScale: CGFloat = 0
    /// Pixel-measured foreground ink height, normalized to the captured image.
    /// Preferred over Vision box height when available.
    var horizontalInkScale: CGFloat = 0
    /// Median center-to-center advance between source rows, normalized to the
    /// captured image. This preserves the source's visual line-height rather
    /// than inheriting the target font's usually tighter default leading.
    var horizontalLineAdvanceScale: CGFloat = 0
    /// Paragraph membership supplied by Vision for this recognition pass.
    /// Keeps wrapped/inline fragments together during capture analysis; it is
    /// not a persistent id or ownership shared across capture contexts.
    var recognitionGroupID: Int? = nil
    /// Native list-item/table-cell ownership, independent of paragraph IDs.
    /// This is capture-local geometry, never reused as a persistent identity.
    var recognitionContainer: CGRect?
    /// Verified horizontal corridors, in source coordinates. Empty means a
    /// rectangular paragraph; nonempty preserves flow around adjacent content.
    var textFlowRegions = [CGRect]()
    /// Verified artwork from restoration. Constrains target layout independently of erasure masks.
    var layoutExclusions = [CGRect]()
    /// Boundary recovered from the document transcript (nil when unavailable).
    /// Prevents a visual wrap from inserting a space inside CJK/Hangul words.
    var followingSeparator: String?
    /// True after two or more Vision observations have been rebuilt into one
    /// visual text region. Appearance analysis uses the union only in this
    /// case, so an inline chip cannot become the paragraph's base style.
    var wasCoalesced = false
    /// A complete image-bounded paragraph; neighboring balloons must stay separate.
    var isReconstructedTextRegion = false
    /// Dominant local background and readable foreground sampled from the
    /// original pixels, used to redraw the translation as an in-place replacement.
    var appearance = OverlaySourceAppearance.fallback
    /// Tighter Vision word/line regions that contain the source glyphs. The
    /// paragraph box remains the layout anchor; only these patches are painted.
    var replacementPatches = [OverlaySourcePatch]()
    /// Vision word ranges retained separately from restoration patches. Patches
    /// may be consolidated on a flat surface, while these runs must stay intact
    /// for mixed foreground, weight, underline, and inline-code styling.
    var styleRuns = [OverlaySourceStyleRun]()
    /// Grapheme geometry for compact labels whose script does not require
    /// whitespace between words. Used only before paragraph composition.
    var spacingAnchors = [OCRTextAnchor]()
    /// Verified empty space for translated text. Never used as an erasure mask.
    var layoutBounds: CGRect?
    /// Alignment inferred by Vision from the original paragraph.
    var alignment: OverlayTextAlignment?
    /// Pixel-inferred closed region that may safely contain replacement text.
    var surface: OverlaySourceSurface?
    var tableCell: OCRTableCell?
    var recognitionLanguages = [String]()
    var continuesToNextLine: Bool?
    /// Independent image input for language context after composition. Native
    /// paragraph IDs describe text flow, not the language of neighboring pages.
    var recognitionContextID: Int?
    /// This input's bounds in capture coordinates, retained for layout after
    /// independently analyzed content is composed onto a larger canvas.
    var recognitionContextBounds: CGRect?

    /// Independent control fragments use measurements owned by their own runs.
    /// A larger marker in the parent row must not determine the label's style.
    mutating func adoptFragmentAppearance(from measuredRuns: [OverlaySourceStyleRun]) {
      let measuredRuns = measuredRuns.filter { $0.range.length > 0 && Range($0.range, in: text) != nil }
      var covered = IndexSet()
      for run in measuredRuns { covered.insert(integersIn: run.range.location..<NSMaxRange(run.range)) }
      // A complete short emphasis span cannot speak for a longer partial or
      // unmeasured body span. Keep the composed parent style in that case.
      guard
        !text.isEmpty, text.utf16.enumerated().allSatisfy({ offset, unit in
          if covered.contains(offset) { return true }
          guard let scalar = UnicodeScalar(unit) else { return false }
          return CharacterSet.whitespacesAndNewlines.contains(scalar)
        })
      else { return }
      guard
        let representative = measuredRuns.max(by: { $0.range.length < $1.range.length }),
        representative.appearance.fontSizeScale > 0
      else { return }
      appearance = representative.appearance
      horizontalInkScale = representative.appearance.inkHeightScale
      horizontalGlyphScale = boundingBoxNormalized.height
    }
  }

  var lines: [Line]
  /// Diagnostic timings for one completed pass; not used for grouping or reuse.
  var stageDurations = [String: Double]()
  /// Native-document inputs in original pixels. A full-frame request is recorded
  /// explicitly; coverage/recovery still inspect the complete source image.
  var documentRegions = [CGRect]()
  var documentOwnershipRegions = [[CGRect]]()

  var joinedText: String {
    lines.map(\.text).joined(separator: "\n")
  }

  /// Joins fragments that Vision occasionally returns as separate paragraphs
  /// even though their boxes form one contiguous text block.
  ///
  /// The test is intentionally geometric and conservative. Vertical fragments
  /// must be neighboring columns; horizontal fragments must be aligned rows
  /// with matching line scale. Connected components join longer blocks without
  /// widening either threshold.
  func coalescingParagraphFragments(
    clearVerticalExpansion: ((OCRVerticalParagraphGrouping.Region, OCRVerticalParagraphGrouping.Region) -> Bool)? = nil
  ) -> OCRResult {
    guard lines.count > 1 else { return self }

    let compactPeerIndices = Self.compactPeerFragmentIndices(in: lines)
    let rowBounds = Self.inlineRowBounds(in: lines, compactPeers: compactPeerIndices)
    let verticalLinks = OCRVerticalParagraphGrouping.links(
      in: lines,
      compatible: { Self.hasCompatibleVerticalAppearance($0, $1) && !Self.hasMaterialTypographyBreak($0, $1) },
      clearExpansion: clearVerticalExpansion
    )
    let horizontalGroups = Dictionary(
      grouping: lines.filter { !$0.isVerticalBlock && $0.recognitionGroupID != nil },
      by: { $0.recognitionGroupID! }
    )
    let horizontalContext = horizontalGroups.mapValues { group -> HorizontalParagraphContext in
      let physicalRows = Self.horizontalVisualRows(group)
      let rows = physicalRows.map { row in
        row.dropFirst().reduce(row[0].boundingBoxNormalized) { $0.union($1.boundingBoxNormalized) }
      }.sorted { $0.midY < $1.midY }
      let advances = zip(rows, rows.dropFirst()).map { $1.midY - $0.midY }.filter { $0 > 0 }.sorted()
      let text = group.sorted { $0.boundingBoxNormalized.minY < $1.boundingBoxNormalized.minY }.map(\.text).joined(separator: " ")
      return HorizontalParagraphContext(
        text: text,
        isTerminated: OCRTextSemantics.endsSentence(text),
        rowCount: physicalRows.reduce(0) { $0 + ($1.map(\.rowCount).max() ?? 1) },
        maximumRowWidth: rows.map(\.width).max() ?? 0,
        advance: rows.count >= 3 && !advances.isEmpty ? advances[advances.count / 2] : nil
      )
    }
    var visited = Array(repeating: false, count: lines.count)
    var groups = [[Int]]()
    for start in lines.indices where !visited[start] {
      visited[start] = true
      var queue = [start]
      var group = [start]
      while let index = queue.popLast() {
        for candidate in lines.indices where !visited[candidate] {
          let suppressesInlineMerge = compactPeerIndices.contains(index)
            && compactPeerIndices.contains(candidate)
          guard
            Self.areAdjacentFragments(
              lines[index],
              lines[candidate],
              suppressesInlineMerge: suppressesInlineMerge,
              continuousColumnPitch: verticalLinks.contains(.init(index, candidate)),
              horizontalContext: horizontalContext,
              lhsRowBounds: rowBounds[index],
              rhsRowBounds: rowBounds[candidate]
            ),
            !Self.hasInterveningRow(between: lines[index], and: lines[candidate], among: lines)
          else { continue }
          visited[candidate] = true
          queue.append(candidate)
          group.append(candidate)
        }
      }
      groups.append(group.sorted())
    }

    let merged = groups.map { indices -> (firstIndex: Int, line: Line) in
      guard indices.count > 1 else { return (indices[0], lines[indices[0]]) }
      let fragments = indices.map { lines[$0] }
      let isVertical = fragments.contains(where: \.isVerticalBlock)
      let script = OverlayTextFlowResolver.scriptEvidence(
        in: fragments.map(\.text).joined()
      ).dominantScript
      let ordered: [Line] =
        if isVertical {
          fragments.sorted { lhs, rhs in
            if lhs.boundingBoxNormalized.midX == rhs.boundingBoxNormalized.midX {
              return lhs.boundingBoxNormalized.minY < rhs.boundingBoxNormalized.minY
            }
            return script == "Mong"
              ? lhs.boundingBoxNormalized.midX < rhs.boundingBoxNormalized.midX
              : lhs.boundingBoxNormalized.midX > rhs.boundingBoxNormalized.midX
          }
        } else {
          Self.orderedHorizontalFragments(fragments, script: script)
        }
      // Vision rows inside one paragraph are visual wraps, not semantic line
      // breaks. Feeding them to Translation as newlines can turn a wrapped row
      // into a new paragraph and add a blank line in the target. Preserve row
      // count for layout, but reconstruct the sentence as continuous text.
      let joined = Self.joinedTextAndSeparators(in: ordered, isVertical: isVertical, script: script)
      let text = joined.text
      let box = fragments.dropFirst().reduce(fragments[0].boundingBoxNormalized) {
        $0.union($1.boundingBoxNormalized)
      }
      let totalRows = isVertical
        ? fragments.reduce(0) { $0 + max(1, $1.rowCount) }
        : Self.horizontalVisualRowCount(fragments)
      let verticalFragments = fragments.filter { $0.verticalCharScale > 0 }
      let verticalRows = verticalFragments.reduce(0) { $0 + max(1, $1.rowCount) }
      let weightedScale = verticalFragments.reduce(0) {
        $0 + $1.verticalCharScale * CGFloat(max(1, $1.rowCount))
      } / CGFloat(max(1, verticalRows))
      let horizontalFragments = fragments.filter { $0.horizontalGlyphScale > 0 }
      let horizontalRows = horizontalFragments.reduce(0) { $0 + max(1, $1.rowCount) }
      let weightedHorizontalScale = horizontalFragments.reduce(0) {
        $0 + $1.horizontalGlyphScale * CGFloat(max(1, $1.rowCount))
      } / CGFloat(max(1, horizontalRows))
      let horizontalInkFragments = fragments.filter { $0.horizontalInkScale > 0 }
      let horizontalInkRows = horizontalInkFragments.reduce(0) { $0 + max(1, $1.rowCount) }
      let weightedHorizontalInkScale = horizontalInkFragments.reduce(0) {
        $0 + $1.horizontalInkScale * CGFloat(max(1, $1.rowCount))
      } / CGFloat(max(1, horizontalInkRows))
      let horizontalLineAdvanceScale = Self.horizontalLineAdvanceScale(
        in: fragments.filter { !$0.isVerticalBlock }
      )
      let appearance = Self.representativeAppearance(in: fragments)
      let groupIDs = Set(fragments.compactMap(\.recognitionGroupID))
      let rotation = fragments.max { $0.boundingBoxNormalized.width < $1.boundingBoxNormalized.width }?.rotationRadians ?? 0
      return (
        indices[0],
        Line(
          boundingBoxNormalized: box,
          text: text,
          rotationRadians: rotation,
          orientedBox: fragments.contains(where: { $0.orientedBox != nil })
            ? OCRGeometry.combinedFrame(fragments, angle: rotation)
            : nil,
          imageAspectRatio: fragments[0].imageAspectRatio,
          needsReview: fragments.contains(where: \.needsReview),
          recognitionConfidence: fragments.map(\.recognitionConfidence).min() ?? 1,
          rowCount: totalRows,
          isVerticalBlock: isVertical,
          verticalCharScale: weightedScale,
          horizontalGlyphScale: weightedHorizontalScale,
          horizontalInkScale: weightedHorizontalInkScale,
          horizontalLineAdvanceScale: horizontalLineAdvanceScale,
          // Keep a stable representative after crossing a Vision paragraph
          // boundary. Dropping the id made a second coalescing pass treat the
          // merged block as ungrouped and absorb an adjacent title/body row.
          recognitionGroupID: groupIDs.min(),
          recognitionContainer: fragments[0].recognitionContainer,
          followingSeparator: ordered.last?.followingSeparator,
          wasCoalesced: true,
          isReconstructedTextRegion: fragments.allSatisfy {
            $0.surface?.confidence == 1 && $0.surface?.clippingRows.isEmpty == false
          },
          appearance: appearance,
          replacementPatches: fragments.flatMap(\.replacementPatches),
          styleRuns: Self.mergedStyleRuns(in: ordered, separators: joined.separators),
          alignment: Self.mergedAlignment(for: ordered, isVertical: isVertical),
          surface: Self.preferredSurface(containing: box, among: fragments),
          tableCell: fragments[0].tableCell,
          recognitionLanguages: Set(fragments.flatMap(\.recognitionLanguages)).sorted(),
          continuesToNextLine: ordered.last?.continuesToNextLine
        )
      )
    }

    return OCRResult(lines: merged.sorted { $0.firstIndex < $1.firstIndex }.map(\.line))
  }

  /// Removes nested observations emitted for the same pixels. Dense controls
  /// can be reported once as a complete row ("Teams | Apps | Users") and again
  /// as an inner word ("Apps"). Rendering both creates overlapping translations
  /// even though each individual Vision observation is valid.
  func removingNestedDuplicates() -> OCRResult {
    OCRResult(lines: OCRCandidateReconciler.canonical(lines))
  }

  /// Japanese ruby is sometimes emitted as a separate tiny horizontal line
  /// immediately above its base ideographs. It is pronunciation metadata, not a
  /// second sentence. Erase it with the base run while retaining the base glyph
  /// scale and text so translation and layout happen exactly once.
  func absorbingRubyAnnotations() -> OCRResult {
    guard lines.count > 1 else { return self }
    var result = lines
    var removed = Set<Int>()

    for rubyIndex in result.indices {
      guard !removed.contains(rubyIndex), Self.isLikelyRuby(result[rubyIndex]) else { continue }
      let ruby = result[rubyIndex]
      let rubyBox = ruby.boundingBoxNormalized.standardized
      let baseIndex = result.indices
        .filter { $0 != rubyIndex && !removed.contains($0) }
        .filter { Self.canBeRubyBase(result[$0], for: ruby) }
        .min { lhs, rhs in
          Self.rubyBaseDistance(result[lhs], rubyBox)
            < Self.rubyBaseDistance(result[rhs], rubyBox)
        }
      guard let baseIndex else { continue }

      var base = result[baseIndex]
      let baseBox = base.boundingBoxNormalized.standardized
      base.orientedBox = base.orientedBox ?? baseBox
      if base.replacementPatches.isEmpty { base.replacementPatches = [OverlaySourcePatch(
        box: baseBox,
        appearance: base.appearance
      )] }
      base.boundingBoxNormalized = baseBox.union(rubyBox)
      let annotations = ruby.replacementPatches.isEmpty
        ? [OverlaySourcePatch(box: rubyBox, appearance: ruby.appearance)]
        : ruby.replacementPatches
      base.replacementPatches.append(contentsOf: annotations.map { patch in
        var patch = patch
        patch.isAnnotation = true
        return patch
      })
      base.surface = Self.preferredSurface(
        containing: base.boundingBoxNormalized,
        among: [base, ruby]
      ) ?? base.surface
      result[baseIndex] = base
      removed.insert(rubyIndex)
    }

    return OCRResult(lines: result.indices.compactMap { removed.contains($0) ? nil : result[$0] })
  }

  // MARK: Private

  private struct AppearanceSample {
    var appearance: OverlaySourceAppearance
    var weight: CGFloat
  }

  private struct HorizontalParagraphContext {
    var text: String
    var isTerminated: Bool
    var rowCount: Int
    var maximumRowWidth: CGFloat
    var advance: CGFloat?
  }

  /// Paragraph adjacency compares whole physical rows. Two styled fragments
  /// can collectively align with the next row even when neither does alone.
  /// This avoids using a non-adjacent A-to-C edge to connect a split middle row.
  private static func inlineRowBounds(in lines: [Line], compactPeers: Set<Int>) -> [CGRect] {
    var parents = Array(lines.indices)
    func root(_ index: Int) -> Int {
      var index = index
      while parents[index] != index { index = parents[index] }
      return index
    }
    for a in lines.indices where !lines[a].isVerticalBlock && !lines[a].preventsJoining {
      for b in lines.indices where b > a && !lines[b].isVerticalBlock && !lines[b].preventsJoining {
        guard
          !(compactPeers.contains(a) && compactPeers.contains(b)),
          !OCRTextSemantics.isCode(lines[a].text), !OCRTextSemantics.isCode(lines[b].text),
          areNeighboringInlineFragments(lines[a], lines[b])
        else { continue }
        parents[root(b)] = root(a)
      }
    }
    var boxes = [Int: CGRect]()
    for index in lines.indices {
      let key = root(index)
      boxes[key] = boxes[key].map { $0.union(lines[index].boundingBoxNormalized) } ?? lines[index].boundingBoxNormalized
    }
    return lines.indices.map { boxes[root($0)]! }
  }

  /// A connected-component edge may not jump over another physical text row.
  /// Otherwise A+C can surround an excluded B, producing overlapping owners
  /// even though each individual translation fits its own bounding rectangle.
  private static func hasInterveningRow(between lhs: Line, and rhs: Line, among lines: [Line]) -> Bool {
    guard !lhs.isVerticalBlock, !rhs.isVerticalBlock else { return false }
    let a = lhs.boundingBoxNormalized
    let b = rhs.boundingBoxNormalized
    let top = min(a.midY, b.midY)
    let bottom = max(a.midY, b.midY)
    guard bottom - top > min(a.height, b.height) * 0.8 else { return false }
    let left = max(a.minX, b.minX)
    let right = min(a.maxX, b.maxX)
    guard right > left else { return false }
    return lines.contains { line in
      let box = line.boundingBoxNormalized
      guard
        line != lhs, line != rhs, !line.isVerticalBlock,
        box.midY > top + box.height * 0.25, box.midY < bottom - box.height * 0.25,
        box.width >= min(a.width, b.width) * 0.25
      else { return false }
      let overlap = min(right, box.maxX) - max(left, box.minX)
      return overlap >= min(right - left, box.width) * 0.5
    }
  }

  private static func preferredSurface(
    containing sourceBox: CGRect,
    among fragments: [Line]
  ) -> OverlaySourceSurface? {
    let source = sourceBox.standardized
    let sourceArea = max(0.000_001, source.width * source.height)
    let candidates = fragments.compactMap(\.surface)
    let enclosing = candidates.filter { surface in
      let bounds = (surface.clippingBox ?? surface.box).standardized
      let intersection = bounds.intersection(source)
      guard !intersection.isNull, !intersection.isEmpty else { return false }
      return intersection.width * intersection.height / sourceArea >= 0.94
    }
    return enclosing.min { lhs, rhs in
      let lhsBounds = (lhs.clippingBox ?? lhs.box).standardized
      let rhsBounds = (rhs.clippingBox ?? rhs.box).standardized
      let lhsArea = lhsBounds.width * lhsBounds.height
      let rhsArea = rhsBounds.width * rhsBounds.height
      if abs(lhsArea - rhsArea) > sourceArea * 0.05 {
        return lhsArea < rhsArea
      }
      return lhs.confidence > rhs.confidence
    } ?? candidates.max(by: { $0.confidence < $1.confidence })
  }

  private static func areAdjacentFragments(
    _ lhs: Line,
    _ rhs: Line,
    suppressesInlineMerge: Bool,
    continuousColumnPitch: Bool,
    horizontalContext: [Int: HorizontalParagraphContext],
    lhsRowBounds: CGRect,
    rhsRowBounds: CGRect
  ) -> Bool {
    guard
      !lhs.isReconstructedTextRegion, !rhs.isReconstructedTextRegion, !lhs.preventsJoining,
      !rhs.preventsJoining
    else { return false }
    guard !OCRTextSemantics.isCode(lhs.text), !OCRTextSemantics.isCode(rhs.text) else { return false }
    guard lhs.recognitionContainer == rhs.recognitionContainer else { return false }
    guard abs(lhs.rotationRadians - rhs.rotationRadians) <= 0.04 else { return false }
    return switch (lhs.isVerticalBlock, rhs.isVerticalBlock) {
    case (true, true):
      areNeighboringVerticalColumns(lhs, rhs, continuousColumnPitch: continuousColumnPitch)
    case (true, false):
      isShortVerticalContinuation(rhs, of: lhs)
    case (false, true):
      isShortVerticalContinuation(lhs, of: rhs)
    case (false, false):
      areNeighboringHorizontalRows(
        withRowBounds(lhs, lhsRowBounds),
        withRowBounds(rhs, rhsRowBounds),
        context: horizontalContext
      )
        || (!suppressesInlineMerge && areNeighboringInlineFragments(lhs, rhs))
    }
  }

  private static func withRowBounds(_ line: Line, _ bounds: CGRect) -> Line {
    guard line.boundingBoxNormalized != bounds else { return line }
    var line = line
    line.boundingBoxNormalized = bounds
    line.orientedBox = nil
    return line
  }

  /// A run of compact peers (badges, segmented labels, or key/value pills) is
  /// visual structure, not one sentence. Vision can assign every peer to one
  /// recognition group, while surface analysis only finds some of the rounded
  /// halves. Detect the whole row before graph coalescing so an undetected half
  /// cannot bridge otherwise independent controls transitively.
  private static func compactPeerFragmentIndices(in lines: [Line]) -> Set<Int> {
    var rows = [[Int]]()
    for index in lines.indices {
      let line = lines[index]
      guard !line.isVerticalBlock, line.rowCount == 1 else { continue }
      if
        let rowIndex = rows.lastIndex(where: { row in
          row.contains { isOnSameVisualRow(line, lines[$0]) }
        })
      {
        rows[rowIndex].append(index)
      } else {
        rows.append([index])
      }
    }

    return Set(rows.filter { isCompactPeerRow($0, in: lines) }.flatMap { $0 })
  }

  private static func isCompactPeerRow(_ indices: [Int], in lines: [Line]) -> Bool {
    guard indices.count >= 4 else { return false }
    let fragments = indices.map { lines[$0] }
    let boxes = fragments.map(\.boundingBoxNormalized).map(\.standardized)
    guard
      zip(fragments, boxes).allSatisfy({ fragment, box in
        let text = fragment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty
          && !text.contains("\n")
          && text.count <= 24
          && box.width > 0
          && box.width <= 0.16
          && box.height > 0
      })
    else { return false }

    let ordered = indices.sorted {
      lines[$0].boundingBoxNormalized.midX < lines[$1].boundingBoxNormalized.midX
    }
    let formsOneCompactRun = zip(ordered, ordered.dropFirst()).allSatisfy { lhs, rhs in
      let a = lines[lhs].boundingBoxNormalized.standardized
      let b = lines[rhs].boundingBoxNormalized.standardized
      let gap = max(0, b.minX - a.maxX)
      return gap <= max(a.height, b.height) * 0.8
    }
    guard formsOneCompactRun else { return false }

    let compactSurfaceCount = fragments.count(where: hasCompactSurface)
    let appearanceTransitions = zip(ordered, ordered.dropFirst()).count { lhs, rhs in
      colorDistance(lines[lhs].appearance.background, lines[rhs].appearance.background) >= 0.12
    }
    return compactSurfaceCount >= 2 || appearanceTransitions >= 3
  }

  private static func mergedStyleRuns(
    in lines: [Line],
    separators: [String]
  ) -> [OverlaySourceStyleRun] {
    var result = [OverlaySourceStyleRun]()
    var utf16Offset = 0
    for (index, line) in lines.enumerated() {
      result.append(contentsOf: line.styleRuns.map { run in
        var run = run
        run.range.location += utf16Offset
        return run
      })
      utf16Offset += line.text.utf16.count
      if separators.indices.contains(index) {
        utf16Offset += separators[index].utf16.count
      }
    }
    return result
  }

  private static func joinedTextAndSeparators(
    in lines: [Line],
    isVertical: Bool,
    script: String?
  ) -> (text: String, separators: [String]) {
    let texts = lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let first = texts.first else { return ("", []) }
    var text = first
    var separators = [String]()
    for index in texts.indices.dropFirst() {
      let separator = isVertical
        ? (script == "Mong" ? " " : "")
        : horizontalSeparator(
          after: lines[index - 1],
          before: lines[index],
          nextText: texts[index],
          among: lines
        )
      separators.append(separator)
      text += separator + texts[index]
    }
    return (text, separators)
  }

  private static func horizontalSeparator(
    after previous: Line,
    before next: Line,
    nextText: String,
    among lines: [Line]
  ) -> String {
    if
      let last = previous.text.last, let first = nextText.first,
      last.unicodeScalars.allSatisfy({ (0x3040...0x9FFF).contains($0.value) }),
      first.unicodeScalars.allSatisfy({ (0x3040...0x9FFF).contains($0.value) }) { return "" }
    if
      previous.recognitionGroupID != nil, previous.recognitionGroupID == next.recognitionGroupID,
      let separator = previous.followingSeparator { return separator }
    if preservesSemanticLineBreak(after: previous, before: next, among: lines) {
      return "\n"
    }
    let text = nextText
    guard let first = text.first else { return " " }
    let noLeadingSpace = CharacterSet(charactersIn: ",;:!?、。！？）」』】")
    guard first.unicodeScalars.allSatisfy(noLeadingSpace.contains) else { return " " }
    let next = text.index(after: text.startIndex)
    return next == text.endIndex || text[next].isWhitespace ? "" : " "
  }

  /// Vision sometimes flattens an explicit `<br>` into ordinary wrapped rows.
  /// A non-final row that ends a sentence despite having enough room for the
  /// next token is a semantic break, not automatic wrapping. Preserve it for
  /// Translation and Core Text so emphasis does not collapse two rows into one.
  private static func preservesSemanticLineBreak(
    after previous: Line,
    before next: Line,
    among lines: [Line]
  ) -> Bool {
    guard
      !previous.isVerticalBlock,
      !next.isVerticalBlock,
      previous.alignment != .center,
      previous.alignment != .trailing,
      next.alignment != .center,
      next.alignment != .trailing
    else { return false }

    let previousBox = previous.boundingBoxNormalized.standardized
    let nextBox = next.boundingBoxNormalized.standardized
    let boxes = lines.map(\.boundingBoxNormalized).map(\.standardized)
    guard
      previousBox.width > 0,
      previousBox.height > 0,
      nextBox.width > 0,
      nextBox.height > 0,
      let commonLeadingEdge = boxes.map(\.minX).sorted().dropFirst(boxes.count / 2).first,
      let commonTrailingEdge = boxes.map(\.maxX).max()
    else { return false }

    let rowHeight = max(previousBox.height, nextBox.height)
    let leadingTolerance = max(0.002, rowHeight * 0.8)
    guard
      abs(previousBox.minX - commonLeadingEdge) <= leadingTolerance,
      abs(nextBox.minX - commonLeadingEdge) <= leadingTolerance
    else { return false }

    let columnWidth = commonTrailingEdge - commonLeadingEdge
    let unusedTail = commonTrailingEdge - previousBox.maxX
    guard columnWidth > 0, unusedTail / columnWidth >= 0.16 else { return false }

    let nextTokenWidth = next.styleRuns
      .min(by: { $0.range.location < $1.range.location })?
      .box.width ?? min(nextBox.width, rowHeight * 4)
    guard unusedTail >= max(nextTokenWidth * 1.45, rowHeight * 1.8) else { return false }

    let trimmed = previous.text.trimmingCharacters(in: .whitespacesAndNewlines)
    let endsSentence = trimmed.last?.unicodeScalars.allSatisfy(
      CharacterSet(charactersIn: ".!?:。！？：").contains
    ) == true
    let previousScale = previous.horizontalGlyphScale > 0
      ? previous.horizontalGlyphScale
      : previousBox.height / CGFloat(max(1, previous.rowCount))
    let nextScale = next.horizontalGlyphScale > 0
      ? next.horizontalGlyphScale
      : nextBox.height / CGFloat(max(1, next.rowCount))
    let scaleRatio = max(previousScale, nextScale) / max(0.000_001, min(previousScale, nextScale))
    return endsSentence || scaleRatio >= 1.3
  }

  private static func horizontalVisualRowCount(_ lines: [Line]) -> Int {
    horizontalVisualRows(lines).reduce(0) { total, row in
      total + (row.map(\.rowCount).max() ?? 1)
    }
  }

  private static func horizontalLineAdvanceScale(in lines: [Line]) -> CGFloat {
    var advances = lines.flatMap { line -> [CGFloat] in
      guard line.horizontalLineAdvanceScale > 0 else { return [] }
      return Array(
        repeating: line.horizontalLineAdvanceScale,
        count: max(1, line.rowCount - 1)
      )
    }
    let atomicRows = horizontalVisualRows(lines.filter { $0.rowCount == 1 })
      .map { row in
        row.dropFirst().reduce(row[0].boundingBoxNormalized.standardized) {
          $0.union($1.boundingBoxNormalized.standardized)
        }
      }
      .sorted { $0.midY < $1.midY }
    advances.append(contentsOf: zip(atomicRows, atomicRows.dropFirst()).compactMap { previous, next in
      let advance = next.midY - previous.midY
      return advance > 0 ? advance : nil
    })

    guard !advances.isEmpty else { return 0 }
    let sorted = advances.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
  }

  private static func horizontalVisualRows(_ lines: [Line]) -> [[Line]] {
    var rows = [[Line]]()
    for line in lines.sorted(by: { $0.boundingBoxNormalized.minY < $1.boundingBoxNormalized.minY }) {
      if
        let index = rows.lastIndex(where: { row in
          row.contains { isOnSameVisualRow(line, $0) }
        })
      {
        rows[index].append(line)
      } else {
        rows.append([line])
      }
    }
    return rows
  }

  private static func representativeAppearance(in lines: [Line]) -> OverlaySourceAppearance {
    let containerLines = lines.filter { !hasCompactSurface($0) }
    let sampledLines = containerLines.isEmpty ? lines : containerLines
    let samples = sampledLines.flatMap { line -> [AppearanceSample] in
      guard !line.styleRuns.isEmpty else {
        return [AppearanceSample(
          appearance: line.appearance,
          weight: CGFloat(max(1, line.text.utf16.count))
        )]
      }
      return line.styleRuns.map {
        AppearanceSample(
          appearance: $0.appearance,
          weight: CGFloat(max(1, $0.range.length))
        )
      }
    }
    guard
      let best = samples.max(by: { lhs, rhs in
        let lhsScore = appearanceClusterScore(for: lhs, among: samples)
        let rhsScore = appearanceClusterScore(for: rhs, among: samples)
        if lhsScore == rhsScore {
          return lhs.appearance.confidence < rhs.appearance.confidence
        }
        return lhsScore < rhsScore
      })
    else { return .fallback }
    return best.appearance
  }

  private static func hasCompactSurface(_ line: Line) -> Bool {
    guard let surface = line.surface else { return false }
    let source = line.boundingBoxNormalized.standardized
    let bounds = (surface.clippingBox ?? surface.box).standardized
    guard bounds.contains(CGPoint(x: source.midX, y: source.midY)) else { return false }
    return bounds.width <= source.width * 2.2
      && bounds.height <= source.height * 3
  }

  private static func appearanceClusterScore(
    for candidate: AppearanceSample,
    among samples: [AppearanceSample]
  ) -> CGFloat {
    samples.reduce(0) { score, sample in
      guard
        colorDistance(candidate.appearance.background, sample.appearance.background) <= 0.06,
        colorDistance(candidate.appearance.foreground, sample.appearance.foreground) <= 0.15
      else { return score }
      return score + sample.weight
    }
  }

  private static func areNeighboringVerticalColumns(_ lhs: Line, _ rhs: Line, continuousColumnPitch: Bool) -> Bool {
    /// Ruby expands the erasure envelope without moving the base columns.
    /// Neighboring text must be compared using its preserved physical geometry.
    let a = OCRVerticalParagraphGrouping.bounds(lhs)
    let b = OCRVerticalParagraphGrouping.bounds(rhs)
    guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }

    let minimumWidth = min(a.width, b.width)
    let horizontalOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    guard horizontalOverlap <= minimumWidth * 0.15 else { return false }

    let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
    let sameRecognitionGroup = lhs.recognitionGroupID != nil
      && lhs.recognitionGroupID == rhs.recognitionGroupID
    let knownSharedSurface = sharesSourceSurface(lhs, rhs)
    if !knownSharedSurface, hasMaterialTypographyBreak(lhs, rhs) { return false }
    let gapScale: CGFloat = sameRecognitionGroup || knownSharedSurface ? 0.75 : 0.25
    guard continuousColumnPitch || horizontalGap <= minimumWidth * gapScale else { return false }

    let verticalOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    guard verticalOverlap / min(a.height, b.height) >= 0.7 else { return false }

    let scales = [lhs.verticalCharScale, rhs.verticalCharScale].filter { $0 > 0 }
    guard scales.count < 2 || scales.min()! / scales.max()! >= 0.65 else { return false }
    return true
  }

  private static func orderedHorizontalFragments(_ fragments: [Line], script: String?) -> [Line] {
    let topToBottom = fragments.sorted {
      let lhs = $0.boundingBoxNormalized.standardized
      let rhs = $1.boundingBoxNormalized.standardized
      if lhs.minY == rhs.minY { return lhs.minX < rhs.minX }
      return lhs.minY < rhs.minY
    }
    var rows = [[Line]]()
    for fragment in topToBottom {
      if
        let index = rows.lastIndex(where: { row in
          row.contains { isOnSameVisualRow(fragment, $0) }
        })
      {
        rows[index].append(fragment)
      } else {
        rows.append([fragment])
      }
    }
    return rows.flatMap { row in
      row.sorted {
        let lhs = $0.boundingBoxNormalized.standardized
        let rhs = $1.boundingBoxNormalized.standardized
        return script == "Arab" ? lhs.midX > rhs.midX : lhs.midX < rhs.midX
      }
    }
  }

  private static func isOnSameVisualRow(_ lhs: Line, _ rhs: Line) -> Bool {
    let (a, b) = OCRGeometry.alignedPair(lhs, rhs)
    guard a.height > 0, b.height > 0 else { return false }
    let verticalOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    return verticalOverlap / min(a.height, b.height) >= 0.55
  }

  private static func areNeighboringInlineFragments(_ lhs: Line, _ rhs: Line) -> Bool {
    guard lhs.rowCount == 1, rhs.rowCount == 1 else { return false }
    let a = lhs.boundingBoxNormalized.standardized
    let b = rhs.boundingBoxNormalized.standardized
    guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
    let verticalOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    guard verticalOverlap / min(a.height, b.height) >= 0.65 else { return false }
    guard min(a.height, b.height) / max(a.height, b.height) >= 0.6 else { return false }

    let minimumWidth = min(a.width, b.width)
    let horizontalOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    guard horizontalOverlap <= minimumWidth * 0.15 else { return false }
    let horizontalGap = max(0, max(a.minX, b.minX) - min(a.maxX, b.maxX))
    // x and y are normalized independently. Compare distances in image units,
    // otherwise wide captures merge navigation links separated by several ems.
    let aspect = max(0.01, lhs.imageAspectRatio)
    guard horizontalGap * aspect <= max(a.height, b.height) * 0.6 else { return false }
    if
      lhs.recognitionGroupID != rhs.recognitionGroupID,
      horizontalGap * aspect > max(a.height, b.height) * 0.32 { return false }

    if lhs.surface != nil, rhs.surface != nil, !sharesSourceSurface(lhs, rhs) {
      return false
    }
    return true
  }

  private static func isShortVerticalContinuation(_ fragment: Line, of vertical: Line) -> Bool {
    guard !fragment.isVerticalBlock, vertical.isVerticalBlock, fragment.text.count <= 3 else { return false }
    let evidence = OverlayTextFlowResolver.scriptEvidence(in: fragment.text)
    let punctuationOnly = fragment.text.unicodeScalars.allSatisfy {
      CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
    }
    guard evidence.verticalCharacterCount > 0 || punctuationOnly else { return false }

    let shortBox = fragment.boundingBoxNormalized.standardized
    let verticalBox = vertical.boundingBoxNormalized.standardized
    guard shortBox.height <= verticalBox.height * 0.4 else { return false }
    if sharesSourceSurface(fragment, vertical) {
      let horizontalGap = max(
        0,
        max(shortBox.minX, verticalBox.minX) - min(shortBox.maxX, verticalBox.maxX)
      )
      let verticalOverlap = max(
        0,
        min(shortBox.maxY, verticalBox.maxY) - max(shortBox.minY, verticalBox.minY)
      )
      if
        horizontalGap <= min(shortBox.width, verticalBox.width) * 0.75,
        verticalOverlap / min(shortBox.height, verticalBox.height) >= 0.7
      {
        return true
      }
    }
    return areSideBySide(shortBox, verticalBox, requiredVerticalOverlap: 0.7)
  }

  private static func areNeighboringHorizontalRows(
    _ lhs: Line,
    _ rhs: Line,
    context: [Int: HorizontalParagraphContext]
  ) -> Bool {
    let (a, b) = OCRGeometry.alignedPair(lhs, rhs)
    guard a.width > 0, a.height > 0, b.width > 0, b.height > 0 else { return false }
    let lowerLine = a.minY <= b.minY ? rhs : lhs
    let upperLine = a.minY <= b.minY ? lhs : rhs
    let nativeContinuation = upperLine.continuesToNextLine == true
      && upperLine.recognitionGroupID != nil && upperLine.recognitionGroupID == lowerLine.recognitionGroupID
    let observedAdvance = [lhs.recognitionGroupID, rhs.recognitionGroupID].compactMap { $0.flatMap { context[$0]?.advance } }
      .min()
    if
      lhs.rowCount == 1, rhs.rowCount == 1, let observedAdvance,
      abs(a.midY - b.midY) > observedAdvance * 1.45
    {
      // A paragraph margin remains a boundary even if OCR attaches a citation
      // to the preceding sentence and punctuation no longer looks complete.
      return false
    }
    let upperContext = upperLine.recognitionGroupID.flatMap { context[$0] }
    let lowerContext = lowerLine.recognitionGroupID.flatMap { context[$0] }
    let upperText = (upperContext?.text ?? upperLine.text)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let upperIsTerminated = upperContext?.isTerminated ?? OCRTextSemantics.endsSentence(upperText)
    let hasEarlierSentence = upperText.range(of: #"(?:[.!?]\s+|[。！？]\s*)\S"#, options: .regularExpression) != nil
    let calibrated = [lhs.appearance.fontSizeScale, rhs.appearance.fontSizeScale].filter { $0 > 0 }
    let ink = [lhs.horizontalInkScale, rhs.horizontalInkScale]
    let matchingInk = ink.min()! > 0 && ink.min()! / ink.max()! >= 0.9
    let compatibleSize = calibrated.count < 2 || calibrated.min()! / calibrated.max()! >= 0.8 || matchingInk
    let continuesSentence = (
      hasEarlierSentence || (lowerLine.text.first?.isLowercase == true
        && upperText.split(whereSeparator: \.isWhitespace).count >= 6)
    ) && !upperIsTerminated
      && hasCompatibleAppearance(lhs, rhs) && compatibleSize
      && (hasEarlierSentence || abs(lhs.appearance.fontWeight.rawValue - rhs.appearance.fontWeight.rawValue) <= 1)
    // A list marker is a semantic paragraph boundary even when the neighboring
    // item is multiline, shares the same appearance, and sits at ordinary CSS
    // line spacing. Without this boundary, connected-component coalescing can
    // link `item -> continuation -> next item` and translate an entire list as
    // one oversized paragraph. The unmarked continuation is still free to join
    // the item above it.
    guard !OCRTextSemantics.beginsListItem(lowerLine.text) else { return false }
    // A native paragraph id is semantic evidence, not permission to flatten a
    // heading and subtitle. Require calibrated size and actual ink to agree on
    // the size step so short-glyph calibration noise still permits body reflow.
    if !continuesSentence, hasObservedFontSizeBreak(lhs, rhs) { return false }
    let crossesVisionParagraphBoundary = lhs.recognitionGroupID != nil
      && rhs.recognitionGroupID != nil
      && lhs.recognitionGroupID != rhs.recognitionGroupID
    if hasMaterialTypographyBreak(lhs, rhs), !isLowContrastBodyWeightNoise(lhs, rhs), !continuesSentence, !nativeContinuation {
      return false
    }
    let hasContinuousBodyAppearance = hasCompatibleBodyAppearance(lhs, rhs)
    let continuesAcrossParagraphBoundary = crossesVisionParagraphBoundary
      && (sharesSourceSurface(lhs, rhs) || continuesSentence)
      && (hasCompatibleAppearance(lhs, rhs) || hasContinuousBodyAppearance)

    let horizontalOverlap = max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX))
    guard horizontalOverlap / min(a.width, b.width) >= 0.78 else { return false }

    let rowHeightA = a.height / CGFloat(max(1, lhs.rowCount))
    let rowHeightB = b.height / CGFloat(max(1, rhs.rowCount))
    guard min(rowHeightA, rowHeightB) / max(rowHeightA, rowHeightB) >= 0.62 else { return false }
    let verticalGap = max(0, max(a.minY, b.minY) - min(a.maxY, b.maxY))
    // Apple can split one continuous card-body paragraph into several
    // document paragraphs even when no closed source surface is detectable.
    // Rejoin only established multiline body copy on the same visual edge;
    // keeping single-row fragments excluded protects table rows and adjacent
    // labels that merely share typography.
    let edgeTolerance = max(rowHeightA, rowHeightB) * 0.6 / max(0.01, lhs.imageAspectRatio)
    let upperBox = a.minY <= b.minY ? a : b
    let lowerBox = a.minY <= b.minY ? b : a
    let hangingListContinuation = OCRTextSemantics.beginsListItem(upperLine.text)
      && lowerBox.minX >= upperBox.minX
      && lowerBox.minX - upperBox.minX <= edgeTolerance * 2.7
    // A sentence boundary is not necessarily a paragraph boundary. An
    // indented list continuation or already measured multiline block can
    // follow a period without paragraph spacing. Raw single rows alone do
    // not provide that structural evidence.
    let continuesBodyAfterSentence = (hangingListContinuation && lowerBox.minX - upperBox.minX > edgeTolerance * 0.25)
      || (max(lhs.rowCount, rhs.rowCount) > 1 && verticalGap <= min(rowHeightA, rowHeightB) * 0.3)
    let hasParagraphBoundary = upperIsTerminated && !continuesBodyAfterSentence
    let sharesTextColumn = abs(a.minX - b.minX) <= edgeTolerance || hangingListContinuation
      || abs(a.maxX - b.maxX) <= edgeTolerance
      || (lhs.alignment == .center
        && rhs.alignment == .center
        && abs(a.midX - b.midX) <= edgeTolerance)
    // Before coalescing, every observation still reports rowCount == 1.
    // Use physical paragraph rows to recognize a wrapped sentence across
    // Vision IDs, independently of lowercase letters or writing direction.
    // A native detector may detach the first full-width row of a paragraph.
    // A following established body block, a shared edge and physical row
    // width provide script-independent continuation evidence. Weak sampled
    // weight changes are not a new paragraph's boundary.
    // Compare the adjacent rows' columns. A later row may extend below a
    // floated image; that wider row must not invalidate this shared edge.
    let substantialFirstRow = upperBox.width >= lowerBox.width * 0.8
      && upperBox.width * max(0.01, lhs.imageAspectRatio) >= max(rowHeightA, rowHeightB) * 12
    // A detached row can occur at either end of an established paragraph.
    // Requiring the lower group to be multiline excluded its last wrapped row
    // even when the upper group supplied the same continuation evidence.
    let hasEstablishedBodyRows = (upperContext?.rowCount ?? 0) >= 2
      || (substantialFirstRow && (lowerContext?.rowCount ?? 0) >= 2)
    let continuesKnownMultilineParagraph = hasEstablishedBodyRows
      && !hasParagraphBoundary
      && upperBox.width >= (upperContext?.maximumRowWidth ?? 0) * 0.8
      && compatibleSize
      && (abs(lhs.appearance.fontWeight.rawValue - rhs.appearance.fontWeight.rawValue) <= 1
        || isLowContrastBodyWeightNoise(lhs, rhs))
    let continuesUnsurfacedBodyBlock = crossesVisionParagraphBoundary
      && !hasParagraphBoundary
      && lhs.surface == nil
      && rhs.surface == nil
      && (max(lhs.rowCount, rhs.rowCount) > 1 || continuesKnownMultilineParagraph)
      && sharesTextColumn
      && (hasCompatibleAppearance(lhs, rhs) || hasContinuousBodyAppearance)

    if crossesVisionParagraphBoundary {
      // Different paragraph IDs normally represent real structure. Keep
      // overlapping manga fragments together, and also continue web body rows
      // when pixel analysis says they occupy the same surface with the same
      // foreground/background treatment.
      let verticalOverlap = max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
      guard
        verticalOverlap / min(rowHeightA, rowHeightB) >= 0.04
        || continuesAcrossParagraphBoundary
        || continuesUnsurfacedBodyBlock
      else { return false }
    }

    // Vision's line boxes hug visible glyphs, so ascenders/descenders make the
    // apparent inter-row gap vary even when CSS line-height is constant. A
    // little over half a row still joins wrapped body copy, while the much
    // larger title-to-body spacing remains separate.
    let gapScale: CGFloat =
      switch (lhs.recognitionGroupID, rhs.recognitionGroupID) {
      case (.some(let lhs), .some(let rhs)) where lhs == rhs: 1.15
      case _ where continuesAcrossParagraphBoundary || continuesUnsurfacedBodyBlock: 1
      default: 0.55
      }
    guard verticalGap <= min(rowHeightA, rowHeightB) * gapScale else { return false }
    if nativeContinuation, sharesTextColumn { return true }
    if
      hangingListContinuation,
      lhs.recognitionGroupID == rhs.recognitionGroupID { return true }
    if continuesAcrossParagraphBoundary || continuesUnsurfacedBodyBlock { return true }
    let alignmentTolerance = edgeTolerance
    // Paragraph alignment hints can be wrong for RTL text. A shared observed
    // edge is stronger evidence once typography, spacing, and group agree.
    if
      lhs.recognitionGroupID != nil, lhs.recognitionGroupID == rhs.recognitionGroupID,
      abs(a.minX - b.minX) <= alignmentTolerance || abs(a.maxX - b.maxX) <= alignmentTolerance
    {
      return true
    }
    switch (lhs.alignment, rhs.alignment) {
    case (.leading?, .leading?):
      return abs(a.minX - b.minX) <= alignmentTolerance

    case (.trailing?, .trailing?):
      return abs(a.maxX - b.maxX) <= alignmentTolerance

    case (.center?, .center?):
      // Vision often labels a paragraph centered even when its wrapped rows
      // share a leading edge. Trust the actual row geometry so a shorter final
      // row is not detached from the preceding lines.
      return abs(a.midX - b.midX) <= alignmentTolerance
        || abs(a.minX - b.minX) <= alignmentTolerance
        || abs(a.maxX - b.maxX) <= alignmentTolerance

    default:
      return abs(a.minX - b.minX) <= alignmentTolerance
        || abs(a.maxX - b.maxX) <= alignmentTolerance
        || abs(a.midX - b.midX) <= alignmentTolerance
    }
  }

  private static func mergedAlignment(
    for lines: [Line],
    isVertical: Bool
  ) -> OverlayTextAlignment? {
    let fallback = lines.compactMap(\.alignment).first
    guard !isVertical, lines.count > 1 else { return fallback }
    let boxes = horizontalVisualRows(lines).filter { row in
      row.contains { $0.text.contains(where: \.isLetter) }
    }.map { row in
      row.dropFirst().reduce(row[0].boundingBoxNormalized.standardized) { $0.union($1.boundingBoxNormalized.standardized) }
    }
    return OCRGeometry.horizontalAlignment(forRows: boxes, imageAspectRatio: lines[0].imageAspectRatio) ?? fallback
  }

  private static func sharesSourceSurface(_ lhs: Line, _ rhs: Line) -> Bool {
    guard let lhs = lhs.surface?.box.standardized, let rhs = rhs.surface?.box.standardized else {
      return false
    }
    let intersection = lhs.intersection(rhs)
    guard !intersection.isNull, !intersection.isEmpty else { return false }
    let intersectionArea = intersection.width * intersection.height
    let minimumArea = min(lhs.width * lhs.height, rhs.width * rhs.height)
    return intersectionArea / max(0.000_001, minimumArea) >= 0.85
  }

  private static func hasCompatibleAppearance(_ lhs: Line, _ rhs: Line) -> Bool {
    let lhs = lhs.appearance
    let rhs = rhs.appearance
    guard
      lhs.confidence >= 0.2,
      rhs.confidence >= 0.2,
      lhs.foregroundConfidence >= 0.05,
      rhs.foregroundConfidence >= 0.05
    else { return false }
    return colorDistance(lhs.background, rhs.background) <= 0.06
      && colorDistance(lhs.foreground, rhs.foreground) <= 0.12
      && lhs.fontDesign == rhs.fontDesign
  }

  private static func hasCompatibleVerticalAppearance(_ lhs: Line, _ rhs: Line) -> Bool {
    let a = lhs.appearance
    let b = rhs.appearance
    // Foreground confidence is the sampled ink cluster's population, not a
    // probability that the color is correct. Thin glyphs/ruby legitimately
    // occupy less than5% of a column; observed matching high-contrast colors,
    // repeated pitch and a clear corridor supply the evidence in this path.
    guard
      a.confidence >= 0.2, b.confidence >= 0.2,
      a.foregroundConfidence > 0, b.foregroundConfidence > 0,
      colorDistance(a.foreground, a.background) >= 0.25,
      colorDistance(b.foreground, b.background) >= 0.25
    else { return false }
    return colorDistance(a.background, b.background) <= 0.06
      && colorDistance(a.foreground, b.foreground) <= 0.12 && a.fontDesign == b.fontDesign
  }

  private static func hasCompatibleBodyAppearance(_ lhs: Line, _ rhs: Line) -> Bool {
    guard isBodyCopy(lhs), isBodyCopy(rhs) else { return false }
    return colorDistance(lhs.appearance.background, rhs.appearance.background) <= 0.08
      && colorDistance(lhs.appearance.foreground, rhs.appearance.foreground) <= 0.18
      && lhs.appearance.fontDesign == rhs.appearance.fontDesign
  }

  private static func hasMaterialTypographyBreak(_ lhs: Line, _ rhs: Line) -> Bool {
    let lhsAppearance = lhs.appearance
    let rhsAppearance = rhs.appearance
    let fontScales = [lhsAppearance.fontSizeScale, rhsAppearance.fontSizeScale]
    let matchingInk = lhs.recognitionGroupID != nil && lhs.recognitionGroupID == rhs.recognitionGroupID
      && min(lhs.horizontalInkScale, rhs.horizontalInkScale) > 0
      && max(lhs.horizontalInkScale, rhs.horizontalInkScale) / min(lhs.horizontalInkScale, rhs.horizontalInkScale) <= 1.15
      && min(lhs.horizontalGlyphScale, rhs.horizontalGlyphScale) > 0
      && max(lhs.horizontalGlyphScale, rhs.horizontalGlyphScale) / min(lhs.horizontalGlyphScale, rhs.horizontalGlyphScale) <= 1.15
    if
      !matchingInk, let smaller = fontScales.min(), let larger = fontScales.max(), smaller > 0,
      larger / smaller > 1.24 { return true }
    guard lhsAppearance.confidence >= 0.2, rhsAppearance.confidence >= 0.2 else {
      return false
    }
    if colorDistance(lhsAppearance.background, rhsAppearance.background) > 0.08 { return true }
    if colorDistance(lhsAppearance.foreground, rhsAppearance.foreground) > 0.25 { return true }
    if lhsAppearance.fontDesign != rhsAppearance.fontDesign { return true }

    let weightDifference = abs(lhsAppearance.fontWeight.rawValue - rhsAppearance.fontWeight.rawValue)
    if
      lhsAppearance.foregroundConfidence >= 0.05,
      rhsAppearance.foregroundConfidence >= 0.05,
      weightDifference >= 2
    {
      return true
    }
    // A compact semibold heading and low-contrast body can share Vision's
    // paragraph id and nearly identical glyph height. The confidence step is
    // the reliable boundary; low-confidence body rows still tolerate the same
    // one-weight sampling jitter through isLowContrastBodyWeightNoise.
    return weightDifference >= 1
      && max(lhsAppearance.foregroundConfidence, rhsAppearance.foregroundConfidence) >= 0.45
      && abs(lhsAppearance.foregroundConfidence - rhsAppearance.foregroundConfidence) >= 0.25
  }

  private static func hasObservedFontSizeBreak(_ lhs: Line, _ rhs: Line) -> Bool {
    let fonts = [lhs.appearance.fontSizeScale, rhs.appearance.fontSizeScale]
    let ink = [lhs.horizontalInkScale, rhs.horizontalInkScale]
    guard fonts.min()! > 0, ink.min()! > 0 else { return false }
    return fonts.max()! / fonts.min()! > 1.24 && ink.max()! / ink.min()! > 1.24
      && (fonts[0] > fonts[1]) == (ink[0] > ink[1])
  }

  private static func isLowContrastBodyWeightNoise(_ lhs: Line, _ rhs: Line) -> Bool {
    hasCompatibleBodyAppearance(lhs, rhs)
  }

  private static func isBodyCopy(_ line: Line) -> Bool {
    line.appearance.confidence >= 0.2
      && line.appearance.foregroundConfidence >= 0.02
      && line.appearance.foregroundConfidence <= 0.3
      && line.appearance.fontWeight != .bold
  }

  private static func isLikelyRuby(_ line: Line) -> Bool {
    let scalars = line.text.unicodeScalars.filter {
      !CharacterSet.whitespacesAndNewlines.contains($0)
    }
    guard !scalars.isEmpty, scalars.count <= 24 else { return false }
    let kanaCount = scalars.count(where: isKana)
    let nonPunctuationCount = scalars.count {
      !CharacterSet.punctuationCharacters.contains($0)
        && !CharacterSet.symbols.contains($0)
    }
    return kanaCount > 0 && kanaCount * 4 >= max(1, nonPunctuationCount) * 3
  }

  private static func canBeRubyBase(_ line: Line, for ruby: Line) -> Bool {
    guard line.text.unicodeScalars.contains(where: isHan) else { return false }
    let rubyBox = ruby.boundingBoxNormalized.standardized
    let base = line.boundingBoxNormalized.standardized
    if line.isVerticalBlock {
      let columnWidth = line.verticalCharScale > 0 ? line.verticalCharScale : base.width / CGFloat(max(1, line.rowCount))
      let rubyWidth = ruby.isVerticalBlock && ruby.verticalCharScale > 0
        ? min(rubyBox.width, ruby.verticalCharScale)
        : rubyBox.width
      let overlap = max(0, min(rubyBox.maxY, base.maxY) - max(rubyBox.minY, base.minY))
      return rubyWidth <= columnWidth * 0.7
        && rubyBox.midX >= base.maxX - columnWidth * 0.35
        && rubyBox.minX - base.maxX <= columnWidth * 0.85
        && overlap >= rubyBox.height * 0.7
    }
    guard rubyBox.height <= base.height * 0.7, rubyBox.midY <= base.midY else { return false }
    let overlap = max(0, min(rubyBox.maxX, base.maxX) - max(rubyBox.minX, base.minX))
    guard overlap / max(0.000_001, rubyBox.width) >= 0.7 else { return false }
    let verticalGap = max(0, base.minY - rubyBox.maxY)
    return verticalGap <= max(min(rubyBox.height * 1.5, base.height * 0.7), base.height * 0.25)
  }

  private static func rubyBaseDistance(_ line: Line, _ ruby: CGRect) -> CGFloat {
    let base = line.boundingBoxNormalized.standardized
    if line.isVerticalBlock {
      return abs(base.maxX - ruby.minX) * line.imageAspectRatio
        + max(0, ruby.minY - base.maxY, base.minY - ruby.maxY)
    }
    return abs(base.midX - ruby.midX) + max(0, base.minY - ruby.maxY)
  }

  private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3040 ... 0x30FF,
         0x31F0 ... 0x31FF:
      true
    default:
      false
    }
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x3400 ... 0x4DBF,
         0x4E00 ... 0x9FFF,
         0xF900 ... 0xFAFF,
         0x20000 ... 0x2FA1F:
      true
    default:
      false
    }
  }

  private static func colorDistance(_ lhs: OverlayColor, _ rhs: OverlayColor) -> CGFloat {
    max(abs(lhs.red - rhs.red), abs(lhs.green - rhs.green), abs(lhs.blue - rhs.blue))
  }

  private static func areSideBySide(
    _ lhs: CGRect,
    _ rhs: CGRect,
    requiredVerticalOverlap: CGFloat
  ) -> Bool {
    guard lhs.width > 0, lhs.height > 0, rhs.width > 0, rhs.height > 0 else { return false }
    let minimumWidth = min(lhs.width, rhs.width)
    let horizontalOverlap = max(0, min(lhs.maxX, rhs.maxX) - max(lhs.minX, rhs.minX))
    guard horizontalOverlap <= minimumWidth * 0.15 else { return false }
    let horizontalGap = max(0, max(lhs.minX, rhs.minX) - min(lhs.maxX, rhs.maxX))
    guard horizontalGap <= minimumWidth * 0.25 else { return false }
    let verticalOverlap = max(0, min(lhs.maxY, rhs.maxY) - max(lhs.minY, rhs.minY))
    return verticalOverlap / min(lhs.height, rhs.height) >= requiredVerticalOverlap
  }
}

// MARK: - OCRTextAnchor

struct OCRTextAnchor: Equatable, Hashable, Sendable {
  var range: NSRange
  var box: CGRect
}

// MARK: - OCRTableCell
