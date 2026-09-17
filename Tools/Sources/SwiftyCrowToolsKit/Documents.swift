// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct DocumentBuilder {
  let workspace: Workspace
  let documents = ["README.md", "CHANGELOG.md", "docs/CONFIGURATION.md", "docs/LANGUAGE_MODELS.md", "THIRD_PARTY_NOTICES.md"]

  func stripNavigation(_ text: String) -> String {
    String(replacing(#"(?s)\n?<!-- LANGUAGE-LINKS:START -->.*?<!-- LANGUAGE-LINKS:END -->\n?"#, in: text) { _ in
      ""
    }.drop(while: { $0 == "\n" }))
  }

  func destination(_ source: String, _ locale: String) -> URL {
    locale == "en"
      ? workspace.root.at(source)
      : workspace.root.at("docs/\(locale)/\(URL(fileURLWithPath: source).lastPathComponent)")
  }

  func source(_ name: String) throws -> String {
    try stripNavigation(workspace.root.at(name == "THIRD_PARTY_NOTICES.md" ? "Localization/ThirdPartyNotice.md" : name).text())
  }

  func languageLinks(_ source: String, _ locale: String) -> String {
    let directory = destination(source, locale).deletingLastPathComponent()
    let links = locales.map { "[\(languageNames[$0]!)](\(relativePath(destination(source, $0), from: directory)))" }
    return "<!-- LANGUAGE-LINKS:START -->\n" + links.joined(separator: " · ") + "\n<!-- LANGUAGE-LINKS:END -->\n\n"
  }

  func headings(_ text: String) -> [String] {
    var result = [String]()
    var counts = [String: Int]()
    var fence: Character?
    for line in lines(text) {
      if let marker = matches(#"^\s*(`{3,}|~{3,})"#, line).first {
        fence = fence == marker[1].first ? nil : marker[1].first
        continue
      }
      guard fence == nil, let heading = matches(#"^#{1,6}\s+(.+)$"#, line).first else { continue }
      let label = replacing("<[^>]+>", in: heading[1]) { _ in "" }
      let slug = trim(replacing(#"[^\p{L}\p{N}_\s-]"#, in: label.lowercased()) { _ in "" }).replacingOccurrences(
        of: " ",
        with: "-"
      )
      let count = counts[slug, default: 0]
      counts[slug] = count + 1
      result.append(slug + (count > 0 ? "-\(count)" : ""))
    }
    return result
  }

  func anchorHeadings(_ text: String, _ anchors: [String]) throws -> String {
    var output = [String]()
    var index = 0
    var fence: Character?
    for line in lines(text) {
      if let marker = matches(#"^\s*(`{3,}|~{3,})"#, line).first { fence = fence == marker[1].first ? nil : marker[1].first }
      if fence == nil, !matches(#"^#{1,6}\s"#, line).isEmpty {
        try require(index < anchors.count, "Changed documentation heading count")
        output.append("<a id=\"\(anchors[index])\"></a>")
        index += 1
      }
      output.append(line)
    }
    try require(index == anchors.count, "Changed documentation heading count")
    return output.joined(separator: "\n") + "\n"
  }

  func transformLinks(_ text: String, _ transform: (String) -> String) -> String {
    var fence: Character?
    return lines(text).map { line in
      let marker = matches(#"^\s*(`{3,}|~{3,})"#, line).first
      if let marker { fence = fence == marker[1].first ? nil : marker[1].first }
      guard fence == nil, marker == nil else { return line }
      let markdown = replacing(#"(?<=\]\()([^\s)]+)(?=\))"#, in: line) { transform($0[0]) }
      return replacing(#"\b(href|src)="([^"]+)""#, in: markdown) { "\($0[1])=\"\(transform($0[2]))\"" }
    }.joined(separator: "\n") + "\n"
  }

  func rewriteLinks(_ text: String, _ name: String, _ locale: String) -> String {
    let targetDirectory = destination(name, locale).deletingLastPathComponent()
    return transformLinks(text) { value in
      if
        var site = URLComponents(string: value), site.scheme == "https", site.host == "swiftycrow.pangmo5.dev",
        site.path == "/"
      {
        site.path += locale == "en" ? "" : locale + "/"
        return site.string ?? value
      }
      guard
        var parts = URLComponents(string: value), parts.scheme == nil, parts.host == nil,
        !parts.path.isEmpty
      else { return value }
      var original = workspace.root.at(name).deletingLastPathComponent().at(parts.path).standardizedFileURL
      let relative = relativePath(original, from: workspace.root)
      guard !relative.hasPrefix("../") else { return value }
      if relative.hasPrefix("DemoLab/Edits/media/en/") { original = workspace.root.at(relative.replacingOccurrences(
        of: "DemoLab/Edits/media/en/",
        with: "DemoLab/Edits/media/\(locale)/"
      )) }
      let target = documents.contains(relative) && relative != "THIRD_PARTY_NOTICES.md" ? destination(relative, locale) : original
      parts.path = relativePath(target, from: targetDirectory)
      return parts.string ?? value
    }
  }

  func siteDocument(_ text: String, _ name: String, _ locale: String) -> String {
    let directory = destination(name, locale).deletingLastPathComponent()
    let pages = ["README.md": "index.html", "CHANGELOG.md": "releases.html", "docs/CONFIGURATION.md": "configuration.html"]
    let destinations = Dictionary(uniqueKeysWithValues: documents.map { (
      relativePath(destination($0, locale), from: workspace.root),
      $0
    ) })
    let prefix = "https://github.com/PangMo5/SwiftyCrow/blob/main/"
    return transformLinks(text) { value in
      guard let parts = URLComponents(string: value) else { return value }
      let relative: String
      let source: String?
      if value.hasPrefix(prefix) {
        relative = String(parts.path.components(separatedBy: "/blob/main/").last ?? "")
        source = documents.contains(relative) ? relative : destinations[relative]
      } else if parts.scheme == nil, parts.host == nil, !parts.path.isEmpty {
        relative = relativePath(directory.at(parts.path).standardizedFileURL, from: workspace.root)
        if relative.hasPrefix("../") { return value }
        source = destinations[relative]
      } else { return value }
      let target: String =
        if let source, let page = pages[source] { "./" + page }
        else { prefix + (source.map { relativePath(destination($0, locale), from: workspace.root) } ?? relative) }
      return target + (parts.query.map { "?" + $0 } ?? "") + (parts.fragment.map { "#" + $0 } ?? "")
    }
  }

  func outputs(_ values: JSON, locale selectedLocale: String? = nil) throws -> [(URL, String)] {
    if let selectedLocale { try require(locales.contains(selectedLocale), "Unsupported document locale") }
    let outputLocales = selectedLocale.map { [$0] } ?? locales
    var output = [(URL, String)]()
    for name in documents {
      let original = try stripNavigation(workspace.root.at(name).text())
      let translatable = try source(name)
      if outputLocales.contains("en") { output.append((destination(name, "en"), languageLinks(name, "en") + original)) }
      for locale in outputLocales where locale != "en" {
        let text = try markdownUnits(translatable, TextCatalog(values: values, locale: locale), name)
        let anchored = try anchorHeadings(text, headings(translatable))
        output.append((destination(name, locale), languageLinks(name, locale) + rewriteLinks(anchored, name, locale)))
      }
    }
    return output
  }

  func build(check: Bool, locale: String? = nil) throws {
    if let locale { try require(locales.contains(locale), "Unsupported document locale") }
    let results = try outputs(JSON.read(workspace.root.at("Localization/Docs.json")), locale: locale)
    for (file, text) in results {
      if check { try require(
        file.exists && (try file.text()) == text,
        "Generated content drift: \(relativePath(file, from: workspace.root))"
      ) } else { try file.write(text) }
    }
    print("\(check ? "Verified" : "Generated") \(results.count) documents")
  }
}
