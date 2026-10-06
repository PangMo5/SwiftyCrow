// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Recover visual roles before paragraph joining loses the evidence. A command,
/// file name, or navigation item is not a prose fragment just because it is near one.
enum OCRVisualStructure {

  // MARK: Internal

  struct InlineAnnotation {
    var range: NSRange
    var inkBox: CGRect
    var runs: [OverlaySourceStyleRun]
    var isSeparator: Bool
  }

  /// A divider belongs between independent UI labels, not inside a translated
  /// sentence. Preserve each label's original owner and the divider's pixels.
  static func separatingCompoundControls(_ result: OCRResult) -> OCRResult {
    .init(lines: result.lines.flatMap { line -> [OCRResult.Line] in
      let separators = inlineAnnotations(in: line).filter(\.isSeparator).sorted { $0.range.location < $1.range.location }
      guard !separators.isEmpty else { return [line] }
      let text = line.text as NSString
      var scopes = [(NSRange, Bool)]()
      var cursor = 0
      for separator in separators {
        if separator.range.location > cursor { scopes.append((
          NSRange(location: cursor, length: separator.range.location - cursor),
          false
        )) }
        scopes.append((separator.range, true))
        cursor = NSMaxRange(separator.range)
      }
      if cursor < text.length { scopes.append((NSRange(location: cursor, length: text.length - cursor), false)) }
      return scopes.compactMap { scope, retained -> OCRResult.Line? in
        let value = text.substring(with: scope).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }
        let range = text.range(of: value, options: [], range: scope)
        let runs = line.styleRuns.filter { NSIntersectionRange($0.range, range).length > 0 }
        guard let first = runs.first, runs.allSatisfy({ NSIntersectionRange($0.range, range) == $0.range }) else { return nil }
        var fragment = line
        fragment.text = value
        fragment.boundingBoxNormalized = runs.reduce(first.inkBox ?? first.box) { $0.union($1.inkBox ?? $1.box) }
        fragment.styleRuns = runs.map { run in
          var run = run
          run.range.location -= range.location
          return run
        }
        fragment.spacingAnchors = []
        fragment.layoutExclusions = []
        fragment.textFlowRegions = []
        fragment.layoutBounds = nil
        fragment.orientedBox = nil
        fragment.replacementPatches = runs.map { .init(box: $0.box, appearance: $0.appearance) }
        fragment.preservesSource = retained
        fragment.preventsJoining = true
        fragment.adoptFragmentAppearance(from: fragment.styleRuns)
        return fragment
      }
    })
  }

  static func classifying(_ result: OCRResult) -> OCRResult {
    let accessories = leadingAccessories(in: result.lines)
    let controlIcons = stackedControlIcons(in: result.lines).union(isolatedSymbolRows(in: result.lines))
    var lines = result.lines.enumerated().flatMap { index, line in
      var line = line
      if controlIcons.contains(index) {
        line.preservesSource = true
        line.preventsJoining = true
      }
      return splitControls(line, preservesLeadingAccessory: accessories.contains(index))
    }
    let codeRows = lines.indices.filter { hasMonospacedWordGeometry(lines[$0]) }
    let pathRows = lines.indices.filter { isPath(lines[$0].text) }
    let independentRows = repeatedControlRows(in: lines).union(repeatedListLabels(in: lines))
    for index in lines.indices {
      if independentRows.contains(index) { lines[index].preventsJoining = true }
      let line = lines[index]
      let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
      let repeatedCode = codeRows.contains { other in
        other != index && sameColumn(line, lines[other])
          && line.text.split(whereSeparator: \.isWhitespace).first == lines[other].text.split(whereSeparator: \.isWhitespace)
          .first
          && abs(line.boundingBoxNormalized.midY - lines[other].boundingBoxNormalized.midY)
          < max(line.boundingBoxNormalized.height, lines[other].boundingBoxNormalized.height) * 6
      }
      let filePeers = pathRows.filter { sameColumn(line, lines[$0]) }
      let nativeFileColumn = line.tableCell.map { cell in
        cell.row > 0 && filePeers.count(where: {
          lines[$0].tableCell.map { $0.table == cell.table && $0.column == cell.column } == true
        }) >= 3
      } ?? false
      let fileRange = filePeers.reduce(CGRect.null) { $0.union(lines[$1].boundingBoxNormalized) }
      let positions = filePeers.map { lines[$0].boundingBoxNormalized.midY }.sorted()
      let advances = zip(positions, positions.dropFirst()).map { $1 - $0 }.sorted()
      let fileAdvance = advances.isEmpty ? 0 : advances[advances.count / 2]
      let fileColumn = text.split(whereSeparator: \.isWhitespace).count == 1 && text.count < 60
        && !OCRTextSemantics.endsSentence(text)
        && filePeers.count >= 3 && (nativeFileColumn || (line.tableCell == nil && !fileRange.isNull
            && line.boundingBoxNormalized.midY >= fileRange.minY
            && line.boundingBoxNormalized.midY <= fileRange.maxY + fileAdvance))
      let nativeNameCount = text.split(whereSeparator: \.isWhitespace).count(where: { isLanguageName(String($0)) })
      let languageSelector = text.count <= 80 && (nativeNameCount >= 2 || (nativeNameCount == 1 && lines.contains { other in
        let a = line.boundingBoxNormalized
        let b = other.boundingBoxNormalized
        return abs(a.midY - b.midY) <= min(a.height, b.height) * 0.5
          && other.text.split(whereSeparator: \.isWhitespace).count(where: { isLanguageName(String($0)) }) >= 2
      }))
      // A zero read as O must not disappear when the label is translated.
      // Repeated neighboring counters establish the numeric role; retain the
      // actual source pixels and flag the uncertain transcript instead of
      // guessing a corrected number.
      let ambiguousCounter = text.range(of: #"^(?:\S\s+)?[OlI]\s+\p{L}+$"#, options: .regularExpression) != nil
        && result.lines.count(where: { other in
          abs(line.boundingBoxNormalized.minX - other.boundingBoxNormalized.minX) * line.imageAspectRatio < line
            .boundingBoxNormalized.height * 1.5
            && abs(line.boundingBoxNormalized.midY - other.boundingBoxNormalized.midY) < line.boundingBoxNormalized.height * 8
            && other.text.range(of: #"^(?:\S\s+)?\d+\s+\p{L}"#, options: .regularExpression) != nil
        }) >= 2
      let belongsToAccessoryColumn = text.count == 1 && accessories.contains { candidate in
        guard let prefix = result.lines[candidate].styleRuns.first?.box else { return false }
        let box = line.boundingBoxNormalized
        return abs(box.minX - prefix.minX) * line.imageAspectRatio < max(box.height, prefix.height) * 0.5
          && abs(box.midY - prefix.midY) < max(box.height, prefix.height) * 14
      }
      let accessory = belongsToAccessoryColumn || isIsolatedAccessory(line, among: result.lines)
      if
        repeatedCode || isPath(text) || isFileLabel(line, among: lines) || OCRTextSemantics.isIdentifier(text)
        || fileColumn || isLanguageName(text)
        || languageSelector || ambiguousCounter || accessory
        || OCRTableStructure.isSymbolColumnValue(line, among: lines)
      {
        lines[index].preservesSource = true
        lines[index].preventsJoining = true
        lines[index].needsReview = lines[index].needsReview || ambiguousCounter
      }
    }
    return OCRResult(lines: lines)
  }

  static func isPath(_ text: String) -> Bool {
    text.range(of: #"^(?:\.?\.?/|[A-Za-z_][\w.-]*/)[\w./-]+$"#, options: .regularExpression) != nil
      || (!text.contains(where: \.isWhitespace) && OCRTextSemantics.isFileName(text))
  }

  /// Spaces are part of a title only when the observed layout supplies its
  /// file role. An instruction such as "Read manual.pdf" still owns prose.
  static func isFileLabel(_ line: OCRResult.Line, among lines: [OCRResult.Line]) -> Bool {
    guard !line.isVerticalBlock, line.rowCount == 1, OCRTextSemantics.isFileName(line.text) else { return false }
    if !line.text.contains(where: \.isWhitespace) { return true }
    if
      lines.count(where: { other in
        other != line && sameColumn(line, other) && OCRTextSemantics.isFileName(other.text)
      }) >= 2 { return true }
    let box = line.boundingBoxNormalized
    let peers = lines.filter { other in
      let peer = other.boundingBoxNormalized
      return other != line && !other.isVerticalBlock && other.rowCount == 1 && other.text.count <= 24
        && abs(peer.midY - box.midY) <= max(box.height, peer.height) * 0.5
        && min(box.height, peer.height) >= max(box.height, peer.height) * 0.5
    }
    return peers.count >= 2 && !OCRTextSemantics.fileNameStartsWithVerb(line.text)
  }

  static func isLanguageName(_ text: String) -> Bool {
    nativeLanguageNames.contains(text.lowercased())
  }

  /// Repeated slug-shaped labels in colored compact surfaces are identifier
  /// tags. Preserve their spelling, just as paths in a file table are preserved.
  static func preservingIdentifierTags(_ result: OCRResult) -> OCRResult {
    let candidates = result.lines.indices.filter { index in
      let line = result.lines[index]
      guard let surface = line.surface, line.rowCount == 1 else { return false }
      let box = line.boundingBoxNormalized
      return surface.box.height < box.height * 3.5
        && line.text.range(of: #"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil
    }
    guard
      candidates.count >= 6,
      candidates.count(where: { result.lines[$0].text.contains("-") }) >= 2
    else { return result }
    var result = result
    for index in candidates {
      result.lines[index].preservesSource = true
      result.lines[index].preventsJoining = true
    }
    return result
  }

  /// Flood fill must not borrow a neighboring control's background through a
  /// one-pixel bridge introduced by downsampling. Adjacent text is a hard bound.
  static func surfaceSearchBounds(for line: OCRResult.Line, among lines: [OCRResult.Line]) -> CGRect {
    let box = line.boundingBoxNormalized
    var left: CGFloat = 0
    var right: CGFloat = 1
    for other in lines {
      let candidate = other.boundingBoxNormalized
      let overlap = min(box.maxY, candidate.maxY) - max(box.minY, candidate.minY)
      guard overlap > min(box.height, candidate.height) * 0.6 else { continue }
      if candidate.maxX < box.minX { left = max(left, (candidate.maxX + box.minX) / 2) }
      if candidate.minX > box.maxX { right = min(right, (candidate.minX + box.maxX) / 2) }
    }
    return CGRect(x: left, y: 0, width: max(0, right - left), height: 1)
  }

  /// Runs inside one Vision observation can still be separate controls. Use
  /// actual whitespace width, never character count or paragraph ID alone.
  static func separatingStyleAccessories(_ result: OCRResult) -> OCRResult {
    .init(lines: result.lines.flatMap { splitControls($0, preservesLeadingAccessory: false, separatesGaps: false) })
  }

  /// A semantic inline owner follows its translated clause inside the containing
  /// paragraph. Recognition selects the range; measured geometry establishes role.
  static func inlineAnnotations(in line: OCRResult.Line) -> [InlineAnnotation] {
    guard !line.isVerticalBlock, !line.preservesSource, abs(line.rotationRadians) < 0.025 else { return [] }
    let text = line.text as NSString
    let runs = line.styleRuns.filter { $0.range.location >= 0 && NSMaxRange($0.range) <= text.length }
    let letters = runs.filter { text.substring(with: $0.range).contains(where: \.isLetter) }
    guard !letters.isEmpty else { return [] }
    var groups = [[OverlaySourceStyleRun]]()
    for run in runs.sorted(by: { $0.range.location < $1.range.location }) {
      if let previous = groups.last?.first, previous.box == run.box {
        groups[groups.count - 1].append(run)
      } else { groups.append([run]) }
    }
    return groups.compactMap { group -> InlineAnnotation? in
      guard let first = group.first, let last = group.last, let ink = first.inkBox else { return nil }
      let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
      let value = text.substring(with: range)
      guard
        value.count <= 16
      else { return nil }
      let reference = value.contains(where: \.isNumber) && value.contains(where: { "[]［］()（）".contains($0) })
        && value.allSatisfy { $0.isNumber || "[]［］()（）.,".contains($0) }
      let separator = value.count == 1 && "|1Il".contains(value)
        && ink.width * line.imageAspectRatio <= ink.height * 0.18
        && text.length <= 80 && line.text.first.map { "[［【".contains($0) } == true
      guard reference || separator else { return nil }
      let neighbors = letters.filter {
        let body = $0.inkBox ?? $0.box
        return abs(body.midY - ink.midY) <= body.height
          && max(0, max(body.minX - ink.maxX, ink.minX - body.maxX)) * line.imageAspectRatio <= body.height * 5
      }
      if separator {
        guard
          neighbors.contains(where: { ($0.inkBox ?? $0.box).maxX < ink.minX }),
          neighbors.contains(where: { ($0.inkBox ?? $0.box).minX > ink.maxX })
        else { return nil }
        return InlineAnnotation(range: range, inkBox: ink, runs: group, isSeparator: separator)
      }
      guard
        neighbors.contains(where: {
          let body = $0.inkBox ?? $0.box
          let smaller = ink.height <= body.height * 0.85
            || (first.appearance.fontSizeScale > 0 && first.appearance.fontSizeScale <= $0.appearance.fontSizeScale * 0.95)
          return smaller && ink.maxY <= body.maxY - body.height * 0.15
        })
      else { return nil }
      return InlineAnnotation(range: range, inkBox: ink, runs: group, isSeparator: separator)
    }
  }

  // MARK: Private

  /// A full-height, independently measured symbol can be an icon that OCR
  /// approximated as a bullet. Its visual identity must not become a new dot.
  private enum LeadingAccessoryRole {
    case pictogram
    case listMarker
  }

  private static let nativeLanguageNames: Set<String> = {
    let identifiers = Locale.LanguageCode.isoLanguageCodes.map(\.identifier) + ["zh-Hans", "zh-Hant"]
    return Set(identifiers.compactMap { identifier in
      Locale(identifier: identifier).localizedString(forIdentifier: identifier)?.lowercased()
    }).union(["简体中文", "繁體中文", "繁体中文", "正體中文"])
  }()

  /// A native list can contain an indented navigation tree. Several independent
  /// compact paragraphs at one repeated row pitch establish label boundaries,
  /// even if Vision combines two adjacent labels into one paragraph. Ordinary
  /// wrapped prose has one paragraph owner and must remain joinable.
  private static func repeatedListLabels(in lines: [OCRResult.Line]) -> Set<Int> {
    var independent = Set<Int>()
    for index in lines.indices {
      let line = lines[index]
      guard let container = line.recognitionContainer, !line.isVerticalBlock, line.rowCount == 1 else { continue }
      let box = line.boundingBoxNormalized
      let peers = lines.indices.filter { other in
        let candidate = lines[other]
        let bounds = candidate.boundingBoxNormalized
        return candidate.recognitionContainer == container && !candidate.isVerticalBlock && candidate.rowCount == 1
          && candidate.text.split(whereSeparator: \.isWhitespace).count <= 5
          && !candidate.text.contains(where: { ".!?。！？".contains($0) })
          && candidate.text.contains(where: \.isLetter)
          && min(box.height, bounds.height) >= max(box.height, bounds.height) * 0.75
          && bounds.width * line.imageAspectRatio <= bounds.height * 18
          && min(abs(box.minX - bounds.minX), abs(box.maxX - bounds.maxX)) * line.imageAspectRatio <= box.height * 0.45
      }.sorted { lines[$0].boundingBoxNormalized.midY < lines[$1].boundingBoxNormalized.midY }
      guard
        peers.contains(index), peers.count >= 4,
        Set(peers.compactMap { lines[$0].recognitionGroupID }).count >= 3
      else { continue }
      let advances = zip(peers, peers.dropFirst()).map {
        lines[$1].boundingBoxNormalized.midY - lines[$0].boundingBoxNormalized.midY
      }.sorted()
      let pitch = advances[advances.count / 2]
      guard
        pitch >= box.height * 1.2, pitch <= box.height * 2,
        advances.count(where: { abs($0 - pitch) <= pitch * 0.2 }) >= 3
      else { continue }
      independent.formUnion(peers)
    }
    return independent
  }

  /// Repeated controls in one column establish independent rows (tables and
  /// collapsible navigation). Their neighboring labels must not become a
  /// single vertical paragraph merely because Vision shares a paragraph ID.
  private static func repeatedControlRows(in lines: [OCRResult.Line]) -> Set<Int> {
    let controls = lines.indices.filter { index in
      let line = lines[index]
      guard !line.isVerticalBlock, line.rowCount == 1, line.text.count <= 24 else { return false }
      return lines.indices.count(where: { other in
        other != index && lines[other].text == line.text && sameColumn(line, lines[other])
          && abs(line.boundingBoxNormalized.midY - lines[other].boundingBoxNormalized.midY)
          >= max(line.boundingBoxNormalized.height, lines[other].boundingBoxNormalized.height) * 1.3
      }) >= 2
    }
    var result = Set(controls)
    var pairs = [(control: Int, label: Int, gap: CGFloat)]()
    for control in controls {
      let peer = lines[control].boundingBoxNormalized
      let nearest = lines.indices.compactMap { index -> (Int, CGFloat)? in
        guard index != control else { return nil }
        let line = lines[index]
        guard !line.isVerticalBlock, line.rowCount == 1, line.text.count <= 80 else { return nil }
        let box = line.boundingBoxNormalized
        let height = max(box.height, peer.height)
        let gap = max(box.minX, peer.minX) - min(box.maxX, peer.maxX)
        guard
          min(box.height, peer.height) / height >= 0.7,
          abs(box.midY - peer.midY) <= height * 0.4,
          gap >= 0,
          box.width * line.imageAspectRatio <= height * 16
        else { return nil }
        return (index, gap)
      }.min { $0.1 < $1.1 }
      if let nearest { pairs.append((control, nearest.0, nearest.1)) }
    }
    for pair in pairs {
      let label = lines[pair.label]
      let control = lines[pair.control]
      let height = max(label.boundingBoxNormalized.height, control.boundingBoxNormalized.height)
      if pair.gap * label.imageAspectRatio <= height * 6 {
        result.insert(pair.label)
        continue
      }
      // Wide or RTL tables can put their controls at the opposite edge of a
      // cell. Distance alone loses their row boundaries. Require a repeated
      // corresponding label column with independent document paragraphs before
      // allowing the longer association; a wrapped adjacent article is not one.
      let labelBox = label.boundingBoxNormalized
      let paragraphIDs = Set(pairs.compactMap { other -> Int? in
        guard sameColumn(control, lines[other.control]) else { return nil }
        let candidate = lines[other.label]
        let box = candidate.boundingBoxNormalized
        let horizontalAlignment = min(
          abs(labelBox.minX - box.minX),
          abs(labelBox.midX - box.midX),
          abs(labelBox.maxX - box.maxX)
        ) * label.imageAspectRatio
        guard horizontalAlignment < max(labelBox.height, box.height) * 0.7 else { return nil }
        return candidate.recognitionGroupID
      })
      if paragraphIDs.count >= 3 { result.insert(pair.label) }
    }
    return result
  }

  private static func leadingAccessoryRole(_ line: OCRResult.Line) -> LeadingAccessoryRole? {
    guard
      !line.isVerticalBlock, line.rowCount == 1,
      line.text.first.map({ !$0.isLetter && !$0.isNumber && !$0.isWhitespace }) == true
    else { return nil }
    let runs = line.styleRuns.sorted { $0.range.location < $1.range.location }
    let text = line.text as NSString
    guard
      let first = runs.first, first.range.location == 0, first.range.length > 0
    else { return nil }
    let token = String(line.text.prefix(while: { !$0.isWhitespace }))
    let prefixLength = token.utf16.count
    let prefix = runs.filter { NSMaxRange($0.range) <= prefixLength }
    guard let initial = prefix.first?.inkBox, prefix.allSatisfy({ $0.inkBox != nil }) else { return nil }
    let icon = prefix.dropFirst().reduce(initial) { $0.union($1.inkBox!) }
    guard
      (1...3).contains(token.count), prefixLength < text.length,
      token.unicodeScalars.allSatisfy({ !CharacterSet.alphanumerics.contains($0) })
      || (token.count <= 2 && token.contains(where: { !$0.isLetter && !$0.isNumber })),
      text.substring(with: NSRange(location: prefixLength, length: 1)).allSatisfy(\.isWhitespace),
      let body = runs.dropFirst().first(where: {
        $0.range.location > prefixLength && NSMaxRange($0.range) <= text.length
          && text.substring(with: $0.range).contains(where: \.isLetter)
      })?.inkBox
    else { return nil }
    let aspect = max(0.01, line.imageAspectRatio)
    let width = icon.width * aspect
    let gap = max(body.minX - icon.maxX, icon.minX - body.maxX) * aspect
    guard abs(icon.midY - body.midY) <= max(icon.height, body.height) * 0.4, gap >= 0 else { return nil }
    let bullet = ["•", "·", "●", "▪", "◦", "‣", "⁃"].contains(token)
    if
      icon.height >= body.height * (bullet ? 0.8 : 0.3), width >= icon.height * (bullet ? 0.6 : 0.3),
      width <= icon.height * 1.8, gap >= body.height * 0.4 { return .pictogram }
    return bullet ? .listMarker : nil
  }

  private static func splitControls(
    _ line: OCRResult.Line,
    preservesLeadingAccessory: Bool,
    separatesGaps: Bool = true
  ) -> [OCRResult.Line] {
    let accessoryRole = leadingAccessoryRole(line)
    let preservesAccessory = preservesLeadingAccessory || accessoryRole != nil
    let inkBoxes = line.styleRuns.compactMap(\.inkBox)
    let uprightInk = !separatesGaps && inkBoxes.count >= 2
      && abs(line.rotationRadians) < 0.1
      && (inkBoxes.map(\.maxY).max()! - inkBoxes.map(\.maxY).min()!) <= inkBoxes.map(\.height).max()! * 0.25
    guard
      !line.isVerticalBlock, line.rowCount == 1,
      abs(line.rotationRadians) < (preservesAccessory ? 0.12 : 0.025) || uprightInk
    else { return [line] }
    let runs = line.styleRuns.sorted { $0.range.location < $1.range.location }
    guard runs.count >= 2 else { return [line] }
    let source = line.text as NSString
    let trailingIcon = runs.last.flatMap { last -> OverlaySourceStyleRun? in
      guard
        let previous = runs.dropLast().last, let icon = last.inkBox, let label = previous.inkBox,
        last.range.length <= 2, last.appearance.fontSizeScale == 0,
        icon.height < label.height * 0.5, abs(icon.midY - label.midY) < label.height * 0.3,
        max(icon.minX - label.maxX, label.minX - icon.maxX) * line.imageAspectRatio > label.height * 0.3
      else { return nil }
      return last
    }
    let prefixLength = line.text.prefix(while: { !$0.isWhitespace }).utf16.count
    let leadingLiteral: Bool
    if
      let first = runs.first, first.range.location == 0, NSMaxRange(first.range) < source.length,
      line.text.count <= 48, line.text.split(whereSeparator: \.isWhitespace).count <= 5,
      line.text.last.map({ !".!?。！？".contains($0) }) == true
    {
      let token = source.substring(with: first.range)
      let nextToken = line.text.split(whereSeparator: \.isWhitespace).dropFirst().first.map(String.init) ?? ""
      let numericAccessory = !token.allSatisfy(\.isNumber)
        || nextToken.allSatisfy(\.isNumber) || OCRTextSemantics.isIdentifier(nextToken)
      leadingLiteral = token.unicodeScalars.allSatisfy { !CharacterSet.letters.contains($0) }
        && numericAccessory
        && token.count == 1
        && first.box.width * line.imageAspectRatio > first.box.height
        && !["•", "·", "●", "▪", "◦", "-", "*"].contains(token)
        && source.substring(with: NSRange(location: NSMaxRange(first.range), length: 1)).allSatisfy(\.isWhitespace)
    } else { leadingLiteral = false }
    let aspect = max(0.01, line.imageAspectRatio)
    func styleScale(_ run: OverlaySourceStyleRun) -> CGFloat {
      // Different scripts have different cap/diacritic heights at one point
      // size. A short Latin span after Arabic is still the same paragraph.
      run.appearance.fontSizeScale > 0 ? run.appearance.fontSizeScale : (run.inkBox?.height ?? run.box.height)
    }
    var groups = [[OverlaySourceStyleRun]]()
    for run in runs {
      let previous = groups.last?.last
      let smallerStyle = previous.map { previous in
        let immediateHeight = styleScale(previous)
        guard styleScale(run) < immediateHeight * 0.6 else { return false }
        // A tall parenthesis or formula glyph is not the typography of the
        // preceding phrase. Use its letter-weighted median so inline math
        // cannot turn the remaining body text into a separate small control.
        let prefix = runs.filter { $0.range.location <= previous.range.location }
          .compactMap { candidate -> (height: CGFloat, weight: Int)? in
            let letters = source.substring(with: candidate.range).filter(\.isLetter).count
            guard letters > 0 else { return nil }
            return (styleScale(candidate), letters)
          }.sorted { $0.height < $1.height }
        var remaining = prefix.reduce(0) { $0 + $1.weight } / 2
        let typicalHeight = prefix.first { sample in
          remaining -= sample.weight
          return remaining < 0
        }?.height
        let previousHeight = typicalHeight ?? styleScale(previous)
        return styleScale(run) < previousHeight * 0.6
          && runs.filter { $0.range.location >= run.range.location }
          .allSatisfy { styleScale($0) < previousHeight * 0.7 }
          && source.substring(from: run.range.location).unicodeScalars.count(where: CharacterSet.letters.contains) >= 2
      } ?? false
      let hasWordBoundary = previous.map {
        NSMaxRange($0.range) < run.range.location
          && source.substring(with: NSRange(location: NSMaxRange($0.range), length: run.range.location - NSMaxRange($0.range)))
          .allSatisfy(\.isWhitespace)
      } ?? false
      let startsBracketedAccessory = source.substring(from: run.range.location).first.map { "[［〔【(（".contains($0) } == true
      if
        let previous = groups.last?.last,
        (leadingLiteral || preservesAccessory) && NSMaxRange(previous.range) == prefixLength
        || (separatesGaps && (run.box.minX - previous.box.maxX) * aspect > max(run.box.height, previous.box.height) * 0.8)
        || (smallerStyle && (hasWordBoundary || startsBracketedAccessory))
        || trailingIcon?.range == run.range
      {
        groups.append([run])
      } else if groups.isEmpty {
        groups.append([run])
      } else {
        groups[groups.count - 1].append(run)
      }
    }
    guard groups.count >= 2 else { return [line] }
    let original = line.text as NSString
    let fragments = groups.compactMap { group -> OCRResult.Line? in
      guard let first = group.first, let last = group.last else { return nil }
      let range = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
      guard range.location >= 0, NSMaxRange(range) <= original.length else { return nil }
      var fragment = line
      fragment.text = original.substring(with: range)
      fragment.boundingBoxNormalized = group.dropFirst().reduce(first.inkBox ?? first.box) { $0.union($1.inkBox ?? $1.box) }
      fragment.orientedBox = nil
      if uprightInk { fragment.rotationRadians = 0 }
      fragment.styleRuns = group.map { run in
        var run = run
        run.range.location -= range.location
        return run
      }
      fragment.adoptFragmentAppearance(from: fragment.styleRuns)
      fragment.spacingAnchors = line.spacingAnchors.compactMap { anchor in
        guard NSIntersectionRange(anchor.range, range).length == anchor.range.length else { return nil }
        var anchor = anchor
        anchor.range.location -= range.location
        return anchor
      }
      fragment.replacementPatches = group.map { OverlaySourcePatch(
        box: $0.box,
        appearance: $0.appearance,
        clippingBox: line.replacementPatches.compactMap(\.clippingBox).first
      ) }
      // A list marker is independent ink, not a paragraph boundary for the
      // prose after it. Keep wrapped list items in their original reading flow.
      fragment.preventsJoining = accessoryRole == .listMarker && groups.count == 2 && range.location > 0
        ? line.preventsJoining
        : true
      if preservesAccessory, range.location == 0 { fragment.preservesSource = true }
      if let trailingIcon, NSIntersectionRange(range, trailingIcon.range).length > 0 { fragment.preservesSource = true }
      // Accessory position is physical evidence. RTL controls put their icon
      // on the right; splitting it must not turn the caption into a left anchor.
      let rightAccessory = preservesAccessory && range.location > 0
        && (groups.first?.first?.box.midX ?? 0) > fragment.boundingBoxNormalized.midX
      fragment.alignment = rightAccessory ? .trailing : .leading
      return fragment
    }
    // A partial range map is not permission to discard punctuation or words.
    guard fragments.map(\.text).joined().filter({ !$0.isWhitespace }) == line.text.filter({ !$0.isWhitespace })
    else { return [line] }
    return fragments
  }

  /// Repeated icon/label rows provide stronger evidence than the glyph's OCR
  /// spelling. A book icon may be read as M and a scale as S&, but their narrow
  /// accessory column is separate from the aligned labels and numeric counters.
  private static func leadingAccessories(in lines: [OCRResult.Line]) -> Set<Int> {
    let candidates: [(index: Int, prefix: String, box: CGRect)] = lines.enumerated().compactMap { index, line in
      let prefix = String(line.text.prefix(while: { !$0.isWhitespace }))
      guard
        (1 ... 2).contains(prefix.count), !prefix.hasSuffix("."), !prefix.hasSuffix(")"),
        !(prefix.count == 2 && prefix.allSatisfy { $0.isASCII && $0.isLowercase }),
        !["•", "·", "●", "▪", "◦", "-"].contains(prefix),
        line.text.count > prefix.count + 3
      else { return nil }
      let runs = line.styleRuns.filter { NSMaxRange($0.range) <= prefix.utf16.count }
      guard let first = runs.first else { return nil }
      let box = runs.dropFirst().reduce(first.box) { $0.union($1.box) }
      let aspect = box.width * line.imageAspectRatio / max(0.00001, box.height)
      guard
        (0.7 ... 1.6).contains(aspect),
        let label = line.styleRuns.first(where: { $0.range.location > prefix.utf16.count }),
        (label.box.minX - box.maxX) * line.imageAspectRatio >= box.height * 0.45
      else { return nil }
      return (index, prefix, box)
    }
    return Set(candidates.compactMap { candidate in
      let peers = candidates.filter {
        abs($0.box.minX - candidate.box.minX) * lines[candidate.index].imageAspectRatio < candidate.box.height * 0.5
          && abs($0.box.midY - candidate.box.midY) < candidate.box.height * 14
      }
      return peers.count >= 3 && Set(peers.map(\.prefix)).count >= 2 ? candidate.index : nil
    })
  }

  private static func isIsolatedAccessory(_ line: OCRResult.Line, among lines: [OCRResult.Line]) -> Bool {
    let box = line.boundingBoxNormalized
    guard
      line.text.count == 1, !line.isVerticalBlock,
      box.width * line.imageAspectRatio > box.height * 0.55
    else { return false }
    if
      line.text.allSatisfy({ $0.isASCII && $0.isLetter }), !lines.contains(where: { other in
        guard other != line else { return false }
        let next = other.boundingBoxNormalized
        let dx = max(0, max(box.minX - next.maxX, next.minX - box.maxX)) * line.imageAspectRatio
        let dy = max(0, max(box.minY - next.maxY, next.minY - box.maxY))
        return other.text.contains(where: \.isLetter) && dx < box.height * 6 && dy < box.height
      }) { return true }
    return lines.contains { other in
      let next = other.boundingBoxNormalized
      let gap = (next.minX - box.maxX) * line.imageAspectRatio
      return other.text.count >= 3 && line.recognitionGroupID != other.recognitionGroupID
        && abs(box.midY - next.midY) < max(box.height, next.height) * 0.5
        && gap > box.height * 0.25 && gap < box.height * 6
    }
  }

  /// Tab and toolbar symbols are often hallucinated as short words. A row of
  /// small labels with larger, low-confidence glyphs centered above them is
  /// visual control structure, not another line to translate.
  private static func stackedControlIcons(in lines: [OCRResult.Line]) -> Set<Int> {
    let labels = lines.indices.filter {
      let line = lines[$0]
      return !line.isVerticalBlock && line.rowCount == 1 && (3 ... 32).contains(line.text.count)
        && line.text.split(whereSeparator: \.isWhitespace).count <= 3
        && line.text.contains(where: \.isLetter)
    }
    var icons = Set<Int>()
    for labelIndex in labels {
      let label = lines[labelIndex].boundingBoxNormalized
      let row = labels.filter {
        let peer = lines[$0].boundingBoxNormalized
        return min(label.height, peer.height) / max(label.height, peer.height) >= 0.7
          && abs(label.midY - peer.midY) <= min(label.height, peer.height) * 0.5
      }
      guard row.count >= 3 else { continue }
      for index in lines.indices where index != labelIndex {
        let line = lines[index]
        let box = line.boundingBoxNormalized
        let gap = label.minY - box.maxY
        let aspect = box.width * line.imageAspectRatio / max(0.00001, box.height)
        if
          line.text.count <= 3, line.recognitionConfidence < 0.6,
          !line.isVerticalBlock, (0.5 ... 3).contains(aspect),
          box.height >= label.height * 1.35, box.height <= label.height * 4.5,
          abs(box.midX - label.midX) <= max(box.width, label.width) * 0.25,
          gap >= -label.height * 0.3, gap <= label.height * 1.5
        {
          icons.insert(index)
        }
      }
    }
    return icons
  }

  /// OCR can confidently read toolbar artwork as a Latin letter or a CJK
  /// ideograph. Repeated square, single-glyph controls with wide gaps have no
  /// sentence context; keep their pixels rather than translating those guesses.
  private static func isEnclosedMarker(_ text: String) -> Bool {
    guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { return false }
    return scalar.properties.name?.contains("CIRCLED") == true
  }

  private static func isolatedSymbolRows(in lines: [OCRResult.Line]) -> Set<Int> {
    let glyphRows = Set(lines.indices.filter { isCompactGlyphRow(lines[$0]) })
    let candidates = glyphRows.filter {
      let line = lines[$0]
      let box = line.boundingBoxNormalized
      let aspect = box.width * line.imageAspectRatio / max(0.00001, box.height)
      let touchesProse = lines.contains { other in
        guard !isCompactGlyphRow(other) else { return false }
        let peer = other.boundingBoxNormalized
        let gap = max(box.minX, peer.minX) - min(box.maxX, peer.maxX)
        return abs(box.midY - peer.midY) < max(box.height, peer.height) * 0.5
          && gap * line.imageAspectRatio < box.height * 1.2
      }
      return !touchesProse && !line.isVerticalBlock && line.rowCount == 1 && (0.5 ... 5.4).contains(aspect)
    }
    return Set(candidates.filter { index in
      let line = lines[index]
      if isEnclosedMarker(line.text) { return true }
      let box = line.boundingBoxNormalized
      return candidates.contains { other in
        guard other != index else { return false }
        let peer = lines[other].boundingBoxNormalized
        let height = max(box.height, peer.height)
        let gap = max(box.minX, peer.minX) - min(box.maxX, peer.maxX)
        return min(box.height, peer.height) / height >= 0.65
          && abs(box.midY - peer.midY) <= height * 0.3
          && gap * line.imageAspectRatio >= height * 0.75
          && gap * line.imageAspectRatio <= height * 5
      }
    })
  }

  private static func isCompactGlyphRow(_ line: OCRResult.Line) -> Bool {
    guard !line.isVerticalBlock, line.rowCount == 1 else { return false }
    let tokens = line.text.split(whereSeparator: \.isWhitespace)
    return (1...3).contains(tokens.count) && tokens.allSatisfy { token in
      let glyph = String(token).trimmingCharacters(in: .punctuationCharacters)
      return glyph.count == 1 && (!glyph.allSatisfy(\.isNumber) || isEnclosedMarker(glyph))
    }
  }

  private static func hasMonospacedWordGeometry(_ line: OCRResult.Line) -> Bool {
    let source = line.text as NSString
    let runs = line.styleRuns.filter {
      $0.range.length >= 3 && NSMaxRange($0.range) <= source.length
        && source.substring(with: $0.range).allSatisfy { $0.isASCII && $0.isLetter }
    }
    guard
      runs.count >= 3, line.rowCount == 1,
      line.text.first?.isLowercase == true,
      line.text.last.map({ !".?!。？！".contains($0) }) == true
    else { return false }
    let pitches = runs.map { $0.box.width / CGFloat($0.range.length) }
    let mean = pitches.reduce(0, +) / CGFloat(pitches.count)
    return mean > 0 && pitches.allSatisfy { abs($0 - mean) / mean < 0.09 }
  }

  private static func sameColumn(_ lhs: OCRResult.Line, _ rhs: OCRResult.Line) -> Bool {
    abs(lhs.boundingBoxNormalized.minX - rhs.boundingBoxNormalized.minX) * max(0.01, lhs.imageAspectRatio)
      < max(lhs.boundingBoxNormalized.height, rhs.boundingBoxNormalized.height) * 0.7
  }

}
