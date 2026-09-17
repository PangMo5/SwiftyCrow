// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// A take is selected explicitly. Passing machine checks never grants visual approval.
struct TakeLibrary {
  let workspace: Workspace

  static func validateStatistics(_ stats: JSON) throws {
    let frames = stats["frames"].double
    let dropped = stats["dropped"].double
    try require(
      stats["status"].str == "ok" && stats["error"].isNull && frames.isFinite && dropped.isFinite
        && frames > 0 && dropped >= 0 && dropped / (frames + dropped) <= 0.01
        && stats["durationSeconds"].double > 0,
      "Recorder failed or missed-slot budget exceeded"
    )
  }

  static func translationFile(_ film: String) -> String {
    switch film {
    case "live": "live-translated-ax.txt"
    case "layout": "layout-translated-ax.txt"
    case "compare": "compare-restored-ax.txt"
    default: "capture-translated-ax.txt"
    }
  }

  /// Script checks supplement the captured language selection; they cannot infer Hans/Hant alone.
  static func validateText(_ text: String, locale: String) throws {
    let required: String
    let forbidden: String
    switch locale {
    case "en": (required, forbidden) = ("[A-Za-z]", "[가-힣ぁ-ヿ一-鿿]")
    case "ko": (required, forbidden) = ("[가-힣]", "[ぁ-ヿ]")
    case "ja": (required, forbidden) = ("[ぁ-ヿ]", "[가-힣]")
    case "zh-Hans",
         "zh-Hant": (required, forbidden) = ("[一-鿿]", "[가-힣ぁ-ヿ]")
    default: throw ToolError("Unsupported evidence locale")
    }
    try require(
      !matches(required, text).isEmpty && matches(forbidden, text).isEmpty,
      "Actual translated text has the wrong writing system: \(locale)"
    )
  }

  func path(_ value: String) throws -> URL {
    try require(!value.isEmpty, "Missing evidence path")
    return value.hasPrefix("/") ? URL(fileURLWithPath: value) : workspace.root.at(value)
  }

  func key(_ take: JSON) throws -> String {
    let locale = take["locale"].str
    let film = take["film"].str
    let films = try JSON.read(workspace.root.at("DemoLab/Localization/Films.json"))["films"]
    try require(locales.contains(locale) && !films[film].isNull, "Unknown take: \(locale)/\(film)")
    return "\(locale)/\(film)"
  }

  func unique(_ takes: [JSON]) throws {
    try require(!takes.isEmpty, "No takes selected")
    var keys = Set<String>()
    for take in takes { try require(keys.insert(key(take)).inserted, "Duplicate film/locale selection") }
  }

  func validate(_ take: JSON) throws -> JSON {
    let id = try key(take)
    let directory = try path(take["directory"].str)
    let scene = try JSON.read(directory.at("scene.json"))
    let stats = try JSON.read(directory.at("capture-demo.json"))
    let film = try JSON.read(workspace.root.at("DemoLab/Localization/Films.json"))["films"][take["film"].str]
    let pair = try FilmLanguagePair(film: film, locale: take["locale"].str)
    try require(scene["film"] == take["film"] && scene["uiLanguage"] == take["locale"], "Wrong take identity: \(id)")
    try require(
      scene["translationSource"].str == pair.source && scene["translationTarget"].str == pair.target,
      "Wrong recorded language pair: \(id)"
    )
    try require(
      scene["actionVerification"]["storyCompleted"].boolean
        && scene["actionVerification"]["actualLanguagePairVerified"].boolean,
      "Incomplete runtime assertions: \(id)"
    )
    try Self.validateStatistics(stats)
    let timeline = try JSON.read(directory.at("presentation.json"))
    try FilmNarration.validate(
      timeline,
      film: take["film"].str,
      locale: take["locale"].str,
      duration: stats["durationSeconds"].double
    )
    try require(
      scene["scenariosSHA256"].str.count == 64 && scene["scenariosSHA256"] == timeline["scenariosSHA256"],
      "Scenario/timeline mismatch: \(id)"
    )
    let ready = try JSON.read(directory.at("capture-demo.ready.json"))
    try require(timeline["captureEpochUptimeNanoseconds"] == ready["firstFrameUptimeNanoseconds"], "Wrong capture epoch: \(id)")
    try require(directory.at("capture-demo.mov").exists, "Camera original missing: \(id)")
    return scene
  }

  func languageEvidence(_ take: JSON, scene: JSON) throws -> JSON {
    let evidence = try path(take["directory"].str).at(Self.translationFile(take["film"].str))
    let text = try evidence.text().components(separatedBy: " AXMenuBar")[0]
    let values = lines(text).compactMap { line -> String? in
      guard line.contains("AXUnknown "), let range = line.range(of: "AXDescription=") else { return nil }
      return String(line[range.upperBound...])
    }.joined(separator: "\n")
    try Self.validateText(values, locale: take["locale"].str)
    let pickers = scene["actionVerification"]["actualLanguagePickerValues"]
    try require(pickers.array.count == 2 && pickers.array.allSatisfy { !$0.str.isEmpty }, "Missing actual language picker values")
    return try .object([
      ("locale", take["locale"]),
      ("film", take["film"]),
      ("source", scene["translationSource"]),
      ("target", scene["translationTarget"]),
      ("actualTranslationText", .string(values)),
      ("actualLanguagePickerValues", pickers),
      ("evidenceFile", .string(relativePath(evidence, from: workspace.root))),
      ("evidenceSHA256", .string(sha(evidence))),
      ("targetMatchesUI", .bool(true)),
    ])
  }

  /// Freeze chosen takes and any human review. Unreviewed selections can be audited but not exported.
  func select(source: URL, output: URL) throws {
    try require(
      source.resolvingSymlinksInPath() != output.resolvingSymlinksInPath(),
      "Selection output must not replace its decisions"
    )
    let decisions = try JSON.read(source)["takes"].array
    try unique(decisions)
    var selected = [JSON]()
    for var take in decisions {
      let scene = try validate(take)
      let directory = try path(take["directory"].str)
      var hashes = [(String, JSON)]()
      for name in [
        "capture-demo.mov",
        "capture-demo.json",
        "capture-demo.ready.json",
        "scene.json",
        "presentation.json",
        Self.translationFile(take["film"].str),
      ] {
        hashes.append((name, .string(try sha(directory.at(name)))))
      }
      take["hashes"] = .object(hashes)
      take["actualLanguageEvidence"] = try languageEvidence(take, scene: scene)
      if !take["review"].str.isEmpty {
        let review = try path(take["review"].str)
        try require(!trim(review.text()).isEmpty, "Visual review is empty")
        take["reviewSHA256"] = .string(try sha(review))
      }
      selected.append(take)
    }
    try JSON.object([("schemaVersion", .integer(1)), ("takes", .array(selected))]).write(output)
    print("Selected \(selected.count) takes; visual review is required before export")
  }

  func selected(_ source: URL, reviewed: Bool) throws -> [JSON] {
    let selection = try JSON.read(source)
    try require(selection["schemaVersion"].int == 1, "Unsupported take selection version")
    let takes = selection["takes"].array
    try unique(takes)
    for take in takes {
      let scene = try validate(take)
      let directory = try path(take["directory"].str)
      for name in [
        "capture-demo.mov",
        "capture-demo.json",
        "capture-demo.ready.json",
        "scene.json",
        "presentation.json",
        Self.translationFile(take["film"].str),
      ] {
        try require(take["hashes"][name].str == sha(directory.at(name)), "Selected take changed: \(name)")
      }
      try require(languageEvidence(take, scene: scene) == take["actualLanguageEvidence"], "Selected language evidence changed")
      if reviewed {
        try require(
          !take["review"].str.isEmpty && take["reviewSHA256"].str == sha(path(take["review"].str)),
          "Visual review missing or changed"
        )
        let seconds = take["posterSeconds"].double
        let duration = try JSON.read(directory.at("capture-demo.json"))["durationSeconds"].double
        try require(seconds.isFinite && seconds >= 0 && seconds < duration, "Poster time is outside the selected take")
      }
    }
    return takes
  }

  func prepare(source: URL, output: URL) async throws {
    let takes = try selected(source, reviewed: false)
    try require(!output.exists, "Review directory already exists; use a new output")
    for take in takes {
      let destination = try output.at(key(take))
      try await VideoAudit(workspace: workspace).audit(
        source: path(take["directory"].str).at("capture-demo.mov"),
        output: destination
      )
    }
    print("Prepared contact sheets; visual acceptance remains pending")
  }

  func export(source: URL, output: URL) async throws {
    let takes = try selected(source, reviewed: true)
    var pending = [JSON]()
    for take in takes {
      let id = try key(take)
      let metadata = output.at(id + ".json")
      if metadata.exists {
        let value = try JSON.read(metadata)
        try require(value["selection"] == take, "Existing export belongs to another selection: \(id)")
        for (field, hash) in ReviewBundle.assets {
          try require(value[hash].str == sha(path(value[field].str)), "Existing export changed: \(id)/\(field)")
        }
        try require(value["cameraSHA256"] == take["hashes"]["capture-demo.mov"], "Existing export camera mismatch")
        print("\(id): retained verified export")
      } else {
        for suffix in ["mp4", "jpg", "ass"] {
          try require(!output.at(id + "." + suffix).exists, "Partial export exists; use a new media directory: \(id)")
        }
        pending.append(take)
      }
    }
    for take in pending {
      let directory = try path(take["directory"].str)
      try await VideoExport(workspace: workspace).export(
        source: directory.at("capture-demo.mov"),
        film: take["film"].str,
        locale: take["locale"].str,
        posterSeconds: take["posterSeconds"].double,
        review: path(take["review"].str),
        mediaRoot: output
      )
      let metadata = try output.at(key(take) + ".json")
      var value = try JSON.read(metadata)
      value["selection"] = take
      value["actualLanguageEvidence"] = take["actualLanguageEvidence"]
      try value.write(metadata)
    }
  }
}
