// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

@Suite("Contextual label ownership")
struct TranslationGroupContextTests {
  @Test
  func tableContextsUseOnlyTheirOwnCaptionAndCompleteGrid() {
    func source(_ text: String, x: CGFloat, y: CGFloat, row: Int?, column: Int, context: Int) -> OverlayLine.Source {
      let box = CGRect(x: x, y: y, width: row == nil ? 0.12 : 0.15, height: 0.03)
      let cell = row.map { OCRTableCell(
        table: 0,
        row: $0,
        column: column,
        box: CGRect(x: x - 0.1, y: y, width: 0.25, height: 0.03)
      ) }
      var line = OCRResult.Line(
        boundingBoxNormalized: box,
        text: text,
        appearance: .init(
          background: .white,
          foreground: .black,
          confidence: 1,
          fontWeight: row == 0 ? .bold : .regular
        ),
        tableCell: cell
      )
      line.recognitionContextID = context
      return .init(recognized: line, language: .init(identifier: "en"))
    }
    var sources = [source("Integer Types", x: 0.05, y: 0.1, row: nil, column: 0, context: 0)]
    for row in 0...2 { for column in 0...1 {
      sources.append(source(
        row == 0 ? ["Signed", "Unsigned"][column] : "Value",
        x: 0.2 + Double(column) * 0.2,
        y: 0.16 + Double(row) * 0.05,
        row: row,
        column: column,
        context: 0
      ))
    } }
    let contexts = TranslationGroupContext.tableHeaders(in: sources)
    #expect(contexts.count == 2)
    #expect(contexts[1]?.context.topic == "Integer Types")
    #expect(contexts[1]?.context.labels == ["Signed", "Unsigned"])
    #expect(contexts[2]?.index == 1)
    let dataCell = source("v1.0", x: 0.6, y: 0.16, row: 0, column: 2, context: 0)
    #expect(TranslationGroupContext.tableHeaders(in: sources + [dataCell]).isEmpty)
    sources[0].recognitionContextID = 1
    #expect(TranslationGroupContext.tableHeaders(in: sources).isEmpty)
    sources[0].recognitionContextID = 0
    sources.removeLast(2)
    #expect(TranslationGroupContext.tableHeaders(in: sources).isEmpty)
  }

  @Test
  func liveReuseRequiresTheSameSemanticGroup() {
    let id = UUID()
    let size = CGSize(width: 800, height: 600)
    let source = OverlayLine.Source(
      recognized: .init(boundingBoxNormalized: .init(x: 0.2, y: 0.2, width: 0.1, height: 0.03), text: "Signed"),
      language: .init(identifier: "en")
    )
    let line = OverlayLine(id: id, source: source)
    let member = TranslationGroupContext.Member(context: .init(topic: "Integer Types", labels: ["Signed", "Unsigned"]), index: 0)
    let context = CaptureFeature.TranslationRequestContext(
      strategy: .lowLatency,
      target: "ko",
      imageSize: size,
      sources: [id: source],
      groupContexts: [id: member]
    )
    #expect(context.matches([source], previous: [line], imageSize: size, groupContexts: [0: member]))
    var changed = member
    changed.context.topic = "Document status"
    #expect(!context.matches([source], previous: [line], imageSize: size, groupContexts: [0: changed]))
    #expect(!context.matches([source], previous: [line], imageSize: size, groupContexts: [:]))
  }

  @Test
  func duplicateSourceLabelsHaveIndependentOwners() throws {
    let group = TranslationGroupContext(topic: "Table: Measurements", labels: ["Value", "Value"])
    let request = try #require(group.attributedRequest)
    #expect(String(request.characters) == "Table: Measurements: Value; Value")
    #expect(request.runs.compactMap(\.link).map(\.lastPathComponent) == ["0", "1"])
  }

  @Test(arguments: [";", "；", "؛"])
  func translatedLabelsReturnByOwnershipRatherThanOutputOrder(_ separator: String) {
    let group = TranslationGroupContext(topic: "Integer Types", labels: ["Signed", "Unsigned"])
    var response = AttributedString("정수형: 부호 없음" + separator + " 부호")
    response[response.range(of: "부호 없음")!].link = URL(string: "swiftycrow-context://item/1")!
    let last = response.characters.index(response.endIndex, offsetBy: -2)
    response[last...].link = URL(string: "swiftycrow-context://item/0")!
    #expect(group.targets(from: response) == ["부호", "부호 없음"])
  }

  @Test
  func missingOrPartialOwnershipCannotPublishAGroup() {
    let group = TranslationGroupContext(topic: "Types", labels: ["Signed", "Unsigned"])
    #expect(group.targets(from: nil) == nil)
    #expect(group.targets(from: AttributedString("종류: 부호; 부호 없음")) == nil)
    var response = AttributedString("종류: 부호; 부호 없음")
    response[response.range(of: "부호")!].link = URL(string: "swiftycrow-context://item/0")!
    response[response.range(of: "없음")!].link = URL(string: "swiftycrow-context://item/1")!
    #expect(group.targets(from: response) == nil)
  }

  @Test
  func mergedLabelsAndDuplicateIDsAreRejected() {
    let group = TranslationGroupContext(topic: "Types", labels: ["Signed", "Unsigned"])
    var response = AttributedString("종류: 부호; 부호 없음")
    response[response.range(of: "부호; 부호 없음")!].link = URL(string: "swiftycrow-context://item/0")!
    #expect(group.targets(from: response) == nil)
    #expect(group.targets(from: group.attributedRequest.map { _ in AttributedString("종류: 부호 부호 없음") }) == nil)
  }

  @Test
  func invalidSourceStructureCannotCreateAnAmbiguousRequest() {
    #expect(TranslationGroupContext(topic: "Topic", labels: ["one"]).attributedRequest == nil)
    #expect(TranslationGroupContext(topic: "Topic", labels: ["one; two", "three"]).attributedRequest == nil)
    #expect(TranslationGroupContext(topic: "Topic\nOther", labels: ["one", "two"]).attributedRequest == nil)
  }
}
