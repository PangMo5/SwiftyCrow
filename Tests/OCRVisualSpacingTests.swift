// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct OCRVisualSpacingTests {
  @Test
  func aPartialBodyMeasurementCannotPromoteAShortEmphasisRun() throws {
    let parent = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.2,
      fontWeight: .regular
    )
    var emphasis = parent
    emphasis.fontSizeScale = 0.4
    emphasis.fontWeight = .bold
    func box(_ x: CGFloat, _ width: CGFloat) -> CGRect {
      CGRect(x: x / 200, y: 10.0 / 60, width: width / 200, height: 12.0 / 60)
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: box(10, 133),
      text: "左 右侧文字 X",
      imageAspectRatio: 200.0 / 60,
      appearance: parent,
      styleRuns: [
        .init(range: NSRange(location: 0, length: 6), box: box(10, 110), appearance: parent),
        .init(range: NSRange(location: 7, length: 1), box: box(136, 7), appearance: emphasis),
      ],
      spacingAnchors: [
        .init(range: NSRange(location: 0, length: 1), box: box(10, 10)),
        .init(range: NSRange(location: 2, length: 4), box: box(80, 40)),
        .init(range: NSRange(location: 7, length: 1), box: box(136, 7)),
      ]
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 200, height: 60) { x, y in
      (10..<22).contains(y) && ((10..<20).contains(x) || (80..<120).contains(x) || (136..<143).contains(x)) ? .black : .white
    }
    #expect(result.lines.map(\.text) == ["左", "右侧文字 X"])
    let fragment = try #require(result.lines.last)
    #expect(fragment.appearance == parent)
    #expect(fragment.styleRuns.last?.appearance == emphasis)
  }

  @Test
  func refiningAnUnsplitRowKeepsItsComposedBaseStyle() {
    let text = "Important ordinary words here"
    let chars = Array(text.utf16)
    let parent = OverlaySourceAppearance(
      background: .black,
      foreground: .white,
      confidence: 1,
      fontSizeScale: 0.3,
      fontWeight: .regular
    )
    var emphasis = parent
    emphasis.fontWeight = .bold
    let lines = (0..<3).map { column in
      let origin = column * 400 + 10
      var offset = 0
      let runs = text.split(separator: " ").enumerated().map { index, word -> OverlaySourceStyleRun in
        defer { offset += word.utf16.count + 1 }
        return .init(
          range: NSRange(location: offset, length: word.utf16.count),
          box: CGRect(
            x: CGFloat(origin + offset * 12) / 1200,
            y: 0.25,
            width: CGFloat(word.utf16.count * 12) / 1200,
            height: 0.4
          ),
          appearance: index == 0 ? emphasis : parent
        )
      }
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(
          x: CGFloat(origin) / 1200,
          y: 0.25,
          width: CGFloat(chars.count * 12) / 1200,
          height: 0.4
        ),
        text: text,
        imageAspectRatio: 30,
        appearance: parent,
        styleRuns: runs
      )
    }
    let result = OCRVisualSpacing.refining(.init(lines: lines), width: 1200, height: 40) { x, y in
      let local = x % 400 - 10
      let index = local / 12
      return local >= 0 && chars.indices.contains(index) && chars[index] != 32
        && local % 12 < 7 && (10..<26).contains(y) ? .white : .black
    }
    #expect(result.lines.count == 3)
    #expect(result.lines.allSatisfy { $0.text == text && $0.appearance == parent })
    #expect(result.lines.allSatisfy { $0.styleRuns.first?.appearance.fontWeight == .bold })
  }

  @Test
  func separatedLabelsDoNotInheritTheirLargerMarkersTypography() throws {
    let parent = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      fontSizeScale: 0.3,
      fontWeight: .bold
    )
    let label = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 1,
      inkHeightScale: 0.12,
      fontSizeScale: 0.14,
      fontWeight: .regular
    )
    let lines = (0..<3).map { index in
      let y = CGFloat(index * 30 + 5) / 100
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.04, y: y, width: 0.65, height: 0.22),
        text: "O Option",
        imageAspectRatio: 2,
        appearance: parent,
        styleRuns: [
          .init(
            range: NSRange(location: 0, length: 1),
            box: CGRect(x: 0.05, y: y, width: 0.12, height: 0.22),
            appearance: parent
          ),
          .init(range: NSRange(location: 2, length: 6), box: CGRect(x: 0.23, y: y, width: 0.4, height: 0.22), appearance: label),
        ]
      )
    }
    let result = OCRVisualSpacing.refining(.init(lines: lines), width: 200, height: 100) { x, y in
      let row = y % 30
      let outline = (12...27).contains(x) && (7...22).contains(row)
        && (x <= 13 || x >= 26 || row <= 8 || row >= 21)
      let text = (46...115).contains(x) && (10...21).contains(row)
      return outline || text ? .black : .white
    }
    let labels = result.lines.filter { $0.text == "Option" }
    try #require(labels.count == 3)
    for fragment in labels {
      #expect(fragment.appearance == label)
      #expect(fragment.horizontalInkScale == label.inkHeightScale)
      #expect(fragment.replacementPatches.allSatisfy { $0.appearance == label })
    }
  }

  @Test
  func repeatedOutlinedControlsAreNotTranslatedAsLetters() {
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let lines = (0..<3).map { index in
      let y = CGFloat(index * 30 + 5) / 100
      return OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.04, y: y, width: 0.65, height: 0.22),
        text: "O Option",
        imageAspectRatio: 2,
        appearance: appearance,
        styleRuns: [
          .init(
            range: NSRange(location: 0, length: 1),
            box: CGRect(x: 0.05, y: y, width: 0.12, height: 0.22),
            appearance: appearance
          ),
          .init(
            range: NSRange(location: 2, length: 6),
            box: CGRect(x: 0.23, y: y, width: 0.4, height: 0.22),
            appearance: appearance
          ),
        ]
      )
    }
    let result = OCRVisualSpacing.refining(.init(lines: lines), width: 200, height: 100) { x, y in
      let row = y % 30
      let outline = (12...27).contains(x) && (7...22).contains(row)
        && (x <= 13 || x >= 26 || row <= 8 || row >= 21)
      let label = (46...115).contains(x) && (10...21).contains(row)
      return outline || label ? .black : .white
    }
    #expect(result.lines.count(where: { $0.text == "O" }) == 3)
    #expect(result.lines.filter { $0.text == "O" }.allSatisfy { $0.preservesSource })
  }

  @Test(arguments: ["三 人工知能", "i Heading", "三 Überschrift"])
  func aSmallLeadingIconKeepsItsPixelsRegardlessOfTheRecognizedScript(_ text: String) throws {
    let appearance = OverlaySourceAppearance(background: .white, foreground: .black, confidence: 1)
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.1, width: 0.75, height: 0.6),
      text: text,
      appearance: appearance,
      styleRuns: [
        .init(
          range: NSRange(location: 0, length: 1),
          box: CGRect(x: 0.05, y: 0.1, width: 0.15, height: 0.6),
          appearance: appearance
        ),
        .init(
          range: NSRange(location: 2, length: text.utf16.count - 2),
          box: CGRect(x: 0.25, y: 0.1, width: 0.5, height: 0.6),
          appearance: appearance
        ),
      ]
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 200, height: 60) { x, y in
      ((15..<29).contains(x) && (18..<32).contains(y)) || ((50..<150).contains(x) && (10..<40).contains(y)) ? .black : .white
    }
    try #require(result.lines.count == 2)
    #expect(result.lines[0].preservesSource)
    #expect(result.lines[1].text == String(text.dropFirst(2)))
  }

  @Test(arguments: ["Manual semantic review", "Manuelle semantische Prüfung", "Révision sémantique manuelle"])
  func normalMonospacedWordSpacesAreNotControlBoundaries(_ text: String) {
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let width = text.utf16.count * 12 + 20
    var offset = 0
    let runs = text.split(separator: " ").map { word -> OverlaySourceStyleRun in
      defer { offset += word.utf16.count + 1 }
      return .init(range: NSRange(location: offset, length: word.utf16.count), box: CGRect(
        x: Double(10 + offset * 12) / Double(width),
        y: 0.25,
        width: Double(word.utf16.count * 12) / Double(width),
        height: 0.4
      ), appearance: appearance)
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0.25, width: 1, height: 0.4),
      text: text,
      imageAspectRatio: Double(width) / 40,
      appearance: appearance,
      styleRuns: runs
    )
    let chars = Array(text.utf16)
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: width, height: 40) { x, y in
      let index = (x - 10) / 12
      return x >= 10 && chars.indices.contains(index) && chars[index] != 32
        && (x - 10) % 12 < 7 && (10..<26).contains(y) ? .white : .black
    }
    #expect(result.lines.count == 1)
    #expect(result.lines[0].text == text)
    #expect(!result.lines[0].preventsJoining)
  }

  @Test(arguments: ["製品支援設定", "产品帮助设置", "제품지원설정"])
  func unspacedNavigationUsesGraphemeGeometry(_ text: String) {
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let chars = Array(text)
    let anchors = chars.indices.map { i in OCRTextAnchor(
      range: NSRange(location: i, length: 1),
      box: CGRect(x: CGFloat(10 + i * 12 + (i / 2) * 24) / 150, y: 0.25, width: 10.0 / 150, height: 0.35)
    ) }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0.25, width: 1, height: 0.35),
      text: text,
      imageAspectRatio: 3.75,
      appearance: appearance,
      spacingAnchors: anchors
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 150, height: 40) { x, y in
      anchors.contains { $0.box.contains(CGPoint(x: CGFloat(x) / 150, y: CGFloat(y) / 40)) } ? .white : .black
    }
    #expect(result.lines.map(\.text) == stride(from: 0, to: chars.count, by: 2).map { String(chars[$0..<$0 + 2]) })
  }

  @Test
  func rightToLeftControlOrderFollowsSourceRanges() {
    let words = ["المساعدة", "والدعم", "الإعدادات"]
    let text = words.joined(separator: " ")
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let boxes = [
      CGRect(x: 0.7, y: 0.25, width: 0.2, height: 0.35),
      CGRect(x: 0.49, y: 0.25, width: 0.2, height: 0.35),
      CGRect(x: 0.1, y: 0.25, width: 0.2, height: 0.35),
    ]
    var offset = 0
    let runs = words.enumerated().map { i, word in
      defer { offset += word.utf16.count + 1 }
      return OverlaySourceStyleRun(
        range: NSRange(location: offset, length: word.utf16.count),
        box: boxes[i],
        appearance: appearance
      )
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.35),
      text: text,
      imageAspectRatio: 7.5,
      appearance: appearance,
      styleRuns: runs
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 300, height: 40) { x, y in
      boxes.contains { $0.contains(CGPoint(x: CGFloat(x) / 300, y: CGFloat(y) / 40)) } ? .white : .black
    }
    #expect(result.lines.map(\.text) == ["المساعدة والدعم", "الإعدادات"])
    #expect(result.lines[0].boundingBoxNormalized.minX > result.lines[1].boundingBoxNormalized.maxX)
  }

  @Test
  func visibleNavigationGapSplitsEvenWhenVisionWordBoxesAlmostTouch() {
    let tokens = ["Release", "notes", "›", "View", "on", "GitHub", "›"]
    let widths = [50, 32, 6, 26, 12, 42, 6]
    let text = tokens.joined(separator: " ")
    var x = 10
    var offset = 0
    var ink = [CGRect]()
    var runs = [OverlaySourceStyleRun]()
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    for i in tokens.indices {
      let rect = CGRect(x: x, y: 10, width: widths[i], height: 14)
      ink.append(rect)
      // The chevron's observed box includes the following navigation padding.
      let reportedWidth = widths[i] + (i == 2 ? 26 : 0)
      runs.append(.init(
        range: NSRange(location: offset, length: tokens[i].utf16.count),
        box: CGRect(x: CGFloat(x) / 250, y: 0.25, width: CGFloat(reportedWidth) / 250, height: 0.35),
        appearance: appearance
      ))
      x += widths[i] + (i == 2 ? 28 : 3)
      offset += tokens[i].utf16.count + 1
    }
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.25, width: CGFloat(x - 13) / 250, height: 0.35),
      text: text,
      imageAspectRatio: 6.25,
      appearance: appearance,
      styleRuns: runs
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 250, height: 40) { x, y in
      ink.contains(where: { $0.contains(CGPoint(x: x, y: y)) }) ? .white : .black
    }
    #expect(result.lines.map(\.text) == ["Release notes ›", "View on GitHub ›"])
    #expect(result.lines.allSatisfy { $0.preventsJoining })
    #expect(result.coalescingParagraphFragments().lines.count == 2)
    #expect(result.lines[0].boundingBoxNormalized.maxX < result.lines[1].boundingBoxNormalized.minX)
  }

  @Test
  func separateFooterControlsKeepObservedWhitespaceAndOrder() {
    let texts = ["Configuration", "License", "Third-party notices"]
    let appearance = OverlaySourceAppearance(background: .black, foreground: .white, confidence: 1)
    let lines = texts.enumerated().map { i, text in
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: CGFloat(i) / 3, y: 0.25, width: 1.0 / 3, height: 0.35),
        text: text,
        imageAspectRatio: 7.5,
        recognitionGroupID: i,
        appearance: appearance
      )
    }
    let result = OCRVisualSpacing.refining(.init(lines: lines), width: 300, height: 40) { x, y in
      (10..<70).contains(x % 100) && (10..<24).contains(y) ? .white : .black
    }
    #expect(result.lines.map(\.text) == texts)
    #expect(result.coalescingParagraphFragments().lines.count == 3)
    #expect(result.lines[0].boundingBoxNormalized.width < 0.25)
  }

  @Test
  func sentenceSpacingDoesNotSplitProse() {
    let line = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1),
      text: "Read the documentation before continuing."
    )
    let result = OCRVisualSpacing.refining(.init(lines: [line]), width: 300, height: 40) { x, _ in x % 60 < 20 ? .white : .black }
    #expect(result.lines == [line])
  }
}
