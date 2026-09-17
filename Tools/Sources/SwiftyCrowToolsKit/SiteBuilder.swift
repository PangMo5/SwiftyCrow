// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct SiteBuilder {
  let workspace: Workspace

  func build(
    output: URL,
    version requestedVersion: String?,
    locale selectedLocale: String? = nil,
    mediaRoot: URL? = nil
  ) async throws {
    // The approved review bundle is the single source for preview, CI, and release.
    // Explicit media roots remain available for incomplete review batches.
    let approvedMedia = workspace.root.at("DemoLab/Edits/media")
    if mediaRoot == nil {
      try ReviewBundle(workspace: workspace).verify(
        JSON.read(workspace.root.at("DemoLab/Edits/review-bundle.json")),
        portable: true
      )
    }
    if let selectedLocale { try require(locales.contains(selectedLocale), "Unsupported site locale") }
    let siteLocales = selectedLocale.map { [$0] } ?? locales
    let checks = CatalogChecks(workspace: workspace)
    let docs = DocumentBuilder(workspace: workspace)
    guard
      let version = try requestedVersion ?? matches(#"let appVersion = "([^"]+)""#, workspace.root.at("Project.swift").text())
        .first?[1]
    else { throw ToolError("Missing appVersion in Project.swift") }
    try require(fullMatch(#"\d+\.\d+\.\d+(?:[.-][A-Za-z0-9.-]+)?"#, version), "Invalid site version")
    let films = try checks.films()
    let values = try JSON.read(workspace.root.at("Localization/Web.json"))
    try output.makeDirectory()
    for file in try workspace.root.at("web").children() where ["css", "js"].contains(file.pathExtension) {
      try copy(file, output.at(file.lastPathComponent))
    }
    try copy(workspace.root.at("Resources/Marketing/app-icon.png"), output.at("icon.png"))
    for locale in siteLocales {
      for (name, film) in films.object {
        let pair = try FilmLanguagePair(film: film, locale: locale)
        let metadata = try JSON.read((mediaRoot ?? approvedMedia).at("\(locale)/\(name).json"))
        try require(
          metadata["uiLanguage"].str == locale
            && metadata["sourceLanguage"].str == pair.source
            && metadata["translationLanguage"].str == pair.target,
          "Demo result language does not match the page: \(name)/\(locale)"
        )
        for suffix in ["mp4", "jpg"] {
          let relative = "media/\(locale)/\(name).\(suffix)"
          try copy((mediaRoot ?? approvedMedia).at("\(locale)/\(name).\(suffix)"), output.at(relative))
        }
      }
    }
    for locale in siteLocales {
      let catalog = TextCatalog(values: values, locale: locale)
      for page in CatalogChecks.pages {
        var displayedFilms = Set<String>()
        var durations = [String: String]()
        if page == "index.html" {
          for (name, _) in films.object {
            let raw = try await runProcess([
              "ffprobe",
              "-v",
              "error",
              "-show_entries",
              "format=duration",
              "-of",
              "default=noprint_wrappers=1:nokey=1",
              output.at("media/\(locale)/\(name).mp4").path,
            ], capture: true)
            guard let duration = Double(trim(raw)), duration.isFinite, duration > 0 else {
              throw ToolError("Invalid video duration: \(name)/\(locale)")
            }
            let seconds = Int(duration)
            durations[name] = String(format: "%d:%02d", seconds / 60, seconds % 60)
          }
        }
        let root = try translateHTML(workspace.root.at("web/\(page)").text(), catalog, page)
        let prefix = locale == "en" ? "./" : "../"
        func pageLink(_ target: String) -> String {
          prefix + (target == "en" ? "" : target + "/") + page
        }
        try root.walk { node in
          if node.tag == "html" { node["lang"] = locale }
          for field in ["title", "caption"] {
            if let name = node["data-film-" + field] {
              try require(!films[name].isNull, "Unknown film copy: \(name)")
              node.children = [.text(films[name][field][locale].str)]
            }
          }
          if let name = node["data-film-poster"] {
            try require(!films[name].isNull, "Unknown film poster: \(name)")
            let relative = "media/\(locale)/\(name).jpg"
            node["src"] = try prefix + relative + "?v=" + sha(output.at(relative)).prefix(12)
          }
          if let name = node["data-film-duration"] {
            guard let duration = durations[name] else { throw ToolError("Unknown film duration: \(name)") }
            node.children = [.text(duration)]
          }
          if let name = node["data-film"] {
            try require(!films[name].isNull && displayedFilms.insert(name).inserted, "Unknown or repeated film: \(name)")
            node["aria-label"] = films[name]["title"][locale].str
            for (attribute, suffix) in [("src", "mp4"), ("poster", "jpg")] {
              let relative = "media/\(locale)/\(name).\(suffix)"
              node[attribute] = try prefix + relative + "?v=" + sha(output.at(relative)).prefix(12)
            }
          }
          for attribute in ["src", "href"] {
            guard
              let value = node[attribute],
              ["./style.css", "./site.js", "./docs.js", "./demos.js", "./icon.png"].contains(where: value.hasPrefix)
            else { continue }
            let name = String(value.dropFirst(2))
            node[attribute] = try prefix + name + "?v=" + sha(output.at(name)).prefix(12)
          }
          if let name = node["data-document"] {
            guard let source = docs.documents.first(where: { URL(fileURLWithPath: $0).lastPathComponent == name })
            else { throw ToolError("Unknown site document: \(name)") }
            node["data-document-src"] = prefix + "content/\(locale)/\(name)"
            node["data-source-url"] = "https://github.com/PangMo5/SwiftyCrow/blob/main/" + relativePath(
              docs.destination(source, locale),
              from: workspace.root
            )
          }
          if node.tag == "a", locale != "en", let value = node["href"] {
            let github = "https://github.com/PangMo5/SwiftyCrow/blob/main/"
            if value.hasPrefix(github), docs.documents.contains(String(value.dropFirst(github.count))) {
              node["href"] = github + relativePath(
                docs.destination(String(value.dropFirst(github.count)), locale),
                from: workspace.root
              )
            }
          }
          if node["class"] == "nav-inner", siteLocales.count > 1 {
            let options = siteLocales.map { code in
              HTMLChild.node(HTMLNode(
                "option",
                [("value", pageLink(code))] + (code == locale ? [("selected", nil)] : []),
                [.text(languageNames[code]!)]
              ))
            }
            node.children.append(.node(HTMLNode(
              "select",
              [
                ("data-language-picker", ""),
                ("aria-label", try catalog.text("Language", "picker")),
                ("class", "language-picker"),
              ],
              options
            )))
          }
          if node["class"] == "footer-inner", siteLocales.count > 1 {
            let links = siteLocales.map { code in
              HTMLChild.node(HTMLNode("a", [("href", pageLink(code)), ("data-language-link", "")] + (code == locale
                  ? [("aria-current", "page")]
                  : []), [.text(languageNames[code]!)]))
            }
            node.children.append(.node(HTMLNode(
              "nav",
              [("class", "language-links"), ("aria-label", try catalog.text("Language", "footer"))],
              links
            )))
          }
          if node.tag == "head" {
            func address(_ code: String) -> String {
              "https://swiftycrow.pangmo5.dev/" + (code == "en" ? "" : code + "/") +
                (page == "index.html"
                  ? ""
                  : page)
            }
            for code in siteLocales { node.children.append(.node(HTMLNode(
              "link",
              [("rel", "alternate"), ("hreflang", code), ("href", address(code))]
            ))) }
            node.children.append(.node(HTMLNode("link", [("rel", "canonical"), ("href", address(locale))])))
          }
        }
        if page == "index.html" {
          try require(displayedFilms == Set(films.object.map(\.0)), "Homepage does not include every declared film")
        }
        try output.at((locale == "en" ? "" : locale + "/") + page).write(root.render().replacingOccurrences(
          of: "__VERSION__",
          with: version
        ) + "\n")
      }
      for source in docs.documents {
        var text = try docs.stripNavigation(docs.destination(source, locale).text())
        if locale == "en" { text = try docs.anchorHeadings(text, docs.headings(text)) }
        try output.at("content/\(locale)/\(URL(fileURLWithPath: source).lastPathComponent)").write(docs.siteDocument(
          text,
          source,
          locale
        ))
      }
    }
    if let selectedLocale, selectedLocale != "en" {
      try output.at("index.html")
        .write(
          "<!doctype html><meta charset=\"utf-8\"><meta http-equiv=\"refresh\" content=\"0;url=./\(selectedLocale)/\"><a href=\"./\(selectedLocale)/\">SwiftyCrow</a>\n"
        )
    }
    print("Built \(CatalogChecks.pages.count * siteLocales.count) pages with locale-matched bundled documentation")
  }
}
