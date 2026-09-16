// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A review bundle can contain independently recorded app/resource cohorts.
/// Each take keeps its own hashes; merging never relabels old recordings as a new build.
struct ReviewBundle {
  static let assets = [
    ("movie", "movieSHA256"),
    ("poster", "posterSHA256"),
    ("subtitles", "subtitlesSHA256"),
    ("presentationTimeline", "presentationTimelineSHA256"),
  ]

  let workspace: Workspace

  func merge(selection: URL, mediaRoot: URL, output: URL, base: URL? = nil) throws {
    try require(selection.resolvingSymlinksInPath() != output.resolvingSymlinksInPath(), "Bundle must not replace its selection")
    let library = TakeLibrary(workspace: workspace)
    let takes = try library.selected(selection, reviewed: true)
    var records = [JSON]()
    if let base {
      let previous = try JSON.read(base)
      try verify(previous, portable: false)
      let replacements = Set(try takes.map { try library.key($0) })
      records = try previous["recordings"].array.filter { !replacements.contains(try library.key($0["selection"])) }
    }
    for take in takes {
      let id = try library.key(take)
      let file = mediaRoot.at(id + ".json")
      var record = try JSON.read(file)
      try require(record["cameraSHA256"] == take["hashes"]["capture-demo.mov"], "Export is from another selected take: \(id)")
      try require(
        record["presentationTimelineSHA256"] == take["hashes"]["presentation.json"],
        "Export narration differs from selected take: \(id)"
      )
      try require(record["visualReviewEvidence"] == take["review"], "Export visual review differs from selection: \(id)")
      record["selection"] = take
      record["scene"] = try library.validate(take)
      record["actualLanguageEvidence"] = take["actualLanguageEvidence"]
      record["metadataFile"] = .string(relativePath(file, from: workspace.root))
      record["metadataSHA256"] = .string(try sha(file))
      records.append(record)
    }
    let bundle = try JSON.object([
      ("schemaVersion", .integer(1)),
      ("kind", .string("reviewed-demo-bundle")),
      ("filmCatalogSHA256", .string(sha(workspace.root.at("DemoLab/Localization/Films.json")))),
      ("recordings", .array(records)),
    ])
    try verify(bundle, portable: false)
    try bundle.write(output)
    print("Merged \(records.count) selected exports with independent per-take provenance")
  }

  func verify(_ bundle: JSON, portable: Bool) throws {
    try require(bundle["schemaVersion"].int == 1 && bundle["kind"].str == "reviewed-demo-bundle", "Unsupported review bundle")
    let filmsURL = workspace.root.at("DemoLab/Localization/Films.json")
    try require(bundle["filmCatalogSHA256"].str == sha(filmsURL), "Review film catalog changed")
    let films = try JSON.read(filmsURL)["films"]
    let records = bundle["recordings"].array
    let expected = Set(locales.flatMap { locale in films.object.map { "\(locale)/\($0.0)" } })
    var found = Set<String>()
    let library = TakeLibrary(workspace: workspace)
    for record in records {
      let take = record["selection"]
      let id = try library.key(take)
      try require(found.insert(id).inserted, "Duplicate bundle recording: \(id)")
      let pair = try FilmLanguagePair(film: films[take["film"].str], locale: take["locale"].str)
      try require(
        record["film"] == take["film"] && record["uiLanguage"] == take["locale"]
          && record["sourceLanguage"].str == pair.source && record["translationLanguage"].str == pair.target,
        "Bundle language mismatch: \(id)"
      )
      for (path, hash) in Self.assets + [("metadataFile", "metadataSHA256")] {
        try require(record[hash].str == sha(library.path(record[path].str)), "Bundle asset changed: \(id)/\(path)")
      }
      let metadata = try JSON.read(library.path(record["metadataFile"].str))
      for key in ["film", "uiLanguage", "sourceLanguage", "translationLanguage", "cameraSHA256", "recorder"]
        + Self.assets.flatMap({ [$0.0, $0.1] })
      {
        try require(metadata[key] == record[key], "Bundle differs from export metadata: \(id)/\(key)")
      }
      try TakeLibrary.validateStatistics(record["recorder"])
      try require(
        record["cameraSHA256"] == take["hashes"]["capture-demo.mov"]
          && record["presentationTimelineSHA256"] == take["hashes"]["presentation.json"],
        "Selection/export binding changed"
      )
      try require(
        take["reviewSHA256"].str == sha(library.path(take["review"].str))
          && record["visualReviewEvidence"] == take["review"],
        "Visual review changed: \(id)"
      )
      let evidence = record["actualLanguageEvidence"]
      let scene = record["scene"]
      try require(
        evidence == take["actualLanguageEvidence"] && evidence["targetMatchesUI"].boolean
          && evidence["source"].str == pair.source && evidence["target"].str == pair.target
          && scene["translationSource"].str == pair.source && scene["translationTarget"].str == pair.target
          && scene["film"] == take["film"] && scene["uiLanguage"] == take["locale"]
          && scene["actionVerification"]["storyCompleted"].boolean
          && scene["actionVerification"]["actualLanguagePairVerified"].boolean
          && scene["actionVerification"]["actualLanguagePickerValues"] == evidence["actualLanguagePickerValues"],
        "Runtime language evidence mismatch: \(id)"
      )
      try TakeLibrary.validateText(evidence["actualTranslationText"].str, locale: take["locale"].str)
      let timeline = try JSON.read(library.path(record["presentationTimeline"].str))
      try FilmNarration.validate(
        timeline,
        film: take["film"].str,
        locale: take["locale"].str,
        duration: record["recorder"]["durationSeconds"].double
      )
      try require(timeline["scenariosSHA256"] == scene["scenariosSHA256"], "Scenario evidence mismatch")
      if !portable {
        let current = try library.validate(take)
        let directory = try library.path(take["directory"].str)
        try require(
          current == scene && library.languageEvidence(take, scene: current) == evidence,
          "Recorded evidence changed: \(id)"
        )
        for (name, hash) in take["hashes"].object {
          try require(!name.contains("/") && hash.str == sha(directory.at(name)), "Selected raw evidence changed: \(id)/\(name)")
        }
      }
    }
    try require(
      found == expected,
      "Bundle must contain exactly one take for every film and locale; missing: \(expected.subtracting(found).sorted())"
    )
    print(
      "Verified \(records.count) recordings (\(portable ? "portable assets and preserved evidence" : "including camera originals"))"
    )
  }

  /// Publish into a fresh directory only, using a same-filesystem staging rename.
  func install(source: URL, output: URL) throws {
    let bundle = try JSON.read(source)
    try verify(bundle, portable: false)
    try require(!output.exists, "Install destination already exists; use a new directory")
    let library = TakeLibrary(workspace: workspace)
    let staging = output.deletingLastPathComponent().at(".swiftycrow-install-" + UUID().uuidString)
    try staging.makeDirectory()
    defer { try? fm.removeItem(at: staging) }
    var records = [JSON]()
    for var record in bundle["recordings"].array {
      let id = try library.key(record["selection"])
      for (field, hash) in Self.assets {
        let input = try library.path(record[field].str)
        let suffix = field == "presentationTimeline" ? "timeline.json" : input.pathExtension
        let relative = "media/\(id).\(suffix)"
        try copy(input, staging.at(relative))
        try require(sha(staging.at(relative)) == record[hash].str, "Installed asset hash mismatch: \(id)")
        record[field] = .string(relativePath(output.at(relative), from: workspace.root))
      }
      var metadata = record
      for field in ["scene", "metadataFile", "metadataSHA256"] { metadata.remove(field) }
      let relative = "media/\(id).json"
      try metadata.write(staging.at(relative))
      record["metadataFile"] = .string(relativePath(output.at(relative), from: workspace.root))
      record["metadataSHA256"] = .string(try sha(staging.at(relative)))
      records.append(record)
    }
    try bundle.merging([("recordings", .array(records))]).write(staging.at("manifest.json"))
    // Recheck all source evidence after the copies, before making the new bundle visible.
    try verify(bundle, portable: false)
    try fm.moveItem(at: staging, to: output)
    print("Installed verified review bundle at \(output.path)")
  }
}
