// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Localization contracts")
struct LocalizationTests {

  // MARK: Internal

  @Test
  func `readme posters follow the approved locale media`() {
    let docs = DocumentBuilder(workspace: workspace)
    let result = docs.rewriteLinks("![Capture](DemoLab/Edits/media/en/capture.jpg)", "README.md", "ja")
    #expect(result.contains("../../DemoLab/Edits/media/ja/capture.jpg"))
    #expect(!result.contains("web/media"))
  }

  @Test
  func `regex offsets can split combining characters`() {
    let text = "Cafe\u{301}"
    #expect(matches(#"(e)(\p{M})"#, text) == [["e\u{301}", "e", "\u{301}"]])
    #expect(replacing(#"\p{M}"#, in: text) { _ in "" } == "Cafe")
    #expect(replacing(#"(a)?b"#, in: "b") { $0[1] + "c" } == "c")
  }

  @Test
  func `heading slugs handle emoji variation selectors`() {
    #expect(DocumentBuilder(workspace: workspace).headings("## ⚠️ Breaking changes\n## 🎉 Features") == [
      "breaking-changes",
      "features",
    ])
  }

  @Test
  func `translation scope excludes internal guidance`() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.documents.allSatisfy { !$0.hasPrefix("DemoLab/") && !$0.contains("LOCALIZATION") && !$0.contains("AGENTS") })
  }

  @Test
  func `missing translation fails`() {
    #expect(throws: ToolError.self) { try TextCatalog(locale: "ko").text("Save image", "button") }
  }

  @Test(arguments: ["저장 {0}", "저장 {0} {0} {1}"])
  func `placeholder loss and duplication fail`(_ translation: String) {
    #expect(throws: ToolError.self) { try catalog("Save {0} to {1}", translation).text("Save {0} to {1}", "guide") }
  }

  @Test
  func `complete sentence can reorder code and link`() throws {
    let source = "Read `config.toml` in [the guide](docs/CONFIGURATION.md)."
    let value = try inlineUnit(source, catalog("Read {0} in [the guide]({1}).", "[안내]({1})에서 {0}을 읽어 주세요."), "guide")
    #expect(value == "[안내](docs/CONFIGURATION.md)에서 `config.toml`을 읽어 주세요.")
  }

  @Test
  func `code fences and anchors stay stable`() throws {
    let source = "# Configuration\n\n```sh\n# Keep this English comment\nprintf \"Hello\"\n```\n"
    let translated = try markdownUnits(source, catalog("Configuration", "설정"), "guide")
    let docs = DocumentBuilder(workspace: workspace)
    #expect(translated.contains("# Keep this English comment\nprintf \"Hello\""))
    #expect(docs.headings(source) == ["configuration"])
    #expect(try docs.anchorHeadings(translated, ["configuration"]).hasPrefix("<a id=\"configuration\"></a>\n# 설정"))
    #expect(throws: ToolError.self) { try markdownUnits("```sh\necho hello", TextCatalog(), "invalid") }
  }

  @Test
  func `multiline quotes stay one unit`() throws {
    let source = "> Read the guide\n> before you change settings.\n"
    let result = try markdownUnits(
      source,
      catalog("Read the guide before you change settings.", "설정을 바꾸기 전에 안내를 읽어 주세요."),
      "guide",
    )
    #expect(result == "> 설정을 바꾸기 전에 안내를 읽어 주세요.\n")
  }

  @Test
  func `source examples stay in their declared language`() throws {
    let root = try translateHTML(
      "<p translate=\"no\">Original source text</p><p>Translation</p>",
      catalog("Translation", "번역문"),
      "page",
    )
    #expect(root.render().contains("Original source text"))
    #expect(root.render().contains("번역문"))
  }

  @Test
  func `printf arguments may reorder without changing types`() {
    let source = CatalogChecks.placeholders("%@ has %lld results (100%%)")
    #expect(source == CatalogChecks.placeholders("%2$lld개: %1$@ (100%%)"))
    #expect(source != CatalogChecks.placeholders("%@ has %@ results"))
  }

  @Test
  func `repository navigation does not enter displayed content`() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.stripNavigation(docs.languageLinks("README.md", "en") + "# SwiftyCrow\n") == "# SwiftyCrow\n")
  }

  @Test
  func `license overview keeps original notice target`() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs
      .rewriteLinks("[Original](THIRD_PARTY_NOTICES.md)\n", "THIRD_PARTY_NOTICES.md", "ko") ==
      "[Original](../../THIRD_PARTY_NOTICES.md)\n")
  }

  @Test
  func `site links resolve from their document and locale`() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.rewriteLinks("[Watch](https://swiftycrow.pangmo5.dev/#demo-live)\n", "README.md", "ko") ==
      "[Watch](https://swiftycrow.pangmo5.dev/ko/#demo-live)\n")
    let text = docs.siteDocument(
      "[Config](CONFIGURATION.md#languages) [Models](LANGUAGE_MODELS.md) [License](../../LICENSE)\n",
      "README.md",
      "ko",
    )
    #expect(text.contains("(./configuration.html#languages)"))
    #expect(text.contains("(https://github.com/PangMo5/SwiftyCrow/blob/main/docs/ko/LANGUAGE_MODELS.md)"))
    #expect(text.contains("(https://github.com/PangMo5/SwiftyCrow/blob/main/LICENSE)"))
    let historical = "[Config](https://github.com/PangMo5/SwiftyCrow/blob/main/docs/CONFIGURATION.md)\n"
    #expect(docs.siteDocument(historical, "CHANGELOG.md", "ja") == "[Config](./configuration.html)\n")
  }

  @Test
  func `selected locale does not require unreviewed translations`() throws {
    let root = fm.temporaryDirectory.at("swiftycrow-locale-\(UUID().uuidString)")
    defer { try? fm.removeItem(at: root) }
    let docs = DocumentBuilder(workspace: Workspace(root: root))
    for name in docs.documents + ["Localization/ThirdPartyNotice.md"] {
      try root.at(name).write("# Guide\n")
    }
    let values = JSON.object([(textKey("Guide"), .object([
      ("en", .string("Guide")),
      ("ko", .string("안내")),
    ]))])
    let korean = try docs.outputs(values, locale: "ko")
    #expect(korean.count == docs.documents.count)
    #expect(korean.allSatisfy { $0.0.path.contains("/docs/ko/") && $0.1.contains("# 안내") })
    #expect(throws: ToolError.self) { try docs.outputs(values) }
    #expect(throws: ToolError.self) { try docs.outputs(values, locale: "unknown") }
  }

  @Test
  func `swift port preserves existing catalogs and generated documents`() throws {
    try CatalogChecks(workspace: workspace).all()
  }

  // MARK: Private

  private var workspace: Workspace {
    Workspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent())
  }

  private func catalog(_ source: String, _ translation: String) -> TextCatalog {
    TextCatalog(
      values: .object([(textKey(source), .object([("en", .string(source)), ("ko", .string(translation))]))]),
      locale: "ko",
    )
  }

}
