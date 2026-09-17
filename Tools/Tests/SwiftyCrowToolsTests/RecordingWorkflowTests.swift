// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

// MARK: - ReviewFixture

struct ReviewFixture {

  // MARK: Lifecycle

  init(reviewed: Bool = true) throws {
    root = fm.temporaryDirectory.at("swiftycrow-workflow-" + UUID().uuidString)
    workspace = Workspace(root: root)
    try root.makeDirectory()
    let targets = ["en": "en-US", "ko": "ko-KR", "ja": "ja-JP", "zh-Hans": "zh-Hans", "zh-Hant": "zh-Hant"]
    let output = ["en": "Read the map", "ko": "지도를 읽으세요", "ja": "地図を読んでください", "zh-Hans": "请阅读地图", "zh-Hant": "請閱讀地圖"]
    let pairs = JSON.object(locales.map { locale in
      (locale, .object([
        ("sourceLanguage", .string(locale == "en" ? "ko-KR" : "en-US")),
        ("translationLanguage", .string(targets[locale]!)),
      ]))
    })
    try JSON.object([("films", .object([("tour", .object([("languagePairs", pairs)]))]))])
      .write(root.at("DemoLab/Localization/Films.json"))
    try root.at("review.md").write("Reviewed complete camera takes and actual translation output.")
    var takes = [JSON]()
    for locale in locales {
      let directory = root.at("raw/\(locale)/tour-01")
      let take = JSON.object([
        ("locale", .string(locale)),
        ("film", .string("tour")),
        ("directory", .string("raw/\(locale)/tour-01")),
        ("posterSeconds", .integer(2)),
      ])
      takes.append(reviewed ? take.merging([("review", .string("review.md"))]) : take)
      try directory.at("capture-demo.mov").write("synthetic camera bytes: \(locale)")
      let stats = try JSON.parse(#"{"status":"ok","frames":300,"dropped":0,"durationSeconds":10,"error":null}"#)
      try stats.write(directory.at("capture-demo.json"))
      try JSON.parse(#"{"firstFrameUptimeNanoseconds":100000}"#).write(directory.at("capture-demo.ready.json"))
      var timeline = try NarrationTests().timeline()
      timeline["uiLanguage"] = .string(locale)
      timeline["scenariosSHA256"] = .string(String(repeating: "a", count: 64))
      try timeline.write(directory.at("presentation.json"))
      let scene = JSON.object([
        ("film", .string("tour")),
        ("uiLanguage", .string(locale)),
        ("translationSource", pairs[locale]["sourceLanguage"]),
        (
          "translationTarget",
          pairs[locale]["translationLanguage"]
        ),
        ("scenariosSHA256", timeline["scenariosSHA256"]),
        ("appArchiveSHA256", .string(String(repeating: locale == "ko" ? "b" : "c", count: 64))),
        (
          "actionVerification",
          .object([
            ("storyCompleted", .bool(true)),
            ("actualLanguagePairVerified", .bool(true)),
            (
              "actualLanguagePickerValues",
              .array([.string("Source picker"), .string("Target picker")])
            ),
          ])
        ),
      ])
      try scene.write(directory.at("scene.json"))
      try directory.at("capture-translated-ax.txt").write(" AXUnknown AXDescription=\(output[locale]!)\n AXMenuBar\n")
      let media = root.at("media/\(locale)")
      try media.at("tour.mp4").write("synthetic encoded bytes: \(locale)")
      try media.at("tour.jpg").write("synthetic poster: \(locale)")
      try media.at("tour.ass").write("caption \(locale)")
      try copy(directory.at("presentation.json"), media.at("tour.timeline.json"))
      var metadata = JSON.object([
        ("film", .string("tour")),
        ("uiLanguage", .string(locale)),
        ("sourceLanguage", scene["translationSource"]),
        (
          "translationLanguage",
          scene["translationTarget"]
        ),
        ("cameraOriginal", .string("raw/\(locale)/tour-01/capture-demo.mov")),
        ("cameraSHA256", .string(try sha(directory.at("capture-demo.mov")))),
        ("recorder", stats),
        ("visualReviewEvidence", .string("review.md")),
      ])
      for (field, suffix) in [
        ("movie", "mp4"),
        ("poster", "jpg"),
        ("subtitles", "ass"),
        ("presentationTimeline", "timeline.json"),
      ] {
        metadata[field] = .string("media/\(locale)/tour.\(suffix)")
        metadata[field + "SHA256"] = .string(try sha(media.at("tour." + suffix)))
      }
      try metadata.write(media.at("tour.json"))
    }
    try JSON.object([("takes", .array(takes))]).write(decisions)
  }

  // MARK: Internal

  let root: URL
  let workspace: Workspace

  var library: TakeLibrary {
    TakeLibrary(workspace: workspace)
  }

  var bundle: ReviewBundle {
    ReviewBundle(workspace: workspace)
  }

  var decisions: URL {
    root.at("decisions.json")
  }

  var selected: URL {
    root.at("selection.json")
  }

  var merged: URL {
    root.at("bundle.json")
  }

  func assemble() throws {
    try library.select(source: decisions, output: selected)
    try bundle.merge(selection: selected, mediaRoot: root.at("media"), output: merged)
  }

  func plan() throws -> JSON {
    var plan = JSON.object([])
    for name in ["demoqa", "app", "archive", "catalog", "source", "sourceApp", "config", "recorder"] {
      try root.at("inputs/" + name).write(name)
      plan[name] = .string("inputs/" + name)
    }
    let scenarios = JSON.object([("version", .integer(2)), ("locales", .object(locales.map { locale in
      (locale, .object([("tour", .object([
        ("targetLanguage", .string(locale == "en"
            ? "en-US"
            : locale == "ko" ? "ko-KR" : locale == "ja" ? "ja-JP" : locale)),
        (
          "sources",
          .array([.object([("language", .string(locale == "en" ? "ko-KR" : "en-US"))])])
        ),
      ]))]))
    }))])
    try scenarios.write(root.at("inputs/scenarios.json"))
    plan["scenarios"] = .string("inputs/scenarios.json")
    plan["takes"] = try JSON.read(decisions)["takes"]
    return plan
  }
}

// MARK: - RecordingWorkflowTests

@Suite("Recording and review workflow")
struct RecordingWorkflowTests {
  @Test
  func defaultSiteBuildRejectsChangedApprovedMediaBeforeWritingOutput() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    try copy(f.merged, f.root.at("DemoLab/Edits/review-bundle.json"))
    try f.root.at("media/en/tour.mp4").write("changed after approval")
    await #expect(throws: ToolError.self) {
      try await SiteBuilder(workspace: f.workspace).build(output: f.root.at("site"), version: "2.10.0")
    }
    #expect(!f.root.at("site").exists)
  }

  @Test(arguments: [
    "capture-demo.mov",
    "scene.json",
    "capture-demo.json",
    "presentation.json",
    "capture-translated-ax.txt",
    "review.md",
  ])
  func rejectsChangesAfterSelection(_ file: String) throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.library.select(source: f.decisions, output: f.selected)
    let url = file == "review.md" ? f.root.at(file) : f.root.at("raw/en/tour-01/" + file)
    try url.write(url.text() + " ")
    #expect(throws: (any Error).self) { try f.library.selected(f.selected, reviewed: true) }
  }

  @Test
  func technicalPassDoesNotGrantVisualApproval() throws {
    let f = try ReviewFixture(reviewed: false)
    defer { try? fm.removeItem(at: f.root) }
    try f.library.select(source: f.decisions, output: f.selected)
    #expect(try f.library.selected(f.selected, reviewed: false).count == 5)
    #expect(throws: ToolError.self) { try f.library.selected(f.selected, reviewed: true) }
  }

  @Test
  func preservesDifferentArchiveCohortsAndInstallsWithoutChangingSources() throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    let originalHash = try sha(f.root.at("media/ko/tour.mp4"))
    let destination = f.root.at("installed")
    try f.bundle.install(source: f.merged, output: destination)
    try f.bundle.verify(JSON.read(destination.at("manifest.json")), portable: false)
    #expect(try sha(destination.at("media/ko/tour.mp4")) == originalHash)
    #expect(try sha(f.root.at("media/ko/tour.mp4")) == originalHash)
    let records = try JSON.read(destination.at("manifest.json"))["recordings"].array
    #expect(Set(records.map { $0["scene"]["appArchiveSHA256"].str }).count == 2)
    #expect(throws: ToolError.self) { try f.bundle.install(source: f.merged, output: destination) }
  }

  @Test
  func changedAssetPreventsAnyInstall() throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    try f.root.at("media/ja/tour.mp4").write("corrupt")
    #expect(throws: ToolError.self) { try f.bundle.install(source: f.merged, output: f.root.at("installed")) }
    #expect(!f.root.at("installed").exists)
  }

  @Test
  func portableVerificationDoesNotPretendToVerifyAbsentCameraOriginals() throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    try fm.removeItem(at: f.root.at("raw"))
    try f.bundle.verify(JSON.read(f.merged), portable: true)
    #expect(throws: (any Error).self) { try f.bundle.verify(JSON.read(f.merged), portable: false) }
  }

  @Test(arguments: ["missing", "duplicate", "wrong-language", "changed-picker"])
  func rejectsIncompleteOrContradictoryBundles(_ fault: String) throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    var bundle = try JSON.read(f.merged)
    var records = bundle["recordings"].array
    switch fault {
    case "missing": records.removeLast()
    case "duplicate": records.append(records[0])
    case "wrong-language": records[0]["translationLanguage"] = .string("ko-KR")
    default: records[0]["scene"]["actionVerification"]["actualLanguagePickerValues"] = .array([])
    }
    bundle["recordings"] = .array(records)
    #expect(throws: ToolError.self) { try f.bundle.verify(bundle, portable: true) }
  }

  @Test
  func resumesCompletedRequestsWithoutLaunchingRecorder() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    let batch = RecordingBatch(workspace: f.workspace)
    let plan = try f.plan()
    for request in try batch.requests(plan) {
      try request.fingerprint.write(f.library.path(request.take["directory"].str).appendingPathExtension("request.json"))
    }
    try plan.write(f.root.at("plan.json"))
    try await batch.record(source: f.root.at("plan.json"), output: f.root.at("results.json"), check: false) { _ in
      Issue.record("Completed takes must not launch a recorder")
    }
    #expect(try JSON.read(f.root.at("results.json"))["results"].array.allSatisfy { $0["status"].str == "resumed" })
  }

  @Test
  func partialTakeIsPreservedWhileOtherLocalesContinue() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    let batch = RecordingBatch(workspace: f.workspace)
    let plan = try f.plan()
    for request in try batch.requests(plan) {
      try request.fingerprint.write(f.library.path(request.take["directory"].str).appendingPathExtension("request.json"))
    }
    try f.root.at("raw/en/tour-01/capture-demo.json").write("incomplete")
    let before = try sha(f.root.at("raw/en/tour-01/capture-demo.mov"))
    try plan.write(f.root.at("plan.json"))
    await #expect(throws: ToolError.self) {
      try await batch.record(source: f.root.at("plan.json"), output: f.root.at("results.json"), check: false) { _ in
        Issue.record("Never overwrite an existing failed take")
      }
    }
    let results = try JSON.read(f.root.at("results.json"))["results"].array
    #expect(results.count(where: { $0["status"].str == "resumed" }) == 4)
    #expect(try sha(f.root.at("raw/en/tour-01/capture-demo.mov")) == before)
  }

  @Test
  func removesQAInjectionEnvironment() async throws {
    let output = try await runProcess(
      ["/usr/bin/env"],
      environment: ["SWIFTYCROW_QA_LIVE_FRAMES": "injected"],
      capture: true,
      removingEnvironment: ["SWIFTYCROW_QA_LIVE_FRAMES"]
    )
    #expect(!output.contains("SWIFTYCROW_QA_LIVE_FRAMES="))
  }

  @Test
  func completedExportsResumeButChangedBytesFail() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.library.select(source: f.decisions, output: f.selected)
    for take in try f.library.selected(f.selected, reviewed: true) {
      let file = try f.root.at("media/" + f.library.key(take) + ".json")
      try JSON.read(file).merging([("selection", take)]).write(file)
    }
    let before = try sha(f.root.at("media/en/tour.mp4"))
    try await f.library.export(source: f.selected, output: f.root.at("media"))
    #expect(try sha(f.root.at("media/en/tour.mp4")) == before)
    try f.root.at("media/en/tour.mp4").write("changed")
    await #expect(throws: ToolError.self) { try await f.library.export(source: f.selected, output: f.root.at("media")) }
  }

  @Test
  func recordsFreshRequestsAndAllowsMutableAppConfigOnResume() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    var plan = try f.plan()
    let originals = plan["takes"].array
    plan["takes"] = .array(originals.map { $0.merging([("directory", .string("new/" + $0["locale"].str))]) })
    try plan.write(f.root.at("plan.json"))
    let batch = RecordingBatch(workspace: f.workspace)
    var launches = 0
    try await batch.record(source: f.root.at("plan.json"), output: f.root.at("report.json"), check: false) { argv in
      let localeIndex = try #require(argv.firstIndex(of: "--locale"))
      let outputIndex = try #require(argv.firstIndex(of: "--output"))
      let locale = argv[localeIndex + 1]
      try copy(f.root.at("raw/" + locale + "/tour-01"), URL(fileURLWithPath: argv[outputIndex + 1]))
      launches += 1
    }
    #expect(launches == 5)
    try f.root.at("inputs/config").write("updated by app language selection")
    try await batch.record(source: f.root.at("plan.json"), output: f.root.at("report.json"), check: false) { _ in
      Issue.record("Mutable app config should not invalidate completed takes")
    }
    try f.root.at("inputs/demoqa").write("changed executable")
    await #expect(throws: ToolError.self) {
      try await batch.record(source: f.root.at("plan.json"), output: f.root.at("report.json"), check: false) { _ in
        Issue.record("Changed tools must not reuse or overwrite an old take")
      }
    }
  }

  @Test
  func planCheckDoesNotLaunchOrCreateTakeDirectories() async throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    var plan = try f.plan()
    plan["takes"] = .array(plan["takes"].array.map { $0.merging([("directory", .string("new/" + $0["locale"].str))]) })
    try plan.write(f.root.at("plan.json"))
    try await RecordingBatch(workspace: f.workspace).record(
      source: f.root.at("plan.json"),
      output: f.root.at("report.json"),
      check: true
    ) { _ in
      Issue.record("Plan validation must not launch the recorder")
    }
    #expect(!f.root.at("new").exists)
    #expect(try JSON.read(f.root.at("report.json"))["requests"].array.count == 5)
  }

  @Test
  func partialSelectionRequiresBaseAndRetainsUnselectedApprovedFilms() throws {
    let f = try ReviewFixture()
    defer { try? fm.removeItem(at: f.root) }
    try f.assemble()
    let base = try JSON.read(f.merged)
    let takes = try JSON.read(f.decisions)["takes"].array.filter { $0["locale"].str == "ja" }
    try JSON.object([("takes", .array(takes))]).write(f.root.at("partial-decisions.json"))
    try f.library.select(source: f.root.at("partial-decisions.json"), output: f.root.at("partial-selection.json"))
    #expect(throws: ToolError.self) {
      try f.bundle.merge(
        selection: f.root.at("partial-selection.json"),
        mediaRoot: f.root.at("media"),
        output: f.root.at("partial.json")
      )
    }
    #expect(!f.root.at("partial.json").exists)
    try f.bundle.merge(
      selection: f.root.at("partial-selection.json"),
      mediaRoot: f.root.at("media"),
      output: f.root.at("combined.json"),
      base: f.merged
    )
    let records = try JSON.read(f.root.at("combined.json"))["recordings"].array
    #expect(records.count == 5)
    for record in records where record["uiLanguage"].str != "ja" {
      #expect(base["recordings"].array.contains(record))
    }
  }

}
