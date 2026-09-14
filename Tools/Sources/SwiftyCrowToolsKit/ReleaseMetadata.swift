// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import cmark_gfm
import Markdown
import SwiftSoup

// MARK: - MarkdownStructure

struct MarkdownStructure {

  // MARK: Lifecycle

  init(_ source: String) {
    var headings = [Int]()
    var code = Set<Int>()
    func visit(_ node: any Markup) {
      if node is Heading, let range = node.range { headings.append(range.lowerBound.line - 1) }
      if node is CodeBlock, let range = node.range { code.formUnion((range.lowerBound.line - 1)...(range.upperBound.line - 1)) }
      for child in node.children { visit(child) }
    }
    visit(Document(parsing: source))
    headingLines = headings
    codeLines = code
  }

  // MARK: Internal

  let headingLines: [Int]
  let codeLines: Set<Int>

  static func html(_ source: String) throws -> String {
    guard let html = cmark_markdown_to_html(source, source.utf8.count, 0) else { throw ToolError("Markdown rendering failed") }
    defer { free(html) }
    return String(cString: html)
  }

}

// MARK: - ReleaseMetadata

struct ReleaseMetadata {
  let workspace: Workspace

  func embedNotes(file: URL, version: String) throws {
    try require(fullMatch(#"\d+\.\d+\.\d+"#, version), "Invalid appcast version")
    let builder = DocumentBuilder(workspace: workspace)
    var notes = [(String, String)]()
    for locale in locales {
      let source = try builder.destination("CHANGELOG.md", locale).text()
      let sourceLines = lines(source)
      let sections = MarkdownStructure(source).headingLines.filter { sourceLines[$0].hasPrefix("## ") }
      let minor = version.split(separator: ".").prefix(2).joined(separator: ".")
      var collected = [String]()
      var started = false
      for (index, line) in sections.enumerated() {
        let heading = String(sourceLines[line].dropFirst(3))
        let sectionVersion = matches(#"^v?(\d+\.\d+\.\d+)"#, heading).first?[1]
        if sectionVersion == version { started = true }
        if !started { continue }
        if sectionVersion?.split(separator: ".").prefix(2).joined(separator: ".") != minor { break }
        let end = index + 1 < sections.count ? sections[index + 1] : sourceLines.count
        collected.append(sourceLines[line..<end].joined(separator: "\n"))
      }
      try require(!collected.isEmpty, "No \(locale) changelog section for \(version)")
      let html = try SwiftSoup.parseBodyFragment(MarkdownStructure.html(collected.joined(separator: "\n")))
      let relative = relativePath(builder.destination("CHANGELOG.md", locale), from: workspace.root)
      let base = URL(string: "https://github.com/PangMo5/SwiftyCrow/blob/main/")!.appendingPathComponent(relative)
      for anchor in try html.select("a[href]") {
        let href = try anchor.attr("href")
        if let url = URL(string: href, relativeTo: base)?.absoluteURL { try anchor.attr("href", url.absoluteString) }
      }
      notes.append((locale, try html.body()?.html() ?? ""))
    }
    let document = try XMLDocument(contentsOf: file, options: [.nodePreserveAll])
    let items = try document.nodes(forXPath: "/rss/channel/item")
    try require(items.count == 1, "Expected a single release item in the generated appcast")
    guard let item = items.first as? XMLElement else { throw ToolError("Missing appcast item") }
    let existing = item.elements(forName: "description")
    if
      notes.allSatisfy({ locale, text in
        existing.contains { $0.attribute(forName: "xml:lang")?.stringValue == locale && $0.stringValue == text }
      })
    { print("Localized appcast descriptions already match")
      return
    }
    for description in existing { description.detach() }
    for (locale, text) in notes {
      let description = XMLElement(name: "description", stringValue: text)
      description.addAttribute(XMLNode.attribute(withName: "xml:lang", stringValue: locale) as! XMLNode)
      item.addChild(description)
    }
    // XMLDocument escapes the HTML as text, preserving XML validity even for ]]>.
    // Sparkle accepts the same description content without requiring CDATA syntax.
    try document.xmlData.write(to: file, options: .atomic)
    print("Appcast: embedded release notes in \(notes.count) languages")
  }
}
