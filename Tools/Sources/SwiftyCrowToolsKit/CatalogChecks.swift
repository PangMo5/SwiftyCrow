// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct CatalogChecks {
  static let pages = ["index.html", "configuration.html", "releases.html"]

  let workspace: Workspace

  var docs: DocumentBuilder {
    DocumentBuilder(workspace: workspace)
  }

  static func placeholders(_ source: String) -> [String] {
    var implicit = 0
    return matches(
      #"%(?:(\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(lld|llu|ld|lu|d|u|@|f|g|s)"#,
      source.replacingOccurrences(of: "%%", with: "")
    ).map { match in
      let position: Int
      if let explicit = Int(match[1]) { position = explicit }
      else { implicit += 1
        position = implicit
      }
      return "\(position):\(match[2])"
    }.sorted()
  }

  func extractedKeys(_ directory: URL) throws -> [String: JSON] {
    var results = [String: JSON]()
    guard let files = fm.enumerator(at: directory, includingPropertiesForKeys: nil)
    else { throw ToolError("Missing compiler string output") }
    for case let file as URL in files where file.pathExtension == "stringsdata" {
      let data = try JSON.read(file)
      let source = URL(fileURLWithPath: data["source"].str).resolvingSymlinksInPath()
      guard source.exists, source.path.hasPrefix(workspace.root.at("Sources").path + "/") else { continue }
      for entry in data["tables"]["Localizable"].array { results[entry["key"].str] = entry }
    }
    return results
  }

  func syncApp(_ directory: URL) throws {
    let file = workspace.root.at("Resources/Localizable.xcstrings")
    var catalog = try JSON.read(file)
    let extracted = try extractedKeys(directory)
    try require(!extracted.isEmpty, "No compiler-generated app localization keys found")
    var strings = JSON.object([])
    for key in extracted.keys.sorted() {
      var entry = catalog["strings"][key]
      if entry.isNull { entry = .object([
        ("extractionState", .string("manual")),
        (
          "localizations",
          .object([("en", .object([("stringUnit", .object([("state", .string("translated")), ("value", .string(key))]))]))])
        ),
      ]) }
      if let comment = extracted[key]?["comment"].string, !comment.isEmpty { entry["comment"] = .string(comment) }
      strings[key] = entry
    }
    catalog["strings"] = strings
    try catalog.write(file)
    print("Synced \(extracted.count) compiler-extracted app keys")
  }

  func app(_ directory: URL? = nil, locale selectedLocale: String? = nil) throws {
    if let selectedLocale { try require(locales.contains(selectedLocale), "Unsupported app locale") }
    let checkedLocales = selectedLocale.map { $0 == "en" ? ["en"] : ["en", $0] } ?? locales
    var total = 0
    for name in ["Localizable", "InfoPlist"] {
      let catalog = try JSON.read(workspace.root.at("Resources/\(name).xcstrings"))
      try require(catalog["sourceLanguage"].str == "en", "English must remain the source language")
      for (key, entry) in catalog["strings"].object {
        let english = entry["localizations"]["en"]["stringUnit"]["value"].str
        let source = name == "Localizable" ? key : english
        for locale in checkedLocales {
          let unit = entry["localizations"][locale]["stringUnit"]
          let value = unit["value"].str
          try require(
            unit["state"].str == "translated" && unit["value"].string != nil && (key.isEmpty || !value.isEmpty),
            "Missing app translation: \(name)/\(key)/\(locale)"
          )
          try require(Self.placeholders(source) == Self.placeholders(value), "Changed app placeholders: \(key)/\(locale)")
          try require(!value.contains("—"), "Em dash in interface copy: \(key)/\(locale)")
          let words = replacing(#"%(?:[0-9]+\$)?(?:lld|llu|ld|lu|d|u|@|f|g|s)"#, in: english) { _ in "" }
          if locale != "en", value == english, entry["shouldTranslate"] != .bool(false), !matches("[A-Za-z]", words).isEmpty {
            throw ToolError("Unreviewed English app copy: \(key)/\(locale)")
          }
        }
        total += 1
      }
      if name == "Localizable", let directory {
        let extracted = try extractedKeys(directory)
        try require(!extracted.isEmpty, "No compiler-generated app localization keys found")
        let keys = Set(catalog["strings"].object.map(\.0))
        let missing = Set(extracted.keys).subtracting(keys)
        let unused = keys.subtracting(extracted.keys)
        try require(missing.isEmpty, "Uncataloged app keys: \(missing.sorted().joined(separator: ", "))")
        try require(unused.isEmpty, "Stale app keys; sync compiler output: \(unused.sorted().joined(separator: ", "))")
      }
    }
    print("Validated \(total) app and permission keys in \(checkedLocales.count) locales")
  }

  func visit(_ kind: String, _ catalog: TextCatalog) throws {
    if kind == "docs" {
      for name in docs.documents { _ = try markdownUnits(docs.source(name), catalog, name) }
    } else {
      for page in Self.pages { _ = try translateHTML(workspace.root.at("web/\(page)").text(), catalog, page) }
      _ = try catalog.text("Language", "language navigation")
    }
  }

  func collect(_ kind: String) throws {
    let catalog = TextCatalog()
    try visit(kind, catalog)
    let file = workspace.root.at("Localization/\(kind == "docs" ? "Docs" : "Web").json")
    let old = file.exists ? try JSON.read(file) : .object([])
    var values = JSON.object([])
    for key in catalog.observed.keys.sorted() {
      values[key] = old[key].isNull ? .object([]) : old[key]
      values[key]["en"] = .string(catalog.observed[key]!.english)
    }
    try values.write(file)
    print("\(kind): \(values.object.count) source units")
  }

  func text(_ kind: String, locale selectedLocale: String? = nil) throws {
    if let selectedLocale { try require(locales.contains(selectedLocale), "Unsupported catalog locale") }
    let checkedLocales = selectedLocale.map { [$0] } ?? Array(locales.dropFirst())
    let values = try JSON.read(workspace.root.at("Localization/\(kind == "docs" ? "Docs" : "Web").json"))
    for locale in checkedLocales {
      let catalog = TextCatalog(values: values, locale: locale)
      try visit(kind, catalog)
      let unused = Set(values.object.map(\.0)).subtracting(catalog.observed.keys)
      try require(unused.isEmpty, "Unused \(kind) source units; collect and review: \(unused.sorted())")
      for (key, observed) in catalog.observed {
        let legal = observed.english == "[GNU Affero General Public License v3.0 only]({0}) ({1}). Copyright (C) 2021-2026 PangMo5."
        try require(
          locale == "en" || legal || values[key][locale].str != observed.english,
          "Unreviewed English copy in \(kind)/\(key)/\(locale)"
        )
      }
    }
    print("Validated \(values.object.count) \(kind) units for \(selectedLocale ?? "all locales")")
  }

  @discardableResult
  func films() throws -> JSON {
    let catalog = try JSON.read(workspace.root.at("DemoLab/Localization/Films.json"))
    try require(catalog["sourceLanguage"].str == "en", "Film source language must be English")
    try require(!catalog["films"].object.isEmpty, "Film catalog is empty")
    for (name, film) in catalog["films"].object {
      try require(fullMatch("[a-z][a-z0-9-]*", name), "Invalid film identifier: \(name)")
      try require(!film["sourceFixture"].str.isEmpty, "Missing source fixture: \(name)")
      for field in ["title", "caption"] {
        for locale in locales {
          let value = film[field][locale].str
          try require(
            !value.isEmpty && (locale == "en" || value != film[field]["en"].str),
            "Missing film translation: \(name)/\(field)/\(locale)"
          )
        }
      }
    }
    print("Validated \(catalog["films"].object.count) films in \(locales.count) locales")
    return catalog["films"]
  }

  func all(locale: String? = nil) throws {
    try app(locale: locale)
    try text("docs", locale: locale)
    try text("web", locale: locale)
    try films()
    let narration = try FilmNarration(workspace: workspace).catalog()
    print("Validated \(narration.object.count) narration cues in \(locales.count) locales")
    try docs.build(check: true, locale: locale)
  }
}
