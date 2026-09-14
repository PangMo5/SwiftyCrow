// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftSoup

// MARK: - TextCatalog

final class TextCatalog {

  // MARK: Lifecycle

  init(values: JSON = .object([]), locale: String = "en") {
    self.values = values
    self.locale = locale
  }

  // MARK: Internal

  let values: JSON
  let locale: String
  var observed = [String: (english: String, context: String)]()

  func text(_ source: String, _ context: String) throws -> String {
    let normalized = trim(replacing(#"\s+"#, in: source) { _ in " " })
    let remainder = trim(replacing(#"\{\d+\}"#, in: normalized) { _ in "" })
    let identity: Set = [
      "SwiftyCrow",
      "Tatami",
      "Amado",
      "PangMo5",
      "GitHub",
      "macOS",
      "TOML",
      "JSON",
      "BCP-47",
      "en",
      "ko",
      "ja",
      "zh-Hans",
      "zh-Hant",
      "__VERSION__",
      "bool",
      "string",
      "double",
      "int",
      "true",
      "false",
      "null",
    ]
    if remainder.isEmpty || matches("[A-Za-z]", remainder).isEmpty || identity.contains(remainder) { return normalized }
    if fullMatch(#"v?\d+\.\d+\.\d+(?:[-.][\w.]+)?(?: \(\d{4}-\d{2}-\d{2}\))?"#, remainder) { return normalized }
    let key = textKey(normalized)
    if observed[key] == nil { observed[key] = (normalized, context) }
    if locale == "en" { return normalized }
    try require(values[key]["en"].str == normalized, "Stale source: \(context): \(key): \(normalized)")
    let translated = values[key][locale].str
    try require(!translated.isEmpty, "Missing \(locale): \(key) / \(normalized)")
    try require(
      matches(#"\{\d+\}"#, normalized).map { $0[0] }.sorted() == matches(#"\{\d+\}"#, translated).map { $0[0] }.sorted(),
      "Changed placeholders: \(key) / \(locale)"
    )
    return translated
  }

}

func htmlEscape(_ source: String, quotes: Bool = true) -> String {
  var text = source.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(
    of: ">",
    with: "&gt;"
  )
  if quotes { text = text.replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#x27;") }
  return text
}

let voidTags: Set = [
  "area",
  "base",
  "br",
  "col",
  "embed",
  "hr",
  "img",
  "input",
  "link",
  "meta",
  "param",
  "source",
  "track",
  "wbr",
]

// MARK: - HTMLNode

final class HTMLNode {

  // MARK: Lifecycle

  init(_ tag: String, _ attributes: [(String, String?)] = [], _ children: [HTMLChild] = []) {
    self.tag = tag
    self.attributes = attributes
    self.children = children
  }

  // MARK: Internal

  let tag: String
  var attributes: [(String, String?)]
  var children: [HTMLChild]

  subscript(_ attribute: String) -> String? {
    get { attributes.first { $0.0 == attribute }?.1 }
    set {
      if let index = attributes.firstIndex(where: { $0.0 == attribute }) { attributes[index].1 = newValue }
      else { attributes.append((attribute, newValue)) }
    }
  }

  func has(_ attribute: String) -> Bool {
    attributes.contains { $0.0 == attribute }
  }

  func render() -> String {
    let content = children.map { $0.render() }.joined()
    switch tag {
    case "#root": return content
    case "#markup": return children.first?.text ?? ""
    case "#comment": return "<!--" + (children.first?.text ?? "") + "-->"
    case "#doctype": return "<!" + (children.first?.text ?? "") + ">"
    default: break
    }
    let attrs = attributes.map { " " + $0.0 + ($0.1.map { "=\"" + htmlEscape($0) + "\"" } ?? "") }.joined()
    let opening = "<" + tag + attrs + ">"
    if voidTags.contains(tag) { return opening }
    return opening + (["script", "style"].contains(tag) ? children.compactMap(\.text).joined() : content) + "</" + tag + ">"
  }

  func walk(_ visitor: (HTMLNode) throws -> Void) rethrows {
    try visitor(self)
    for child in children { if let node = child.node { try node.walk(visitor) } }
  }

}

// MARK: - HTMLChild

enum HTMLChild {
  case text(String)
  case node(HTMLNode)

  var text: String? {
    if case .text(let value) = self { return value }
    return nil
  }

  var node: HTMLNode? {
    if case .node(let value) = self { return value }
    return nil
  }

  func render() -> String {
    switch self
    { case .text(let value): htmlEscape(value, quotes: false)
    case .node(let value): value.render() }
  }
}

/// SwiftSoup handles HTML tokenization, entities and the browser-compatible tree.
/// The small translation tree keeps movable prose placeholders separate from markup.
func translationTree(_ source: String) throws -> HTMLNode {
  func convert(_ node: SwiftSoup.Node) throws -> HTMLChild {
    if let node = node as? SwiftSoup.TextNode { return .text(node.getWholeText()) }
    if let node = node as? SwiftSoup.DataNode { return .text(node.getWholeData()) }
    if let node = node as? SwiftSoup.Comment { return .node(HTMLNode("#comment", [], [.text(node.getData())])) }
    if node is SwiftSoup.DocumentType { return .node(HTMLNode("#markup", [], [.text(try node.outerHtml())])) }
    let booleanAttributes: Set = [
      "controls",
      "muted",
      "playsinline",
      "defer",
      "selected",
      "disabled",
      "hidden",
      "autoplay",
      "loop",
      "checked",
      "multiple",
      "required",
      "open",
    ]
    let attributes = node.getAttributes()?.asList().map { attribute -> (String, String?) in
      let key = attribute.getKey()
      let value = attribute.getValue()
      return (key, booleanAttributes.contains(key) && value.isEmpty ? nil : value)
    } ?? []
    return .node(HTMLNode(node.nodeName(), attributes, try node.getChildNodes().map(convert)))
  }
  let nodes: [SwiftSoup.Node] =
    if !matches("(?i)<(?:!doctype|html)\\b", source).isEmpty {
      try SwiftSoup.parse(source).getChildNodes()
    } else {
      try SwiftSoup.parseBodyFragment(source).body()?.getChildNodes() ?? []
    }
  return HTMLNode("#root", [], try nodes.map(convert))
}

func translateHTML(_ source: String, _ catalog: TextCatalog, _ context: String) throws -> HTMLNode {
  let root = try translationTree(source)
  let blocks: Set = ["div", "section", "nav", "aside", "article", "main", "footer", "header", "ul", "ol", "li", "video", "pre"]
  let translatable: Set = [
    "p",
    "h1",
    "h2",
    "h3",
    "h4",
    "title",
    "a",
    "button",
    "summary",
    "label",
    "span",
    "option",
    "small",
  ]
  func visit(_ node: HTMLNode) throws {
    if
      ["script", "style", "pre", "code", "#comment", "#doctype", "#markup"]
        .contains(node.tag) || node["translate"] == "no" { return }
    for attribute in [
      "aria-label",
      "title",
      "alt",
      "placeholder",
      "data-source-label",
      "data-unreleased-label",
      "data-copied-label",
      "data-copy-error",
      "data-play-hint",
      "data-load-error",
      "data-no-notes",
    ] {
      if let value = node[attribute], !value.isEmpty { node[attribute] = try catalog.text(value, context + " / " + attribute) }
    }
    if
      node.tag == "meta" && (node["name"] == "description" || ["og:title", "og:description"].contains(node["property"] ?? "")),
      let content = node["content"]
    { node["content"] = try catalog.text(
      content,
      context + " / meta"
    ) }
    for child in node.children { if let child = child.node { try visit(child) } }
    let eligible = translatable.contains(node.tag) || (node.tag == "div" && node.children.allSatisfy { $0.text != nil })
    if !eligible || node.children.contains(where: { $0.node.map { blocks.contains($0.tag) } ?? false }) { return }
    var protected = [HTMLChild]()
    var source = ""
    func protect(_ child: HTMLChild) {
      source += "{\(protected.count)}"
      protected.append(child)
    }
    for child in node.children {
      if
        let element = child.node, ["em", "strong", "b", "i"].contains(element.tag),
        element.children.allSatisfy({ $0.text != nil })
      {
        protect(.node(HTMLNode("#markup", [], [.text("<" + element.tag + ">")])))
        source += element.children.compactMap(\.text).joined()
        protect(.node(HTMLNode("#markup", [], [.text("</" + element.tag + ">")])))
      } else if child.node != nil { protect(child) }
      else { source += child.text! }
    }
    if trim(source).isEmpty { return }
    let translated = try catalog.text(source, context + " / " + node.tag)
    var children = [HTMLChild]()
    var cursor = translated.startIndex
    let regex = try! NSRegularExpression(pattern: #"\{(\d+)\}"#)
    for match in regex.matches(in: translated, range: NSRange(translated.startIndex..., in: translated)) {
      let range = Range(match.range, in: translated)!
      if cursor < range.lowerBound { children.append(.text(String(translated[cursor..<range.lowerBound]))) }
      let index = Int(translated[Range(match.range(at: 1), in: translated)!])!
      try require(index < protected.count, "Invalid protected HTML index")
      children.append(protected[index])
      cursor = range.upperBound
    }
    if cursor < translated.endIndex { children.append(.text(String(translated[cursor...]))) }
    node.children = children
  }
  try visit(root)
  return root
}

func inlineUnit(_ source: String, _ catalog: TextCatalog, _ context: String) throws -> String {
  var protected = [String]()
  let text = replacing(#"<[^>]+>|(`+)(.+?)\1|(?<=\]\()([^\s)]+)(?=\))|https?://[^\s<>]+"#, in: source) { match in
    protected.append(match[0])
    return "{\(protected.count - 1)}"
  }
  return try replacing(#"\{(\d+)\}"#, in: catalog.text(text, context)) { match in
    let index = Int(match[1])!
    try require(index < protected.count, "Invalid inline placeholder")
    return protected[index]
  }
}

func markdownUnits(_ source: String, _ catalog: TextCatalog, _ context: String) throws -> String {
  let input = lines(source)
  var output = [String]()
  var index = 0
  var fence: Character?
  var comment = false
  while index < input.count {
    let line = input[index]
    index += 1
    if line.contains("<!--") {
      comment = !line.contains("-->")
      output.append(line)
      continue
    }
    if comment {
      output.append(line)
      if line.contains("-->") { comment = false }
      continue
    }
    if let marker = matches(#"^\s*(`{3,}|~{3,})"#, line).first {
      if fence == nil { fence = marker[1].first }
      else if fence == marker[1].first { fence = nil }
      output.append(line)
      continue
    }
    if fence != nil || trim(line).isEmpty || !matches(#"^\s*</?(?:details|a)\b"#, line).isEmpty {
      output.append(line)
      continue
    }
    if let heading = matches(#"^(#{1,6})\s+(.+)$"#, line).first {
      output.append(try heading[1] + " " + inlineUnit(heading[2], catalog, context + "/heading"))
      continue
    }
    if line.hasPrefix("|") {
      if fullMatch(#"[| :\-]+"#, line) { output.append(line) }
      else {
        let cells = replacing(#"\|(?=(?:[^`]*`[^`]*`)*[^`]*$)"#, in: line) { _ in "\u{0}" }.components(separatedBy: "\u{0}")
        output
          .append(try cells.map { trim($0).isEmpty ? "" : try inlineUnit(trim($0), catalog, context + "/table") }
            .joined(separator: "|"))
      }
      continue
    }
    if line.hasPrefix("> ") {
      var block = [String(line.dropFirst(2))]
      while index < input.count, input[index].hasPrefix("> "), !trim(String(input[index].dropFirst(2))).isEmpty {
        block.append(String(input[index].dropFirst(2)))
        index += 1
      }
      output.append(try "> " + inlineUnit(block.joined(separator: " "), catalog, context + "/quote"))
      continue
    }
    let prefix = matches(#"^(\s*(?:[-*+] |\d+\. ))(.*)$"#, line).first
    let lead = prefix?[1] ?? ""
    var block = [prefix?[2] ?? line]
    while
      index < input.count, !trim(input[index]).isEmpty,
      matches(#"^(?:#{1,6} |\s*[-*+] |\s*\d+\. |\||<|>|```|~~~)"#, input[index]).isEmpty
    {
      block.append(trim(input[index]))
      index += 1
    }
    output.append(try lead + inlineUnit(block.joined(separator: " "), catalog, context + "/prose"))
  }
  try require(fence == nil, "Unclosed Markdown code fence: \(context)")
  return output.joined(separator: "\n") + "\n"
}
