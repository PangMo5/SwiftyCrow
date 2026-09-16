// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Localization contracts")
struct LocalizationTests {
  var workspace: Workspace {
    Workspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent())
  }

  func catalog(_ source: String, _ translation: String) -> TextCatalog {
    TextCatalog(
      values: .object([(textKey(source), .object([("en", .string(source)), ("ko", .string(translation))]))]),
      locale: "ko"
    )
  }

  @Test
  func regexOffsetsCanSplitCombiningCharacters() {
    let text = "Cafe\u{301}"
    #expect(matches(#"(e)(\p{M})"#, text) == [["e\u{301}", "e", "\u{301}"]])
    #expect(replacing(#"\p{M}"#, in: text) { _ in "" } == "Cafe")
    #expect(replacing(#"(a)?b"#, in: "b") { $0[1] + "c" } == "c")
  }

  @Test
  func headingSlugsHandleEmojiVariationSelectors() {
    #expect(DocumentBuilder(workspace: workspace).headings("## ⚠️ Breaking changes\n## 🎉 Features") == [
      "breaking-changes",
      "features",
    ])
  }

  @Test
  func translationScopeExcludesInternalGuidance() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.documents.allSatisfy { !$0.hasPrefix("DemoLab/") && !$0.contains("LOCALIZATION") && !$0.contains("AGENTS") })
  }

  @Test
  func missingTranslationFails() {
    #expect(throws: ToolError.self) { try TextCatalog(locale: "ko").text("Save image", "button") }
  }

  @Test(arguments: ["저장 {0}", "저장 {0} {0} {1}"])
  func placeholderLossAndDuplicationFail(_ translation: String) {
    #expect(throws: ToolError.self) { try catalog("Save {0} to {1}", translation).text("Save {0} to {1}", "guide") }
  }

  @Test
  func completeSentenceCanReorderCodeAndLink() throws {
    let source = "Read `config.toml` in [the guide](docs/CONFIGURATION.md)."
    let value = try inlineUnit(source, catalog("Read {0} in [the guide]({1}).", "[안내]({1})에서 {0}을 읽어 주세요."), "guide")
    #expect(value == "[안내](docs/CONFIGURATION.md)에서 `config.toml`을 읽어 주세요.")
  }

  @Test
  func codeFencesAndAnchorsStayStable() throws {
    let source = "# Configuration\n\n```sh\n# Keep this English comment\nprintf \"Hello\"\n```\n"
    let translated = try markdownUnits(source, catalog("Configuration", "설정"), "guide")
    let docs = DocumentBuilder(workspace: workspace)
    #expect(translated.contains("# Keep this English comment\nprintf \"Hello\""))
    #expect(docs.headings(source) == ["configuration"])
    #expect(try docs.anchorHeadings(translated, ["configuration"]).hasPrefix("<a id=\"configuration\"></a>\n# 설정"))
    #expect(throws: ToolError.self) { try markdownUnits("```sh\necho hello", TextCatalog(), "invalid") }
  }

  @Test
  func multilineQuotesStayOneUnit() throws {
    let source = "> Read the guide\n> before you change settings.\n"
    let result = try markdownUnits(
      source,
      catalog("Read the guide before you change settings.", "설정을 바꾸기 전에 안내를 읽어 주세요."),
      "guide"
    )
    #expect(result == "> 설정을 바꾸기 전에 안내를 읽어 주세요.\n")
  }

  @Test
  func sourceExamplesStayInTheirDeclaredLanguage() throws {
    let root = try translateHTML(
      "<p translate=\"no\">Original source text</p><p>Translation</p>",
      catalog("Translation", "번역문"),
      "page"
    )
    #expect(root.render().contains("Original source text"))
    #expect(root.render().contains("번역문"))
  }

  @Test
  func printfArgumentsMayReorderWithoutChangingTypes() {
    let source = CatalogChecks.placeholders("%@ has %lld results (100%%)")
    #expect(source == CatalogChecks.placeholders("%2$lld개: %1$@ (100%%)"))
    #expect(source != CatalogChecks.placeholders("%@ has %@ results"))
  }

  @Test
  func repositoryNavigationDoesNotEnterDisplayedContent() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.stripNavigation(docs.languageLinks("README.md", "en") + "# SwiftyCrow\n") == "# SwiftyCrow\n")
  }

  @Test
  func licenseOverviewKeepsOriginalNoticeTarget() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs
      .rewriteLinks("[Original](THIRD_PARTY_NOTICES.md)\n", "THIRD_PARTY_NOTICES.md", "ko") ==
      "[Original](../../THIRD_PARTY_NOTICES.md)\n")
  }

  @Test
  func siteLinksResolveFromTheirDocumentAndLocale() {
    let docs = DocumentBuilder(workspace: workspace)
    #expect(docs.rewriteLinks("[Watch](https://swiftycrow.pangmo5.dev/#demo-live)\n", "README.md", "ko") ==
      "[Watch](https://swiftycrow.pangmo5.dev/ko/#demo-live)\n")
    let text = docs.siteDocument(
      "[Config](CONFIGURATION.md#languages) [Models](LANGUAGE_MODELS.md) [License](../../LICENSE)\n",
      "README.md",
      "ko"
    )
    #expect(text.contains("(./configuration.html#languages)"))
    #expect(text.contains("(https://github.com/PangMo5/SwiftyCrow/blob/main/docs/ko/LANGUAGE_MODELS.md)"))
    #expect(text.contains("(https://github.com/PangMo5/SwiftyCrow/blob/main/LICENSE)"))
    let historical = "[Config](https://github.com/PangMo5/SwiftyCrow/blob/main/docs/CONFIGURATION.md)\n"
    #expect(docs.siteDocument(historical, "CHANGELOG.md", "ja") == "[Config](./configuration.html)\n")
  }

  @Test
  func selectedLocaleDoesNotRequireUnreviewedTranslations() throws {
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
  func swiftPortPreservesExistingCatalogsAndGeneratedDocuments() throws {
    try CatalogChecks(workspace: workspace).all()
  }
}
