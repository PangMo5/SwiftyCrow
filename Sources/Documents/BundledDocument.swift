// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SwiftUI

// MARK: - BundledDocument

enum BundledDocument: String, CaseIterable, Identifiable, Sendable {
  case thirdPartyNotices
  case changelog
  case license

  // MARK: Internal

  static let repositoryURL = URL(string: "https://github.com/PangMo5/SwiftyCrow/blob/main/")!

  var id: Self {
    self
  }

  var title: LocalizedStringResource {
    switch self {
    case .thirdPartyNotices: "Third-Party Notices"
    case .changelog: "Changelog"
    case .license: "License (AGPL-3.0-only)"
    }
  }

  var sourcePath: String {
    switch self {
    case .thirdPartyNotices: "THIRD_PARTY_NOTICES.md"
    case .changelog: "CHANGELOG.md"
    case .license: "LICENSE"
    }
  }

  var sourceURL: URL {
    Self.repositoryURL.appendingPathComponent(sourcePath)
  }

  static func language(preferences: [String]) -> String {
    Bundle.preferredLocalizations(from: ["en", "ko", "ja", "zh-Hans", "zh-Hant"], forPreferences: preferences).first ?? "en"
  }

  func resolveLink(_ url: URL, language: String = "en") -> URL {
    if url.scheme == nil, url.path.isEmpty, let fragment = url.fragment {
      return URL(string: "swiftycrow-document://\(rawValue)#\(fragment)")!
    }
    let base: URL =
      if language == "en" || self == .license { sourceURL }
      else { Self.repositoryURL.appendingPathComponent("docs/\(language)/" + (sourcePath as NSString).lastPathComponent) }
    let absolute = URL(string: url.relativeString, relativeTo: base)!.absoluteURL
    guard absolute.host == "github.com" else { return absolute }
    let prefix = "/pangmo5/swiftycrow/blob/main/"
    guard absolute.path.lowercased().hasPrefix(prefix) else { return absolute }
    var path = String(absolute.path.dropFirst(prefix.count))
    for locale in ["ko", "ja", "zh-Hans", "zh-Hant"] {
      path = path.replacingOccurrences(of: "docs/\(locale)/", with: "docs/")
    }
    if path == "docs/THIRD_PARTY_NOTICES.md" || path == "docs/CHANGELOG.md" {
      path = String(path.dropFirst(5))
    }
    guard let target = Self.allCases.first(where: { $0.sourcePath == path }) else { return absolute }
    var components = URLComponents()
    components.scheme = "swiftycrow-document"
    components.host = target.rawValue
    components.fragment = self == .thirdPartyNotices && target == self && absolute.fragment == nil
      ? "original-license-notices"
      : absolute.fragment
    return components.url!
  }
}

// MARK: - BundledDocumentBlock

struct BundledDocumentBlock: Identifiable, Sendable {
  enum Kind: Sendable {
    case text
    case heading(Int)
    case code
    case rule
    case table
  }

  struct Cell: Identifiable, Sendable { let id: Int
    var text: AttributedString
  }

  struct Row: Identifiable, Sendable { let id: Int
    let isHeader: Bool
    var cells: [Cell]
  }

  let id: Int
  var kind: Kind
  var text: AttributedString
  var marker: String?
  var indentation = 0
  var isQuote = false
  var rows = [Row]()
}

// MARK: - ParsedBundledDocument

struct ParsedBundledDocument: Sendable {

  // MARK: Lifecycle

  init(plainText: String) {
    blocks = [BundledDocumentBlock(id: 1, kind: .code, text: AttributedString(plainText))]
    anchors = [:]
  }

  init(markdown: String, document: BundledDocument, language: String = "en") throws {
    let cleaned = Self.clean(markdown)
    var value = try AttributedString(markdown: cleaned.text, options: .init(interpretedSyntax: .full))
    for run in value.runs {
      if let link = run.link { value[run.range].link = document.resolveLink(link, language: language) }
      if run.inlinePresentationIntent?.contains(.code) == true {
        value[run.range].font = .system(.body, design: .monospaced)
      }
    }
    blocks = []
    anchors = [:]
    var headingIndex = 0
    for (intent, range) in value.runs[\.presentationIntent] {
      guard let intent, let leaf = intent.components.first else { continue }
      let text = AttributedString(value[range])
      if
        let table = intent.components.first(where: { if case .table = $0.kind { true } else { false } }),
        let row = intent.components
          .first(where: { if case .tableHeaderRow = $0.kind { true } else if case .tableRow = $0.kind { true } else { false } })
      {
        if blocks.last?.id != table.identity { blocks.append(BundledDocumentBlock(
          id: table.identity,
          kind: .table,
          text: AttributedString()
        )) }
        let blockIndex = blocks.count - 1
        if blocks[blockIndex].rows.last?.id != row.identity {
          blocks[blockIndex].rows.append(.init(id: row.identity, isHeader: row.kind == .tableHeaderRow, cells: []))
        }
        let rowIndex = blocks[blockIndex].rows.count - 1
        blocks[blockIndex].rows[rowIndex].cells.append(.init(id: leaf.identity, text: text))
        continue
      }
      var block = BundledDocumentBlock(id: leaf.identity, kind: .text, text: text)
      switch leaf.kind {
      case .header(let level):
        block.kind = .heading(level)
        if cleaned.anchors.indices.contains(headingIndex) { anchors[cleaned.anchors[headingIndex]] = leaf.identity }
        headingIndex += 1

      case .codeBlock: block.kind = .code

      case .thematicBreak: block.kind = .rule

      default: break
      }
      let components = intent.components
      if
        let item = components.firstIndex(where: { if case .listItem = $0.kind { true } else { false } }),
        case .listItem(let ordinal) = components[item].kind
      {
        block.marker = components.dropFirst(item + 1).first?.kind == .orderedList ? "\(ordinal)." : "•"
        block.indentation = max(0, components.count(where: { if case .listItem = $0.kind { true } else { false } }) - 1)
      }
      block.isQuote = components.contains { $0.kind == .blockQuote }
      blocks.append(block)
    }
    if document == .changelog {
      guard
        let firstRelease = blocks.firstIndex(where: {
          guard case .heading(2) = $0.kind else { return false }
          // Retain the current Unreleased section while this release is under review.
          return true
        })
      else { throw CocoaError(.fileReadCorruptFile) }
      blocks.removeFirst(firstRelease)
    }
  }

  // MARK: Internal

  var blocks: [BundledDocumentBlock]
  var anchors: [String: Int]

  static func clean(_ source: String) -> (text: String, anchors: [String]) {
    var output = [String]()
    var anchors = [String]()
    var pendingAnchor: String?
    var used = [String: Int]()
    var navigation = false
    var comment = false
    var fence: (Character, Int)?
    for line in source.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let current = fence {
        output.append(line)
        if trimmed.prefix(while: { $0 == current.0 }).count >= current.1 { fence = nil }
        continue
      }
      if let first = trimmed.first, first == "`" || first == "~", trimmed.prefix(while: { $0 == first }).count >= 3 {
        fence = (first, trimmed.prefix(while: { $0 == first }).count)
        output.append(line)
        continue
      }
      if trimmed.contains("<!-- LANGUAGE-LINKS:START -->") { navigation = true
        continue
      }
      if navigation { if trimmed.contains("<!-- LANGUAGE-LINKS:END -->") { navigation = false }
        continue
      }
      if comment { if trimmed.contains("-->") { comment = false }
        continue
      }
      if trimmed.hasPrefix("<!--") { comment = !trimmed.contains("-->")
        continue
      }
      let utf16 = trimmed as NSString
      if let match = anchorExpression.firstMatch(in: trimmed, range: NSRange(location: 0, length: utf16.length)) {
        pendingAnchor = utf16.substring(with: match.range(at: 1))
        continue
      }
      let level = trimmed.prefix(while: { $0 == "#" }).count
      if (1...6).contains(level), trimmed.dropFirst(level).hasPrefix(" ") {
        let title = String(trimmed.dropFirst(level + 1))
        let plain = (try? AttributedString(markdown: title)).map { String($0.characters) } ?? title
        let slug = plain.lowercased().replacingOccurrences(of: #"[^\w\s-]"#, with: "", options: .regularExpression)
          .replacingOccurrences(
            of: " ",
            with: "-"
          )
        let occurrence = used[slug, default: 0]
        used[slug] = occurrence + 1
        anchors.append(pendingAnchor ?? (slug + (occurrence > 0 ? "-\(occurrence)" : "")))
        pendingAnchor = nil
      }
      output.append(line)
    }
    return (output.joined(separator: "\n"), anchors)
  }

  // MARK: Private

  /// Strip repository navigation and HTML metadata outside code fences. Keep
  /// explicit heading anchors for in-document navigation, without displaying tags.
  private static let anchorExpression = try! NSRegularExpression(pattern: #"^<a\s+id="([^"]+)"\s*></a>$"#)

}

// MARK: - BundledDocumentLoader

actor BundledDocumentLoader {

  // MARK: Internal

  static let shared = BundledDocumentLoader()

  nonisolated var unownedExecutor: UnownedSerialExecutor {
    executor.asUnownedSerialExecutor()
  }

  func load(_ document: BundledDocument, language: String, bundle: Bundle = .main) throws -> ParsedBundledDocument {
    let key = bundle.bundleURL.path + ":" + document.rawValue + ":" + language
    if let cached = cache[key] { return cached }
    guard let resources = bundle.resourceURL else { throw CocoaError(.fileNoSuchFile) }
    let result: ParsedBundledDocument
    if document == .license {
      result = ParsedBundledDocument(plainText: try String(
        contentsOf: resources.appendingPathComponent("LICENSE"),
        encoding: .utf8
      ))
    } else {
      let filename = (document.sourcePath as NSString).lastPathComponent
      let originalURL = resources.appendingPathComponent(filename)
      let path = resources.appendingPathComponent(language == "en" ? filename : "\(language)/\(filename)")
      var source = try String(contentsOf: path, encoding: .utf8)
      if document == .thirdPartyNotices, language != "en" {
        // Keep the complete original notice, including its scope and copyright
        // preamble, after the localized overview. Do not alter license wording.
        let original = try String(contentsOf: originalURL, encoding: .utf8)
        source += "\n\n<a id=\"original-license-notices\"></a>\n" + original
      }
      result = try ParsedBundledDocument(markdown: source, document: document, language: language)
    }
    cache[key] = result
    return result
  }

  // MARK: Private

  private let executor = DispatchSerialQueue(label: "dev.PangMo5.SwiftyCrow.documents", qos: .userInitiated)
  private var cache = [String: ParsedBundledDocument]()

}
