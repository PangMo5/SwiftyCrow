// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Browser document runtime")
@MainActor
struct WebRuntimeTests {
  var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func render(_ markdown: String, ok: Bool = true) throws -> JSContext {
    let context = JSContext()!
    context.evaluateScript("""
      const element = () => ({children: [], dataset: {}, appendChild(child) { this.children.push(child); }, replaceChildren() { this.children = []; }});
      const container = element();
      container.dataset = {mode: 'releases', documentSrc: 'content/ko/CHANGELOG.md', loadError: '불러오지 못했어요.', sourceLabel: 'GitHub에서 읽기', sourceUrl: 'https://github.com/PangMo5/SwiftyCrow', unreleasedLabel: '개발 중', noNotes: '내용이 없어요.'};
      const document = {documentElement: {lang: 'ko'}, querySelector: () => container, createElement: element};
      const location = {hash: ''};
      const fetch = async () => ({ok: \(ok), status: \(ok ? 200 : 404), text: async () => \(JSON.quote(markdown))});
      // Test grouping and failure copy here. Browser QA uses real Marked and DOMPurify.
      const marked = {parse: text => text}, DOMPurify = {sanitize: text => text};
      """)
    context.evaluateScript(try root.at("web/docs.js").text())
    #expect(context.exception == nil)
    return context
  }

  @Test
  func allHistoriesPreserveTagsAndSubsectionAnchors() throws {
    let docs = DocumentBuilder(workspace: Workspace(root: root))
    for locale in locales {
      var markdown = try docs.stripNavigation(docs.destination("CHANGELOG.md", locale).text())
      if locale == "en" { markdown = try docs.anchorHeadings(markdown, docs.headings(markdown)) }
      let context = try render(markdown)
      #expect(context.evaluateScript("container.children.length")?.toInt32() == 22)
      #expect(context.evaluateScript("container.children[0].id")?.toString() == "2100-2026-09-17")
      #expect(context.evaluateScript("container.children[0].innerHTML.includes('<a id=\"improvements\"></a>')")?.toBool() == true)
      #expect(context.evaluateScript("container.children[0].innerHTML.includes('releases/tag/v2.10.0')")?.toBool() == true)
      #expect(context.evaluateScript("container.children[1].innerHTML.includes('releases/tag/v2.9.1')")?.toBool() == true)
    }
  }

  @Test
  func versionedDraftHasNoPublicTagLink() throws {
    let context = try render("<a id=\"2100-unreleased\"></a>\n## 2.10.0（未リリース）\n\n- Draft notes\n")
    #expect(context.evaluateScript("container.children.length")?.toInt32() == 1)
    #expect(context.evaluateScript("container.children[0].innerHTML.includes('2.10.0')")?.toBool() == true)
    #expect(context.evaluateScript("container.children[0].innerHTML.includes('releases/tag/')")?.toBool() == false)
  }

  @Test
  func headingLikeCodeStaysInsideReleaseBody() throws {
    let context = try render("<a id=\"unreleased\"></a>\n## 출시 예정\n\n```md\n## Example heading\n<a id=\"sample\"></a>\n```\n")
    #expect(context.evaluateScript("container.children.length")?.toInt32() == 1)
    #expect(context.evaluateScript("container.children[0].innerHTML.includes('## Example heading')")?.toBool() == true)
  }

  @Test
  func failedRequestUsesLocaleCopyAndUsableLink() throws {
    let context = try render("", ok: false)
    #expect(context.evaluateScript("container.children[0].textContent")?.toString() == "불러오지 못했어요. ")
    #expect(context.evaluateScript("container.children[0].children[0].textContent")?.toString() == "GitHub에서 읽기")
    #expect(context.evaluateScript("container.children[0].children[0].href")?
      .toString() == "https://github.com/PangMo5/SwiftyCrow")
  }
}
#endif
