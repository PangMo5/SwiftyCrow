// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation
import Testing
@testable import SwiftyCrow

@Suite("OCR paragraph coalescing")
struct OCRResultTests {

  // MARK: Internal

  struct SeparationCase: Sendable, CustomTestStringConvertible {
    let name: String
    let lhs: OCRResult.Line
    let rhs: OCRResult.Line

    var testDescription: String {
      name
    }
  }

  struct BodyAppearanceCase: Sendable, CustomTestStringConvertible {
    let name: String
    let firstForeground: CGFloat
    let secondForeground: CGFloat
    let firstForegroundConfidence: CGFloat
    let secondForegroundConfidence: CGFloat
    let firstWeight: OverlayFontWeight

    var testDescription: String {
      name
    }
  }

  @Test
  func joinsObservedSplitBubbleRightToLeft() throws {
    let right = verticalLine(
      x: 0.453125,
      y: 0.38125,
      width: 0.03125,
      height: 0.11458,
      text: "それは本当で"
    )
    let left = verticalLine(
      x: 0.421875,
      y: 0.38125,
      width: 0.028125,
      height: 0.03958,
      text: "すか"
    )

    let result = OCRResult(lines: [right, left]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)
    #expect(result.lines.count == 1)
    #expect(merged.text == "それは本当ですか")
    #expect(merged.boundingBoxNormalized == right.boundingBoxNormalized.union(left.boundingBoxNormalized))
    #expect(merged.isVerticalBlock)
  }

  @Test
  func joinsThreeColumnComponentTransitively() {
    let lines = [
      verticalLine(x: 0.40, y: 0.2, width: 0.03, height: 0.2, text: "右"),
      verticalLine(x: 0.368, y: 0.2, width: 0.03, height: 0.2, text: "中"),
      verticalLine(x: 0.336, y: 0.2, width: 0.03, height: 0.2, text: "左"),
    ]
    let result = OCRResult(lines: lines).coalescingParagraphFragments()
    #expect(result.lines.count == 1)
    #expect(result.lines.first?.text == "右中左")
  }

  @Test
  func joinsWideSpacedVerticalColumnsInsideOneDetectedSurface() throws {
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.30, y: 0.10, width: 0.20, height: 0.30),
      confidence: 0.7
    )
    var right = verticalLine(x: 0.44, y: 0.12, width: 0.02, height: 0.20, text: "昨日の夜")
    right.recognitionGroupID = 3
    right.surface = surface
    var middle = verticalLine(x: 0.408, y: 0.12, width: 0.02, height: 0.20, text: "時計が止まり")
    middle.recognitionGroupID = 3
    middle.surface = surface
    var left = verticalLine(x: 0.376, y: 0.12, width: 0.02, height: 0.07, text: "ました")
    left.recognitionGroupID = 3
    left.surface = surface

    let merged = try #require(
      OCRResult(lines: [right, middle, left]).coalescingParagraphFragments().lines.first
    )

    #expect(merged.text == "昨日の夜時計が止まりました")
  }

  @Test
  func prefersCompactSurfaceContainingMergedText() throws {
    let compact = OverlaySourceSurface(
      box: CGRect(x: 0.38, y: 0.10, width: 0.12, height: 0.30),
      confidence: 0.6,
      clippingBox: CGRect(x: 0.36, y: 0.08, width: 0.16, height: 0.34)
    )
    let oversized = OverlaySourceSurface(
      box: CGRect(x: 0.02, y: 0.02, width: 0.94, height: 0.50),
      confidence: 0.99,
      clippingBox: CGRect(x: 0.01, y: 0.01, width: 0.98, height: 0.54)
    )
    var right = verticalLine(x: 0.44, y: 0.12, width: 0.02, height: 0.20, text: "右")
    right.recognitionGroupID = 7
    right.surface = oversized
    var left = verticalLine(x: 0.408, y: 0.12, width: 0.02, height: 0.20, text: "左")
    left.recognitionGroupID = 7
    left.surface = compact

    let merged = try #require(
      OCRResult(lines: [right, left]).coalescingParagraphFragments().lines.first
    )

    #expect(merged.surface == compact)
  }

  @Test
  func ordersSplitHorizontalFragmentsInVisualReadingOrder() throws {
    let lines = [
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.05, y: 0.80, width: 0.18, height: 0.020),
        text: "first",
        recognitionGroupID: 9
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.15, y: 0.816, width: 0.08, height: 0.017),
        text: "right",
        recognitionGroupID: 9
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.06, y: 0.819, width: 0.09, height: 0.017),
        text: "left",
        recognitionGroupID: 9
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.08, y: 0.833, width: 0.13, height: 0.017),
        text: "last",
        recognitionGroupID: 9
      ),
    ]

    let merged = try #require(OCRResult(lines: lines).coalescingParagraphFragments().lines.first)

    #expect(merged.text == "first left right last")
  }

  @Test
  func joinsAdjacentMixedStyleFragmentsOnOneVisualRow() throws {
    let normalAppearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.08, green: 0.09, blue: 0.10, alpha: 1),
      foreground: OverlayColor(red: 0.92, green: 0.93, blue: 0.95, alpha: 1),
      confidence: 0.7,
      foregroundConfidence: 0.1,
      fontWeight: .regular
    )
    let codeAppearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.20, green: 0.21, blue: 0.23, alpha: 1),
      foreground: OverlayColor(red: 0.95, green: 0.95, blue: 0.96, alpha: 1),
      confidence: 0.8,
      foregroundConfidence: 0.2,
      fontWeight: .regular,
      fontDesign: .monospaced
    )
    let left = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.10, y: 0.30, width: 0.22, height: 0.03),
      text: "Open report",
      rowCount: 1,
      recognitionGroupID: 1,
      appearance: normalAppearance
    )
    let codeText = "build 2.10.0"
    let code = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.325, y: 0.299, width: 0.11, height: 0.032),
      text: codeText,
      rowCount: 1,
      recognitionGroupID: 2,
      appearance: codeAppearance,
      styleRuns: [
        OverlaySourceStyleRun(
          range: NSRange(location: 0, length: (codeText as NSString).length),
          box: CGRect(x: 0.325, y: 0.299, width: 0.11, height: 0.032),
          appearance: codeAppearance
        )
      ],
      surface: OverlaySourceSurface(
        box: CGRect(x: 0.32, y: 0.295, width: 0.12, height: 0.04),
        confidence: 0.8
      )
    )
    let tail = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.432, y: 0.301, width: 0.09, height: 0.029),
      text: ", and keep",
      rowCount: 1,
      recognitionGroupID: 3,
      appearance: normalAppearance
    )

    let result = OCRResult(lines: [left, code, tail]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)

    #expect(result.lines.count == 1)
    #expect(merged.text == "Open report build 2.10.0, and keep")
    #expect(merged.rowCount == 1)
    #expect(merged.wasCoalesced)
    #expect(merged.appearance == normalAppearance)
    let styled = try #require(merged.styleRuns.first)
    #expect((merged.text as NSString).substring(with: styled.range) == codeText)
  }

  @Test
  func keepsPaddedSegmentLabelsSeparate() {
    let selected = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.10, y: 0.30, width: 0.09, height: 0.03),
      text: "Balanced"
    )
    let neighboring = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.22, y: 0.30, width: 0.08, height: 0.03),
      text: "Fast mode"
    )

    let result = OCRResult(lines: [selected, neighboring]).coalescingParagraphFragments()

    #expect(result.lines == [selected, neighboring])
  }

  @Test
  func keepsAdjacentMultilineCardBodiesSeparate() {
    let left = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.10, y: 0.40, width: 0.30, height: 0.15),
      text: "The left card contains several wrapped rows of supporting text.",
      rowCount: 4
    )
    let right = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.42, y: 0.40, width: 0.30, height: 0.15),
      text: "The right card is a separate visual container with its own body.",
      rowCount: 4
    )

    let result = OCRResult(lines: [left, right]).coalescingParagraphFragments()

    #expect(result.lines == [left, right])
  }

  @Test
  func preservesTightReplacementPatchesWhenParagraphsMerge() throws {
    var right = verticalLine(x: 0.40, y: 0.2, width: 0.03, height: 0.2, text: "右")
    right.replacementPatches = [OverlaySourcePatch(box: right.boundingBoxNormalized)]
    var left = verticalLine(x: 0.368, y: 0.2, width: 0.03, height: 0.2, text: "左")
    left.replacementPatches = [OverlaySourcePatch(box: left.boundingBoxNormalized)]

    let merged = try #require(OCRResult(lines: [right, left]).coalescingParagraphFragments().lines.first)

    #expect(merged.replacementPatches.map(\.box) == [right.boundingBoxNormalized, left.boundingBoxNormalized])
  }

  @Test
  func absorbsShortCJKContinuationMisclassifiedAsHorizontal() throws {
    let vertical = verticalLine(
      x: 0.15,
      y: 0.0479,
      width: 0.0344,
      height: 0.2083,
      text: "今日はいい天気です"
    )
    let continuation = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1156, y: 0.0479, width: 0.0281, height: 0.0208),
      text: "ね"
    )

    let result = OCRResult(lines: [vertical, continuation]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)
    #expect(result.lines.count == 1)
    #expect(merged.text == "今日はいい天気ですね")
    #expect(merged.isVerticalBlock)
    #expect(merged.verticalCharScale == vertical.verticalCharScale)
  }

  @Test
  func absorbsOverlappingTerminalGlyphInsideSameVerticalSurface() throws {
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.07, y: 0.04, width: 0.14, height: 0.23),
      confidence: 0.8
    )
    var vertical = verticalLine(
      x: 0.109,
      y: 0.05,
      width: 0.019,
      height: 0.15,
      text: "この町で起きている不思議な出来事を説明してもらいます"
    )
    vertical.surface = surface
    var terminal = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.081, y: 0.094, width: 0.019, height: 0.015),
      text: "か"
    )
    terminal.surface = surface

    let merged = try #require(
      OCRResult(lines: [vertical, terminal]).coalescingParagraphFragments().lines.first
    )

    #expect(merged.text.hasSuffix("か"))
    #expect(merged.isVerticalBlock)
  }

  @Test
  func joinsWrappedHorizontalRowsFromOneTextBlock() throws {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0903, y: 0.4444, width: 0.3288, height: 0.0266),
      text: "今日はいい天気ですね。"
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0906, y: 0.4688, width: 0.3406, height: 0.0479),
      text: "次の週末もここで会いましょう。",
      rowCount: 2
    )

    let result = OCRResult(lines: [first, second]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)
    #expect(result.lines.count == 1)
    #expect(merged.text == "今日はいい天気ですね。 次の週末もここで会いましょう。")
    #expect(merged.rowCount == 3)
    #expect(!merged.isVerticalBlock)
  }

  @Test
  func keepsLargeHeadingAndSmallSubtitleSeparate() {
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.2, y: 0.1, width: 0.6, height: 0.09),
      text: "Lives in your menu bar."
    )
    let subtitle = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.04),
      text: "No Dock icon, no clutter."
    )

    let result = OCRResult(lines: [heading, subtitle]).coalescingParagraphFragments()

    #expect(result.lines == [heading, subtitle])
  }

  @Test
  func joinsObservedWebBodyRowsWithTightCSSLineHeight() throws {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0756, y: 0.7125, width: 0.2253, height: 0.0271),
      text: "Open the popover or fire any action"
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0740, y: 0.7499, width: 0.2298, height: 0.0332),
      text: "from a global shortcut, even with no"
    )
    let third = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0726, y: 0.7891, width: 0.0948, height: 0.0248),
      text: "window open."
    )

    let result = OCRResult(lines: [first, second, third]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)

    #expect(result.lines.count == 1)
    #expect(merged.rowCount == 3)
    #expect(abs(merged.horizontalLineAdvanceScale - 0.0377) < 0.001)
    #expect(merged.text == "Open the popover or fire any action from a global shortcut, even with no window open.")
  }

  @Test
  func visionTranscriptNewlineSeparatesCardHeadingFromWrappedBody() {
    let groups = OCRParagraphLineGrouping.segmentIndices(
      paragraphTranscript: "Smart, or fully manual\nChoose Conservative, Balanced, or Fast and let Amado filter spikes.",
      lineTranscripts: [
        "Smart, or fully manual",
        "Choose Conservative, Balanced, or",
        "Fast and let Amado filter spikes.",
      ]
    )

    #expect(groups == [0, 1, 1])
  }

  @Test
  func infersHardBreakWhenACompletedRowLeavesRoomForTheNextToken() throws {
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 1, green: 0.94, blue: 0.84, alpha: 1),
      foreground: OverlayColor(red: 0.65, green: 0.40, blue: 0.02, alpha: 1),
      confidence: 0.7,
      foregroundConfidence: 0.15,
      fontWeight: .regular
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.626, y: 0.302, width: 0.170, height: 0.024),
      text: "Two checks are pending.",
      horizontalGlyphScale: 0.023,
      recognitionGroupID: 10,
      appearance: appearance,
      alignment: .leading
    )
    let secondText = "The orange surface and its rounded corners"
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.629, y: 0.335, width: 0.271, height: 0.026),
      text: secondText,
      horizontalGlyphScale: 0.023,
      recognitionGroupID: 10,
      appearance: appearance,
      styleRuns: [
        OverlaySourceStyleRun(
          range: NSRange(location: 0, length: 3),
          box: CGRect(x: 0.629, y: 0.335, width: 0.021, height: 0.024)
        )
      ],
      alignment: .leading
    )
    let third = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.626, y: 0.372, width: 0.227, height: 0.026),
      text: "must remain visible after translation.",
      horizontalGlyphScale: 0.023,
      recognitionGroupID: 10,
      appearance: appearance,
      alignment: .leading
    )

    let merged = try #require(
      OCRResult(lines: [first, second, third]).coalescingParagraphFragments().lines.first
    )

    #expect(merged.text == "Two checks are pending.\n\(secondText) must remain visible after translation.")
    #expect(merged.rowCount == 3)
  }

  @Test
  func ordinaryWrappedRowsRemainOneContinuousSentence() throws {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.10, y: 0.30, width: 0.39, height: 0.03),
      text: "The first sentence ends here.",
      recognitionGroupID: 3,
      alignment: .leading
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.10, y: 0.34, width: 0.40, height: 0.03),
      text: "The next sentence uses the remaining row.",
      recognitionGroupID: 3,
      alignment: .leading
    )

    let merged = try #require(OCRResult(lines: [first, second]).coalescingParagraphFragments().lines.first)

    #expect(merged.text == "The first sentence ends here. The next sentence uses the remaining row.")
  }

  @Test
  func visionParagraphMembershipJoinsLooseWrappedRowsWithoutAbsorbingHeading() {
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.03, y: 0.20, width: 0.20, height: 0.05),
      text: "Bypass list",
      recognitionGroupID: 1
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.03, y: 0.30, width: 0.80, height: 0.04),
      text: "Exempt roles, teams, agents, apps, and users from this ruleset by adding them to the",
      recognitionGroupID: 2
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.03, y: 0.38, width: 0.12, height: 0.04),
      text: "bypass list.",
      recognitionGroupID: 2
    )

    let result = OCRResult(lines: [heading, first, second]).coalescingParagraphFragments()

    #expect(result.lines.count == 2)
    #expect(result.lines[0] == heading)
    #expect(result.lines[1]
      .text == "Exempt roles, teams, agents, apps, and users from this ruleset by adding them to the bypass list.")
  }

  @Test
  func distinctVisionParagraphsStaySeparateEvenAtTightCSSSpacing() {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.30, width: 0.92, height: 0.025),
      text: "The first paragraph ends here.",
      recognitionGroupID: 4
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.329, width: 0.92, height: 0.025),
      text: "The next paragraph starts here.",
      recognitionGroupID: 5
    )

    let result = OCRResult(lines: [first, second]).coalescingParagraphFragments()

    #expect(result.lines == [first, second])
  }

  @Test
  func listItemsStaySeparateWhileIndentedContinuationRemainsAttached() throws {
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.04, green: 0.06, blue: 0.08, alpha: 1),
      foreground: OverlayColor(red: 0.91, green: 0.94, blue: 0.98, alpha: 1),
      confidence: 0.8,
      foregroundConfidence: 0.8,
      fontWeight: .regular
    )
    let item = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04215, y: 0.71852, width: 0.92006, height: 0.03252),
      text: "• Per-display workspaces: Pin a workspace to a display.",
      horizontalGlyphScale: 0.03229,
      recognitionGroupID: 8,
      appearance: appearance,
      alignment: .leading
    )
    let continuation = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.06250, y: 0.76771, width: 0.88663, height: 0.07708),
      text: "Each display keeps its own active and recent workspace across relaunches.",
      rowCount: 2,
      horizontalGlyphScale: 0.03490,
      recognitionGroupID: 9,
      appearance: appearance,
      alignment: .leading
    )
    let nextItem = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04167, y: 0.86525, width: 0.86667, height: 0.04255),
      text: "• Cross-display control: Jump focus between displays.",
      horizontalGlyphScale: 0.04167,
      recognitionGroupID: 10,
      appearance: appearance,
      alignment: .leading
    )

    let result = OCRResult(lines: [item, continuation, nextItem])
      .coalescingParagraphFragments()

    #expect(result.lines.count == 2)
    let mergedItem = try #require(result.lines.first)
    #expect(mergedItem
      .text ==
      "• Per-display workspaces: Pin a workspace to a display. Each display keeps its own active and recent workspace across relaunches.")
    #expect(mergedItem.rowCount == 3)
    #expect(result.lines.last == nextItem)
  }

  @Test
  func repeatedCoalescingDoesNotMergeColoredHeadingIntoBody() {
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.03, y: 0.80, width: 0.46, height: 0.18),
      confidence: 0.8
    )
    let headingAppearance = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.26, alpha: 1),
      confidence: 0.8,
      foregroundConfidence: 0.2,
      fontWeight: .bold
    )
    let bodyAppearance = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1),
      confidence: 0.8,
      foregroundConfidence: 0.2,
      fontWeight: .regular
    )
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.20, y: 0.846, width: 0.11, height: 0.027),
      text: "細石器",
      recognitionGroupID: 8,
      appearance: headingAppearance,
      surface: surface
    )
    let bodyFirst = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.875, width: 0.44, height: 0.033),
      text: "岩の小さな破片を木の棒や",
      recognitionGroupID: 9,
      appearance: bodyAppearance,
      surface: surface
    )
    let bodySecond = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.04, y: 0.906, width: 0.44, height: 0.037),
      text: "動物の骨にはめて使った。",
      recognitionGroupID: 10,
      appearance: bodyAppearance,
      surface: surface
    )

    let once = OCRResult(lines: [heading, bodyFirst, bodySecond]).coalescingParagraphFragments()
    let twice = once.coalescingParagraphFragments()

    #expect(once.lines.count == 2)
    #expect(twice.lines.count == 2)
    #expect(twice.lines[0].text == "細石器")
    #expect(twice.lines[1].text.contains("岩の小さな破片"))
    #expect(twice.lines[1].recognitionGroupID != nil)
  }

  @Test
  func absorbsSeparateJapaneseRubyIntoItsBaseRun() throws {
    let rubyBox = CGRect(x: 0.208, y: 0.836, width: 0.096, height: 0.014)
    let baseBox = CGRect(x: 0.202, y: 0.846, width: 0.110, height: 0.027)
    let ruby = OCRResult.Line(
      boundingBoxNormalized: rubyBox,
      text: "さいせっき",
      horizontalGlyphScale: 0.014,
      replacementPatches: [OverlaySourcePatch(box: rubyBox)]
    )
    let base = OCRResult.Line(
      boundingBoxNormalized: baseBox,
      text: "細石器",
      horizontalGlyphScale: 0.027,
      replacementPatches: [OverlaySourcePatch(box: baseBox)]
    )

    let result = OCRResult(lines: [ruby, base]).absorbingRubyAnnotations()
    let line = try #require(result.lines.first)

    #expect(result.lines.count == 1)
    #expect(line.text == "細石器")
    #expect(line.boundingBoxNormalized == rubyBox.union(baseBox))
    #expect(line.replacementPatches.count == 2)
    #expect(line.horizontalGlyphScale == base.horizontalGlyphScale)
  }

  @Test
  func sameVisionParagraphKeepsStronglyDifferentColorsSeparate() {
    let orange = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.86, green: 0.42, blue: 0.26, alpha: 1),
      confidence: 0.8,
      foregroundConfidence: 0.2,
      fontWeight: .bold
    )
    let black = OverlaySourceAppearance(
      background: .white,
      foreground: .black,
      confidence: 0.8,
      foregroundConfidence: 0.2,
      fontWeight: .regular
    )
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.04),
      text: "Heading",
      recognitionGroupID: 3,
      appearance: orange
    )
    let body = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.245, width: 0.3, height: 0.04),
      text: "Body copy",
      recognitionGroupID: 3,
      appearance: black
    )

    #expect(OCRResult(lines: [heading, body]).coalescingParagraphFragments().lines.count == 2)
  }

  @Test
  func joinsMatchingBodyRowsAcrossVisionParagraphsInsideOneSurface() throws {
    let firstAppearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
      foreground: OverlayColor(red: 0.57, green: 0.57, blue: 0.59, alpha: 1),
      confidence: 0.6,
      foregroundConfidence: 0.12,
      fontWeight: .semibold
    )
    var secondAppearance = firstAppearance
    secondAppearance.fontWeight = .regular
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.38, y: 0.47, width: 0.25, height: 0.45),
      confidence: 0.6
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.389, y: 0.786, width: 0.211, height: 0.021),
      text: "Manual for direct control over the",
      horizontalGlyphScale: 0.02,
      recognitionGroupID: 4,
      appearance: firstAppearance,
      alignment: .leading,
      surface: surface
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.388, y: 0.822, width: 0.222, height: 0.031),
      text: "RSSI threshold, confirmation delay,",
      horizontalGlyphScale: 0.031,
      recognitionGroupID: 5,
      appearance: secondAppearance,
      alignment: .leading,
      surface: surface
    )

    let merged = try #require(OCRResult(lines: [first, second]).coalescingParagraphFragments().lines.first)

    #expect(merged.text == "Manual for direct control over the RSSI threshold, confirmation delay,")
  }

  @Test
  func joinsContinuousMultilineCardBodyWithoutDetectedSurface() throws {
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
      foreground: OverlayColor(red: 0.51, green: 0.51, blue: 0.53, alpha: 1),
      confidence: 0.64,
      foregroundConfidence: 0.08,
      fontWeight: .regular
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3865, y: 0.6623, width: 0.2284, height: 0.0676),
      text: "The borrowed block is the real workspace, so changes stay with it.",
      rowCount: 2,
      horizontalGlyphScale: 0.0257,
      recognitionGroupID: 5,
      appearance: appearance,
      alignment: .leading
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3866, y: 0.7350, width: 0.2295, height: 0.0234),
      text: "Directional focus and MFF cross the",
      horizontalGlyphScale: 0.0234,
      recognitionGroupID: 6,
      appearance: {
        var noisy = appearance
        noisy.foregroundConfidence = 0.15
        noisy.fontWeight = .semibold
        return noisy
      }(),
      alignment: .leading
    )
    let third = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3864, y: 0.7667, width: 0.2315, height: 0.0697),
      text: "seam, while host and borrowed tiled windows share one switching order.",
      rowCount: 2,
      horizontalGlyphScale: 0.0270,
      recognitionGroupID: 6,
      appearance: appearance,
      alignment: .leading
    )
    let fourth = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.3864, y: 0.8409, width: 0.2068, height: 0.0684),
      text: "Activate it to switch over fully, or borrow it again to return it.",
      rowCount: 2,
      horizontalGlyphScale: 0.0276,
      recognitionGroupID: 7,
      appearance: appearance,
      alignment: .leading
    )

    let merged = try #require(
      OCRResult(lines: [first, second, third, fourth]).coalescingParagraphFragments().lines.first
    )

    #expect(merged.rowCount == 7)
    #expect(merged.text.contains("Directional focus and MFF cross the seam"))
  }

  @Test(arguments: [
    BodyAppearanceCase(
      name: "foreground sampling jitter",
      firstForeground: 0.50,
      secondForeground: 0.65,
      firstForegroundConfidence: 0.10,
      secondForegroundConfidence: 0.12,
      firstWeight: .regular
    ),
    BodyAppearanceCase(
      name: "weak first-row confidence",
      firstForeground: 0.50,
      secondForeground: 0.53,
      firstForegroundConfidence: 0.03,
      secondForegroundConfidence: 0.12,
      firstWeight: .regular
    ),
    BodyAppearanceCase(
      name: "noisy first-row weight",
      firstForeground: 0.50,
      secondForeground: 0.53,
      firstForegroundConfidence: 0.15,
      secondForegroundConfidence: 0.10,
      firstWeight: .semibold
    ),
  ])
  func joinsSplitCardBodyDespiteLowContrastStyleNoise(_ testCase: BodyAppearanceCase) throws {
    let background = OverlayColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.06, y: 0.44, width: 0.26, height: 0.45),
      confidence: 0.7
    )
    let firstAppearance = OverlaySourceAppearance(
      background: background,
      foreground: OverlayColor(
        red: testCase.firstForeground,
        green: testCase.firstForeground,
        blue: testCase.firstForeground,
        alpha: 1
      ),
      confidence: 0.6,
      foregroundConfidence: testCase.firstForegroundConfidence,
      fontWeight: testCase.firstWeight
    )
    let secondAppearance = OverlaySourceAppearance(
      background: background,
      foreground: OverlayColor(
        red: testCase.secondForeground,
        green: testCase.secondForeground,
        blue: testCase.secondForeground,
        alpha: 1
      ),
      confidence: 0.6,
      foregroundConfidence: testCase.secondForegroundConfidence,
      fontWeight: .regular
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0828, y: 0.6667, width: 0.1512, height: 0.0260),
      text: "Each profile has its own",
      recognitionGroupID: 4,
      appearance: firstAppearance,
      alignment: .leading,
      surface: surface
    )
    let remainder = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0814, y: 0.7016, width: 0.2297, height: 0.1562),
      text: "workspaces, app assignments, and shortcuts. Switch by hotkey or from the menu bar.",
      rowCount: 5,
      recognitionGroupID: 5,
      appearance: secondAppearance,
      alignment: .leading,
      surface: surface
    )

    let result = OCRResult(lines: [first, remainder]).coalescingParagraphFragments()
    let merged = try #require(result.lines.first)

    #expect(result.lines.count == 1)
    #expect(merged.rowCount == 6)
  }

  @Test
  func joinsSingleRowsWhenLowContrastSamplingAloneChangesTheirWeight() {
    let background = OverlayColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    let regular = OverlaySourceAppearance(
      background: background,
      foreground: OverlayColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1),
      confidence: 0.6,
      foregroundConfidence: 0.11,
      fontWeight: .regular
    )
    let noisySemibold = OverlaySourceAppearance(
      background: background,
      foreground: OverlayColor(red: 0.50, green: 0.50, blue: 0.52, alpha: 1),
      confidence: 0.6,
      foregroundConfidence: 0.17,
      fontWeight: .semibold
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.7006, y: 0.6198, width: 0.2137, height: 0.0260),
      text: "Copy apps and settings from one",
      recognitionGroupID: 9,
      appearance: regular,
      alignment: .leading
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.7006, y: 0.6550, width: 0.2122, height: 0.0210),
      text: "profile or workspace into another",
      recognitionGroupID: 9,
      appearance: noisySemibold,
      alignment: .leading
    )

    let result = OCRResult(lines: [first, second]).coalescingParagraphFragments()

    #expect(result.lines.count == 1)
    #expect(result.lines.first?.text == "Copy apps and settings from one profile or workspace into another")
  }

  @Test
  func joinsIndentedContinuationAcrossVisionParagraphsInsideOneSurface() throws {
    let appearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.97, green: 0.97, blue: 0.97, alpha: 1),
      foreground: OverlayColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1),
      confidence: 0.7,
      foregroundConfidence: 0.2,
      fontWeight: .regular
    )
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.04, y: 0.79, width: 0.20, height: 0.08),
      confidence: 0.7
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.06, y: 0.819, width: 0.09, height: 0.017),
      text: "鍵は私が",
      horizontalGlyphScale: 0.017,
      recognitionGroupID: 8,
      appearance: appearance,
      surface: surface
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.078, y: 0.833, width: 0.13, height: 0.017),
      text: "持っています。",
      horizontalGlyphScale: 0.017,
      recognitionGroupID: 9,
      appearance: appearance,
      surface: surface
    )

    let merged = try #require(OCRResult(lines: [first, second]).coalescingParagraphFragments().lines.first)

    #expect(merged.text == "鍵は私が 持っています。")
  }

  @Test
  func differentTypographyDoesNotMergeInsideTheSameSurface() {
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.38, y: 0.47, width: 0.25, height: 0.45),
      confidence: 0.6
    )
    var titleAppearance = OverlaySourceAppearance(
      background: OverlayColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1),
      foreground: .white,
      confidence: 0.6,
      foregroundConfidence: 0.8,
      fontWeight: .semibold
    )
    titleAppearance.inkHeightScale = 0.04
    let bodyAppearance = OverlaySourceAppearance(
      background: titleAppearance.background,
      foreground: OverlayColor(red: 0.57, green: 0.57, blue: 0.59, alpha: 1),
      confidence: 0.6,
      foregroundConfidence: 0.12,
      fontWeight: .regular
    )
    let title = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.388, y: 0.613, width: 0.2, height: 0.044),
      text: "Smart, or fully manual",
      horizontalGlyphScale: 0.044,
      recognitionGroupID: 1,
      appearance: titleAppearance,
      alignment: .leading,
      surface: surface
    )
    let body = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.388, y: 0.675, width: 0.225, height: 0.031),
      text: "Choose Conservative, Balanced, or",
      horizontalGlyphScale: 0.031,
      recognitionGroupID: 2,
      appearance: bodyAppearance,
      alignment: .leading,
      surface: surface
    )

    #expect(OCRResult(lines: [title, body]).coalescingParagraphFragments().lines.count == 2)
  }

  @Test
  func semiboldHeadingDoesNotMergeIntoLowContrastBodyFromTheSameVisionParagraph() {
    let surface = OverlaySourceSurface(
      box: CGRect(x: 0.03, y: 0.60, width: 0.46, height: 0.22),
      confidence: 0.8
    )
    let headingAppearance = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
      confidence: 0.7,
      foregroundConfidence: 0.91,
      fontWeight: .semibold
    )
    let bodyAppearance = OverlaySourceAppearance(
      background: .white,
      foreground: OverlayColor(red: 0.38, green: 0.38, blue: 0.42, alpha: 1),
      confidence: 0.7,
      foregroundConfidence: 0.08,
      fontWeight: .regular
    )
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0625, y: 0.6395, width: 0.1192, height: 0.0303),
      text: "Release notes",
      horizontalGlyphScale: 0.0303,
      recognitionGroupID: 12,
      appearance: headingAppearance,
      alignment: .leading,
      surface: surface
    )
    let body = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0610, y: 0.6977, width: 0.4041, height: 0.0305),
      text: "Improved paragraph grouping, source restoration, and language-aware wrapping.",
      horizontalGlyphScale: 0.0302,
      recognitionGroupID: 13,
      appearance: bodyAppearance,
      alignment: .leading,
      surface: surface
    )

    let result = OCRResult(lines: [heading, body]).coalescingParagraphFragments()

    #expect(result.lines == [heading, body])
  }

  @Test
  func lineGeometryOverridesIncorrectCenteredParagraphAlignment() throws {
    let rows = [
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.695, y: 0.675, width: 0.202, height: 0.024),
        text: "Pause from the menu bar for 15",
        recognitionGroupID: 9,
        alignment: .center
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.695, y: 0.709, width: 0.229, height: 0.035),
        text: "minutes to four hours, or choose an",
        recognitionGroupID: 9,
        alignment: .center
      ),
      OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.696, y: 0.748, width: 0.194, height: 0.029),
        text: "exact resume time in Settings.",
        recognitionGroupID: 9,
        alignment: .center
      ),
    ]

    let merged = try #require(OCRResult(lines: rows).coalescingParagraphFragments().lines.first)

    #expect(merged.alignment == .leading)
  }

  @Test
  func centeredVisionParagraphStillJoinsShortLeadingAlignedFinalRow() {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5307, y: 0.55, width: 0.4334, height: 0.0738),
      text: "手でにぎったり、木のぼうの先 にくくりつけたりして、木材を",
      rowCount: 2,
      recognitionGroupID: 6,
      alignment: .center
    )
    let final = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.5305, y: 0.6139, width: 0.3319, height: 0.0352),
      text: "加工するのに使われた。",
      recognitionGroupID: 6,
      alignment: .center
    )

    let result = OCRResult(lines: [first, final]).coalescingParagraphFragments()

    #expect(result.lines.count == 1)
    #expect(result.lines[0].rowCount == 3)
  }

  @Test
  func overlappingVisionParagraphsInsideOneBubbleStillCoalesce() {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0903, y: 0.44436, width: 0.3288, height: 0.0266),
      text: "今日はいい天気ですね。",
      recognitionGroupID: 1
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.0906, y: 0.46875, width: 0.3406, height: 0.0479),
      text: "次の週末もここで会いましょう。",
      rowCount: 2,
      recognitionGroupID: 2
    )

    let result = OCRResult(lines: [first, second]).coalescingParagraphFragments()

    #expect(result.lines.count == 1)
    #expect(result.lines[0].rowCount == 3)
  }

  @Test
  func removesNestedWordObservationAlreadyCoveredByControlRow() {
    let row = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.20, y: 0.70, width: 0.50, height: 0.06),
      text: "| Teams | Apps | Users | Others"
    )
    let nested = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.36, y: 0.71, width: 0.06, height: 0.04),
      text: "Apps"
    )
    let separate = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.05, y: 0.70, width: 0.05, height: 0.04),
      text: "All"
    )

    let result = OCRResult(lines: [row, nested, separate]).removingNestedDuplicates()

    #expect(result.lines == [row, separate])
  }

  @Test
  func supplementalRecognitionAddsOnlyRowsMissingFromDocumentRecognition() {
    let title = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.14, y: 0.13, width: 0.74, height: 0.07),
      text: "Switch your whole setup at once."
    )
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.70, y: 0.62, width: 0.21, height: 0.026),
      text: "Copy apps and settings from one",
      recognitionGroupID: 7
    )
    let final = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.70, y: 0.68, width: 0.22, height: 0.028),
      text: "with a reviewable diff. Keep or skip",
      recognitionGroupID: 8
    )
    var duplicatedFirst = first
    duplicatedFirst.boundingBoxNormalized = CGRect(x: 0.701, y: 0.621, width: 0.209, height: 0.025)
    duplicatedFirst.recognitionGroupID = nil
    let missing = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.70, y: 0.655, width: 0.21, height: 0.021),
      text: "profile or workspace into another"
    )

    let merged = OCRSupplementalMerger.addingUncovered(
      [title, duplicatedFirst, missing],
      to: [first, final]
    )

    #expect(merged.map(\.text) == [
      "Switch your whole setup at once.",
      "Copy apps and settings from one",
      "profile or workspace into another",
      "with a reviewable diff. Keep or skip",
    ])
  }

  @Test
  func keepsIdenticalLabelsWhenTheirBoxesDoNotOverlap() {
    let first = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05),
      text: "Bypass list"
    )
    let second = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.4, width: 0.2, height: 0.05),
      text: "Bypass list"
    )

    #expect(OCRResult(lines: [first, second]).removingNestedDuplicates().lines == [first, second])
  }

  @Test(arguments: [
    SeparationCase(
      name: "horizontal gap is too large",
      lhs: verticalLine(x: 0.2, y: 0.2, width: 0.03, height: 0.2, text: "甲"),
      rhs: verticalLine(x: 0.24, y: 0.2, width: 0.03, height: 0.2, text: "乙")
    ),
    SeparationCase(
      name: "vertical overlap is too small",
      lhs: verticalLine(x: 0.2, y: 0.1, width: 0.03, height: 0.1, text: "甲"),
      rhs: verticalLine(x: 0.168, y: 0.18, width: 0.03, height: 0.1, text: "乙")
    ),
    SeparationCase(
      name: "same column is not a neighboring column",
      lhs: verticalLine(x: 0.2, y: 0.1, width: 0.03, height: 0.2, text: "甲"),
      rhs: verticalLine(x: 0.202, y: 0.1, width: 0.03, height: 0.2, text: "乙")
    ),
    SeparationCase(
      name: "different character scales stay separate",
      lhs: verticalLine(x: 0.2, y: 0.1, width: 0.03, height: 0.2, text: "甲", scale: 0.03),
      rhs: verticalLine(x: 0.168, y: 0.1, width: 0.03, height: 0.2, text: "乙", scale: 0.012)
    ),
    SeparationCase(
      name: "horizontal paragraph stays separate",
      lhs: verticalLine(x: 0.2, y: 0.1, width: 0.03, height: 0.2, text: "甲"),
      rhs: OCRResult.Line(
        boundingBoxNormalized: CGRect(x: 0.168, y: 0.1, width: 0.03, height: 0.2),
        text: "caption"
      )
    ),
  ])
  func keepsUnrelatedParagraphsSeparate(_ testCase: SeparationCase) {
    let result = OCRResult(lines: [testCase.lhs, testCase.rhs]).coalescingParagraphFragments()
    #expect(result.lines.count == 2)
  }

  @Test
  func preservesComponentPositionInVisionOrder() {
    let heading = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.05, width: 0.5, height: 0.05),
      text: "heading"
    )
    let right = verticalLine(x: 0.5, y: 0.2, width: 0.03, height: 0.2, text: "本当で")
    let left = verticalLine(x: 0.468, y: 0.2, width: 0.03, height: 0.2, text: "すか")
    let footer = OCRResult.Line(
      boundingBoxNormalized: CGRect(x: 0.1, y: 0.8, width: 0.5, height: 0.05),
      text: "footer"
    )

    let result = OCRResult(lines: [heading, right, left, footer]).coalescingParagraphFragments()
    #expect(result.lines.map(\.text) == ["heading", "本当ですか", "footer"])
  }

  // MARK: Private

  private static func verticalLine(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    text: String,
    scale: CGFloat = 0.03
  ) -> OCRResult.Line {
    OCRResult.Line(
      boundingBoxNormalized: CGRect(x: x, y: y, width: width, height: height),
      text: text,
      isVerticalBlock: true,
      verticalCharScale: scale
    )
  }

  private func verticalLine(
    x: CGFloat,
    y: CGFloat,
    width: CGFloat,
    height: CGFloat,
    text: String,
    scale: CGFloat = 0.03
  ) -> OCRResult.Line {
    Self.verticalLine(x: x, y: y, width: width, height: height, text: text, scale: scale)
  }
}
