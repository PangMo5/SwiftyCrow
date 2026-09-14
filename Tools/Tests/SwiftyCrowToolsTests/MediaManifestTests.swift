// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Reviewed media provenance")
struct MediaManifestTests {
  @Test(arguments: [
    "source",
    "fixture",
    "catalog",
    "recordedCatalog",
    "archive",
    "video",
    "review",
    "film",
    "missingFilm",
    "narration",
    "subtitles",
    "scenarios",
    "languagePair",
  ])
  func rejectsChangedEvidenceWithoutReplacingTheManifest(_ changed: String) throws {
    let root = fm.temporaryDirectory.at(UUID().uuidString)
    try root.makeDirectory()
    defer { try? fm.removeItem(at: root) }
    let source = root.at("DemoLab/Fixtures/source.png")
    let fixture = root.at("DemoLab/Fixtures/manifest.json")
    let catalog = root.at("Resources/Localizable.xcstrings")
    let recordedCatalog = root.at("raw/Localizable.xcstrings")
    let review = root.at("review.md")
    let narration = root.at("DemoLab/Localization/Narration.json")
    let scenarios = root.at("DemoLab/Fixtures/scenarios.json")
    try narration.write("Declared narration")
    try scenarios.write("Declared scenarios")
    try source.write("Declared source pixels")
    try JSON.object([("files", .object([("Fixtures/source.png", .string(sha(source)))]))]).write(fixture)
    try catalog
      .write(#"{"sourceLanguage":"en","strings":{"Capture":{"localizations":{"en":{"stringUnit":{"value":"Capture"}}}}}}"#)
    try recordedCatalog.write(catalog.text())
    try review.write("Reviewed every film in every locale")
    let filmIDs = ["tour", "capture"]
    let films = JSON.object(filmIDs.map { id in
      (id, .object([
        ("sourceFixture", .string("Fixtures/manifest.json")),
        ("sourceLanguage", .string("en-US")),
        ("translationLanguage", .string("ko-KR")),
        ("title", .object(locales.map { ($0, .string("\(id) title \($0)")) })),
        ("caption", .object(locales.map { ($0, .string("\(id) caption \($0)")) })),
      ]))
    })
    try JSON.object([("sourceLanguage", .string("en")), ("films", films)])
      .write(root.at("DemoLab/Localization/Films.json"))
    try root.at("DemoLab/Recorder/source-provenance.json").write("{}")
    for film in filmIDs {
      for locale in locales {
        var metadata = try JSON.object([
          ("film", .string(film)),
          ("uiLanguage", .string(locale)),
          ("visualReviewEvidence", .string("review.md")),
          ("sourceLanguage", .string("en-US")),
          ("translationLanguage", .string("ko-KR")),
          ("narrationCatalogSHA256", .string(sha(narration))),
          ("recorder", .object([("durationSeconds", .decimal(6))])),
        ])
        for (key, hashKey, path) in [
          ("cameraOriginal", "cameraSHA256", "raw/\(locale)/\(film)/camera.mov"),
          ("movie", "movieSHA256", "web/media/\(locale)/\(film).mp4"),
          ("poster", "posterSHA256", "web/media/\(locale)/\(film).jpg"),
          ("subtitles", "subtitlesSHA256", "web/media/\(locale)/\(film).ass"),
        ] {
          try root.at(path).write("Evidence for \(locale)/\(film)/\(key)")
          metadata[key] = .string(path)
          metadata[hashKey] = .string(try sha(root.at(path)))
        }
        let timeline = root.at("raw/\(locale)/\(film)/presentation.json")
        try JSON.object([
          ("schemaVersion", .integer(1)),
          ("film", .string(film)),
          ("uiLanguage", .string(locale)),
          ("durationSeconds", .decimal(6)),
          ("captureEpochUptimeNanoseconds", .integer(123)),
          ("scenariosSHA256", .string(sha(scenarios))),
          ("events", .array([
            .object([
              ("track", .string("chapter")),
              ("id", .string(film + ".chapter")),
              ("start", .decimal(0)),
              ("end", .decimal(6)),
            ]),
            .object([
              ("track", .string("caption")),
              ("id", .string(film + ".intro")),
              ("start", .decimal(0)),
              ("end", .decimal(6)),
            ]),
            .object([("track", .string("keys")), ("chord", .string("cmd - c")), ("start", .decimal(2)), ("end", .decimal(4))]),
          ])),
        ]).write(timeline)
        metadata["presentationTimeline"] = .string(relativePath(timeline, from: root))
        metadata["presentationTimelineSHA256"] = .string(try sha(timeline))
        try metadata.write(root.at("web/media/\(locale)/\(film).json"))
        try JSON.object([
          ("film", .string(film)),
          ("uiLanguage", .string(locale)),
          ("translationSource", .string("en-US")),
          ("translationTarget", .string("ko-KR")),
          ("scenariosSHA256", .string(sha(scenarios))),
          ("sourceSHA256", .string(sha(fixture))),
          ("catalogSHA256", .string(sha(catalog))),
          ("appArchiveSHA256", .string(String(repeating: "a", count: 64))),
        ]).write(root.at("raw/\(locale)/\(film)/scene.json"))
      }
    }
    let exporter = VideoExport(workspace: Workspace(root: root))
    var annotated = try JSON.read(catalog)
    annotated["strings"]["Capture"]["comment"] = .string("Translator guidance added after capture")
    try annotated.write(catalog)
    try exporter.manifest(review: review, recordedCatalog: recordedCatalog)
    let manifest = root.at("DemoLab/media-manifest.json")
    let accepted = try Data(contentsOf: manifest)
    #expect(try JSON.read(manifest)["recordings"].array.count == 10)
    switch changed {
    case "source": try source.write("New, unrecorded source pixels")

    case "fixture":
      var value = try JSON.read(fixture)
      value["description"] = .string("Changed declared fixture")
      try value.write(fixture)

    case "catalog":
      annotated["strings"]["Capture"]["localizations"]["en"]["stringUnit"]["value"] = .string("Different label")
      try annotated.write(catalog)

    case "recordedCatalog":
      var value = try JSON.read(recordedCatalog)
      value["strings"]["Capture"]["comment"] = .string("Even harmless changes invalidate the original raw hash")
      try value.write(recordedCatalog)

    case "video": try root.at("web/media/ko/capture.mp4").write("Different export")

    case "narration": try narration.write("New unrecorded narration")

    case "subtitles": try root.at("web/media/ko/capture.ass").write("Different subtitles")

    case "scenarios": try scenarios.write("Changed scenarios")

    case "languagePair":
      let file = root.at("web/media/ko/capture.json")
      var value = try JSON.read(file)
      value["sourceLanguage"] = .string("ja-JP")
      try value.write(file)

    case "archive",
         "film":
      let file = root.at("raw/ko/capture/scene.json")
      var scene = try JSON.read(file)
      scene[changed == "archive" ? "appArchiveSHA256" : "film"] = .string(changed == "archive"
        ? String(repeating: "b", count: 64)
        : "tour")
      try scene.write(file)

    case "missingFilm": try fm.removeItem(at: root.at("web/media/zh-Hant/tour.json"))

    default:
      let file = root.at("web/media/ko/capture.json")
      var metadata = try JSON.read(file)
      metadata["visualReviewEvidence"] = .string("other-review.md")
      try metadata.write(file)
    }
    #expect(throws: (any Error).self) { try exporter.manifest(review: review, recordedCatalog: recordedCatalog) }
    #expect(try Data(contentsOf: manifest) == accepted)
  }
}
