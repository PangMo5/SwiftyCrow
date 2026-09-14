// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CryptoKit
import DemoDriverKit
import Foundation

// MARK: - QAError

struct QAError: Error, CustomStringConvertible {
  init(_ description: String) {
    self.description = description
  }

  let description: String
}

// MARK: - ScenarioManifest

struct ScenarioManifest: Decodable {
  let version: Int
  let films: [String: FilmScenario]
}

// MARK: - FilmScenario

struct FilmScenario: Decodable {
  let sources: [ScenarioSource]
  let targetLanguage: String
  let noteHeading: String?
  let originalReadingOrder: [String]?
  let translationWindowFrame: [Double]?
}

// MARK: - ScenarioSource

struct ScenarioSource: Decodable, Equatable {
  let id: String
  let kind: String
  let asset: String?
  let scene: String?
  let bundleID: String
  let language: String
  let windowFrame: [Double]
  let selectionFrame: [Double]
  let expectedOriginal: [String]
  let expectedTranslation: [String]
  let changedOriginal: [String]?
  let changedTranslation: [String]?
  let laterOriginal: [String]?
  let laterTranslation: [String]?
}

// MARK: - PreparedNativeSource

struct PreparedNativeSource {
  let source: ScenarioSource
  let processID: pid_t
  let windowFrame: CGRect
  let canvasFrame: CGRect
  let windowDescription: String
}

func scenarioRect(_ values: [Double]) throws -> CGRect {
  guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else {
    throw QAError("Invalid scenario rectangle")
  }
  return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
}

// MARK: - Arguments

struct Arguments {

  // MARK: Lifecycle

  init(_ arguments: [String]) throws {
    command = arguments.first ?? "help"
    var values = [String: String]()
    var index = 1
    while index < arguments.count {
      let key = arguments[index]
      guard key.hasPrefix("--"), index + 1 < arguments.count else {
        throw QAError("Expected --option value, got \(key)")
      }
      values[String(key.dropFirst(2))] = arguments[index + 1]
      index += 2
    }
    self.values = values
  }

  // MARK: Internal

  let command: String
  let values: [String: String]

  func required(_ key: String) throws -> String {
    guard let value = values[key], !value.isEmpty else { throw QAError("Missing --\(key)") }
    return value
  }
}

func writeJSON(_ value: Any, to url: URL) throws {
  try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    .write(to: url, options: .atomic)
}

func digest(_ url: URL) throws -> String {
  SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}

@discardableResult
func run(_ executable: String, _ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = String(decoding: data, as: UTF8.self)
  guard process.terminationStatus == 0 else {
    throw QAError("\(executable) exited \(process.terminationStatus): \(text)")
  }
  return text
}

func pause(_ seconds: TimeInterval) {
  Thread.sleep(forTimeInterval: seconds)
}

// MARK: - SceneDriver

@MainActor
final class SceneDriver {

  // MARK: Lifecycle

  init(_ args: Arguments) throws {
    appURL = URL(fileURLWithPath: try args.required("app"))
    guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else { throw QAError("Invalid app bundle") }
    self.bundleID = bundleID
    language = try args.required("locale")
    guard let locale = ["en": "en_US", "ko": "ko_KR", "ja": "ja_JP", "zh-Hans": "zh_CN", "zh-Hant": "zh_TW"][language] else {
      throw QAError("Unsupported UI locale: \(language)")
    }
    self.locale = locale
    output = URL(fileURLWithPath: try args.required("output"), isDirectory: true)
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw QAError("Refusing to overwrite an existing QA output directory")
    }
    source = URL(fileURLWithPath: try args.required("source"))
    catalogURL = URL(fileURLWithPath: try args.required("catalog"))
    guard
      let document = try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any],
      let strings = document["strings"] as? [String: Any]
    else { throw QAError("Invalid string catalog") }
    catalog = strings
    appArchive = args.values["archive"].map { URL(fileURLWithPath: $0) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
  }

  // MARK: Internal

  let appURL: URL
  let bundleID: String
  let language: String
  let locale: String
  let output: URL
  let source: URL
  let catalogURL: URL
  let catalog: [String: Any]
  let appArchive: URL?
  var events = [[String: Any]]()
  var sceneStart = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
  var recording: Process?
  var settingsAbsenceChecks = 0
  var zoomVerification = [String: String]()
  var translationTarget = "ko-KR"
  var translationSource = "en-US"
  var sceneMode = "collect"
  var recorderSHA256: String?
  var requestedCodec = "hevc"
  var bitrateMbps = "automatic"
  var film: String?
  var actionVerification = [String: Any]()
  var sourceAssets = [String: String]()
  var scenario: FilmScenario?
  var scenariosURL: URL?
  var sourceAppURL: URL?
  var activeSource: ScenarioSource?
  var preparedSecondarySource: PreparedNativeSource?
  var configuredShortcuts = [String: String]()
  var keystrokes = [[String: Any]]()
  var narration = [[String: Any]]()
  var recordingEpoch: UInt64?
  var noteHeading = ""
  let sourceWindowFrame = CGRect(x: 80, y: 60, width: 1760, height: 1000)
  let selectionFrame = CGRect(x: 180, y: 250, width: 1560, height: 570)

  func label(_ key: String) throws -> String {
    guard
      let entry = catalog[key] as? [String: Any],
      let translations = entry["localizations"] as? [String: Any],
      let localized = translations[language] as? [String: Any],
      let unit = localized["stringUnit"] as? [String: Any],
      let value = unit["value"] as? String
    else { throw QAError("Missing \(language) string: \(key)") }
    return value
  }

  func snapshot() throws -> String {
    try NativeInteractionDriver.snapshot(bundleIdentifier: bundleID)
  }

  func event(_ name: String) {
    events.append([
      "seconds": Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - sceneStart,
      "event": name,
      "utc": Date.now.ISO8601Format(),
    ])
    print(name)
    fflush(stdout)
  }

  @discardableResult
  func observe(_ name: String, png: Bool = true) throws -> String {
    let text = try snapshot()
    try text.write(to: output.appendingPathComponent(name + "-ax.txt"), atomically: true, encoding: .utf8)
    // ScreenCaptureKit is the only capture path used during a take. Extra PNG
    // capture sessions are deferred until recording has finalized.
    if png, recording == nil {
      try run("/usr/sbin/screencapture", ["-x", output.appendingPathComponent(name + ".png").path])
    }
    return text
  }

  func waitFor(_ description: String, timeout: Double = 5, _ predicate: (String) -> Bool) throws -> String {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while true {
      let text = try snapshot()
      if predicate(text) { return text }
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("Timed out waiting for \(description)") }
      pause(0.1)
    }
  }

  func click(_ identifier: String) throws {
    try NativeInteractionDriver.click(bundleIdentifier: bundleID, identifier: identifier)
    pause(0.2)
  }

  func press(_ chord: String) throws {
    var notes = [String]()
    let start = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - sceneStart
    try KeyDriver.press(ChordParser.parse(chord, notes: &notes), holdMilliseconds: 24)
    keystrokes.append(["seconds": start, "chord": chord, "holdMilliseconds": 24, "source": "actual KeyDriver key events"])
  }

  func launch() throws {
    let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    for app in existing { guard app.terminate() else { throw QAError("App refused normal termination") } }
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("Previous app is still running") }
      pause(0.1)
    }
    try run("/usr/bin/open", ["-na", appURL.path, "--args", "-AppleLanguages", "(\(language))", "-AppleLocale", locale])
    let appeared = ProcessInfo.processInfo.systemUptime + 5
    while NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty {
      guard ProcessInfo.processInfo.systemUptime < appeared else { throw QAError("App did not launch") }
      pause(0.1)
    }
    pause(0.4)
    try writeScene()
  }

  func settingsAbsent() throws {
    guard !(try snapshot()).contains("AXWindow AXIdentifier=settings") else {
      throw QAError("Settings window is present; hiding it is not sufficient for recording")
    }
    settingsAbsenceChecks += 1
  }

  func closeSettings() throws {
    if try snapshot().contains("AXWindow AXIdentifier=settings") {
      try NativeInteractionDriver.closeWindow(bundleIdentifier: bundleID, identifier: "settings")
      _ = try waitFor("Settings window to close") { !$0.contains("AXWindow AXIdentifier=settings") }
    }
    try settingsAbsent()
  }

  func collect() throws {
    try launch()
    try click("title:SwiftyCrow")
    _ = try observe("menu")
    try click("button:" + label("Settings"))
    _ = try waitFor("Settings after center click") { $0.contains("AXWindow AXIdentifier=settings") }
    if try snapshot().contains("AXDescription=" + label("Capture Region")) { try click("title:SwiftyCrow") }
    for key in ["General", "Languages", "Translation", "Overlay", "Shortcuts", "Updates", "About"] {
      try click("text:" + label(key))
      _ = try observe("settings-" + key.lowercased())
    }
    try closeSettings()
    _ = try observe("settings-closed")
    try writeScene()
  }

  func writeScene() throws {
    if let hostInput = try NativeInteractionDriver.hostInputSessionMetadata() {
      actionVerification["hostInput"] = hostInput
      try writeJSON(hostInput, to: output.appendingPathComponent("host-input.json"))
    }
    let executable = appURL.appendingPathComponent("Contents/MacOS/SwiftyCrow")
    var sourceAppDigest = "not used"
    if let sourceAppURL {
      guard let executable = Bundle(url: sourceAppURL)?.executableURL else { throw QAError("Invalid source app") }
      sourceAppDigest = try digest(executable)
    }
    var notRecorded = film == nil
      ? ["scroll", "manual resize", "dismiss", "live overlay"]
      : ["initial source and blank note preparation", "primary translation prewarming"]
    if film == "tour" { notRecorded.append("secondary source launch, geometry preparation, and hiding") }
    if
      film ==
      "compare" { notRecorded.append("native separate window preparation, In-place restoration, hiding, and source reset") }
    try writeJSON([
      "uiLanguage": language,
      "appleLocale": locale,
      "film": film ?? "legacy-capture",
      "translationSource": translationSource,
      "translationTarget": translationTarget,
      "launchArguments": ["-AppleLanguages", "(\(language))", "-AppleLocale", locale],
      "appPath": appURL.path,
      "appExecutableSHA256": try digest(executable),
      "appDebugDylibSHA256": try digest(appURL.appendingPathComponent("Contents/MacOS/SwiftyCrow.debug.dylib")),
      "appArchivePath": appArchive?.path ?? "not provided",
      "appArchiveSHA256": try appArchive.map(digest) ?? "not provided",
      "sourceSHA256": try digest(source),
      "catalogSHA256": try digest(catalogURL),
      "sourceWindowFrame": film == nil
        ? NSStringFromRect(sourceWindowFrame)
        : (actionVerification["primarySourceWindowFrame"] as? String ?? "not yet positioned"),
      "selectionFrame": film == nil ? NSStringFromRect(selectionFrame) : "See actionVerification for each actual selection",
      "guestLogicalProcessorCount": ProcessInfo.processInfo.processorCount,
      "guestPhysicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
      "demoqaExecutableSHA256": try digest(URL(fileURLWithPath: CommandLine.arguments[0])),
      "recorderExecutableSHA256": recorderSHA256 ?? "not used",
      "requestedCodec": requestedCodec,
      "bitrateMbps": bitrateMbps,
      "sceneMode": sceneMode,
      "orchestration": "Swift demoqa",
      "settingsWindowPolicy": "Close actual window and assert absence before/after capture",
      "settingsAbsenceChecksPassed": settingsAbsenceChecks,
      "zoomVerification": zoomVerification,
      "actionVerification": actionVerification,
      "sourceAssets": sourceAssets,
      "scenariosSHA256": try scenariosURL.map(digest) ?? "not used",
      "sourceAppPath": sourceAppURL?.path ?? "not used",
      "sourceAppExecutableSHA256": sourceAppDigest,
      "recordingFirstFrameUptimeNanoseconds": recordingEpoch.map(String.init) ?? "not recorded",
      "timelineClock": "DispatchTime uptime relative to first encoded frame",
      "configuredShortcuts": configuredShortcuts,
      "recordedTransitions": sceneMode == "record" ? events.compactMap { $0["event"] as? String } : [],
      "notRecorded": notRecorded,
    ], to: output.appendingPathComponent("scene.json"))
    let destination = output.appendingPathComponent(film == nil ? "source-sample.html" : "source-manifest.json")
    if !FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.copyItem(at: source, to: destination) }
  }

  func capture(_ args: Arguments) throws {
    let mode = args.values["mode"] ?? "preview"
    guard ["preview", "record", "error"].contains(mode) else { throw QAError("Invalid capture mode") }
    let movie = output.appendingPathComponent("capture-demo.mov")
    sceneMode = mode
    requestedCodec = args.values["codec"] ?? "hevc"
    guard ["hevc", "h264"].contains(requestedCodec) else { throw QAError("--codec expects hevc or h264") }
    bitrateMbps = args.values["bitrate-mbps"] ?? "automatic"
    if mode == "record" { recorderSHA256 = try digest(URL(fileURLWithPath: try args.required("recorder"))) }
    if mode == "error" { translationTarget = "ja-JP" }
    try launch()
    try closeSettings()
    if try snapshot().contains("AXIdentifier=xmark ") { try click("xmark") }
    try settingsAbsent()
    try run("/usr/bin/open", ["-a", "Safari", source.path])
    pause(0.4)
    try NativeInteractionDriver.snapshot(bundleIdentifier: "com.apple.Safari")
      .write(to: output.appendingPathComponent("source-before-layout-ax.txt"), atomically: true, encoding: .utf8)
    _ = try NativeInteractionDriver.arrangeMainWindow(bundleIdentifier: "com.apple.Safari", frame: sourceWindowFrame)
    try press("cmd - 0")
    try press("cmd - r")
    pause(0.5)
    try NativeInteractionDriver.snapshot(bundleIdentifier: "com.apple.Safari")
      .write(to: output.appendingPathComponent("source-layout-ax.txt"), atomically: true, encoding: .utf8)
    let config = URL(fileURLWithPath: try args.required("config"))
    let oldConfig = try String(contentsOf: config, encoding: .utf8)
    if mode == "error" {
      let errorConfig = oldConfig.replacingOccurrences(of: "ko-KR", with: "ja-JP")
        .replacingOccurrences(of: "ko-Kore-KR", with: "ja-Jpan-JP")
      guard errorConfig != oldConfig else { throw QAError("Expected Korean translation target in demo config") }
      try errorConfig.write(to: config, atomically: true, encoding: .utf8)
      pause(0.6)
    }
    defer { if mode == "error" { try? oldConfig.write(to: config, atomically: true, encoding: .utf8) } }
    _ = try observe("source-ready")
    try settingsAbsent()
    sceneStart = ProcessInfo.processInfo.systemUptime
    let pidfile = output.appendingPathComponent("capture-demo.pid")
    var logHandle: FileHandle?
    defer {
      if let process = recording {
        if process.isRunning { process.interrupt() }
        process.waitUntilExit()
        recording = nil
      }
      try? logHandle?.close()
      try? writeJSON(events, to: output.appendingPathComponent("timeline.json"))
      try? writeScene()
    }
    if mode == "record" {
      let recorder = try args.required("recorder")
      let log = output.appendingPathComponent("capture-demo.log")
      FileManager.default.createFile(atPath: log.path, contents: nil)
      logHandle = try FileHandle(forWritingTo: log)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: recorder)
      process.arguments = [
        "--output",
        movie.path,
        "--fps",
        args.values["fps"] ?? "30",
        "--duration-seconds",
        "45",
        "--pidfile",
        pidfile.path,
      ]
      process.arguments?.append(contentsOf: ["--codec", requestedCodec])
      if let bitrate = args.values["bitrate-mbps"] { process.arguments?.append(contentsOf: ["--bitrate-mbps", bitrate]) }
      process.standardOutput = logHandle
      process.standardError = logHandle
      try process.run()
      recording = process
      let deadline = ProcessInfo.processInfo.systemUptime + 8
      while !FileManager.default.fileExists(atPath: pidfile.path) {
        guard
          process.isRunning,
          ProcessInfo.processInfo.systemUptime < deadline
        else { throw QAError("Recorder did not encode a first frame") }
        pause(0.1)
      }
      event("recording ready")
      pause(1)
    }
    try press("cmd + shift - 1")
    event("capture shortcut")
    _ = try observe("selector")
    try settingsAbsent()
    try NativeInteractionDriver.drag(from: selectionFrame.origin, to: CGPoint(x: selectionFrame.maxX, y: selectionFrame.maxY))
    event("region selected")
    let expected = mode == "error"
      ? [try label("Translation unavailable")]
      : [
        "도시의 조용한 오후",
        "도서관은 오늘 저녁 6시까지 열려 있습니다.",
        "좋아하는 책을 가져오시고 차 한 잔을 즐기세요.",
        "모든 방문객을 환영합니다.",
      ]
    _ = try waitFor("real capture output", timeout: 25) { text in expected.allSatisfy(text.contains) }
    try settingsAbsent()
    event("real UI verified")
    _ = try observe(mode == "error" ? "error" : "translated")
    if mode != "error" {
      let fit = try label("Fit image (⌘0)")
      let frontmostBeforeFit = NativeInteractionDriver.frontmostBundleIdentifier() ?? "unknown"
      guard
        let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
        app.activate()
      else { throw QAError("Could not activate capture result") }
      pause(0.3)
      event("capture result activated (previous frontmost: \(frontmostBeforeFit))")
      // The initial image zoom can differ from explicit Fit after the result
      // window settles. Establish the command's own baseline before zooming.
      try click("help:" + fit)
      let baseline = try observe("fit-baseline")
      guard let original = baseline.split(separator: "\n").first(where: { $0.contains("AXHelp=" + fit) }) else {
        throw QAError("Fit control missing")
      }
      zoomVerification["explicitFitBaselineAX"] = String(original)
      let baselineScrollbars = baseline.split(separator: "\n").count(where: { $0.contains("AXScrollBar") })
      zoomVerification["baselineScrollbarCount"] = String(baselineScrollbars)
      event("explicit Fit baseline verified")
      try click("plus.magnifyingglass")
      let zoomed = try observe("zoom-in")
      guard !zoomed.split(separator: "\n").contains(original) else { throw QAError("Zoom did not change percentage") }
      event("zoom in verified")
      try click("help:" + fit)
      let fitted = try observe("fit")
      zoomVerification["afterZoomAX"] = zoomed.split(separator: "\n").first(where: { $0.contains("AXHelp=" + fit) })
        .map(String.init)
      zoomVerification["finalFitAX"] = fitted.split(separator: "\n").first(where: { $0.contains("AXHelp=" + fit) })
        .map(String.init)
      let finalScrollbars = fitted.split(separator: "\n").count(where: { $0.contains("AXScrollBar") })
      zoomVerification["finalScrollbarCount"] = String(finalScrollbars)
      guard fitted.split(separator: "\n").contains(original) else { throw QAError("Fit did not restore percentage") }
      guard finalScrollbars == baselineScrollbars
      else { throw QAError("Fit left different scrollbar visibility than its baseline") }
      try settingsAbsent()
      event("percentage Fit verified")
      try Pointer.warp(toDisplayIndex: 0, unitX: 0.8, unitY: 0.75)
      if mode == "record" { pause(5) }
    }
    if let process = recording {
      process.interrupt()
      process.waitUntilExit()
      recording = nil
      guard process.terminationStatus == 0 else { throw QAError("Recorder failed") }
      _ = try observe("independent-fit-after-recording")
    }
    try settingsAbsent()
  }
}

extension SceneDriver {

  // MARK: Internal

  func story(_ args: Arguments) throws {
    let selectedFilm = try args.required("film")
    scenariosURL = URL(fileURLWithPath: try args.required("scenarios"))
    let manifest = try JSONDecoder().decode(ScenarioManifest.self, from: Data(contentsOf: scenariosURL!))
    guard
      manifest.version == 1, let scenario = manifest.films[selectedFilm], let primary = scenario.sources.first,
      ["tour", "capture", "live", "layout", "compare"].contains(selectedFilm)
    else { throw QAError("Invalid film scenario") }
    self.scenario = scenario
    film = selectedFilm
    translationSource = primary.language
    translationTarget = scenario.targetLanguage
    guard scenario.sources.allSatisfy({ $0.language == translationSource })
    else { throw QAError("A film must use one verified language pair") }
    sourceAppURL = args.values["source-app"].map { URL(fileURLWithPath: $0) }
    noteHeading = scenario.noteHeading ?? "Japanese magazine\nRecognized reading order\n\n"
    sceneMode = args.values["mode"] ?? "preview"
    guard ["preview", "record"].contains(sceneMode) else { throw QAError("Story mode must be preview or record") }
    requestedCodec = args.values["codec"] ?? "hevc"
    bitrateMbps = args.values["bitrate-mbps"] ?? "8"
    guard
      let assetManifest = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any],
      let files = assetManifest["files"] as? [String: String], !files.isEmpty
    else { throw QAError("Invalid fixture manifest") }
    sourceAssets = files
    for (path, expected) in files where path.hasPrefix("Fixtures/") {
      guard !path.contains("..") else { throw QAError("Invalid fixture path") }
      let asset = source.deletingLastPathComponent().appendingPathComponent(String(path.dropFirst("Fixtures/".count)))
      guard try digest(asset) == expected else { throw QAError("Fixture source hash mismatch: \(path)") }
    }
    try configureScenario(args, scenario: scenario)
    try launch()
    try verifyLanguagePair()
    for bundle in ["com.apple.Safari", "com.apple.TextEdit", "com.apple.Preview"] { try closeFixtureWindows(bundle) }
    if let sourceAppURL, let sourceBundle = Bundle(url: sourceAppURL)?.bundleIdentifier {
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: sourceBundle) { app.terminate() }
    }
    if ["tour", "layout"].contains(selectedFilm) { try prepareNote() }
    if selectedFilm == "tour" {
      guard let secondary = scenario.sources.dropFirst().first else { throw QAError("Tour requires live secondary source") }
      try prepareSecondarySource(secondary)
    }
    try openSource(primary)
    if sceneMode == "record" {
      try selectSource(primary, live: false, stage: "prewarm", narrationID: nil)
      try click("xmark")
      try activate(primary.bundleID)
    }
    if selectedFilm == "compare" { try prepareCompareWindow(primary) }
    try settingsAbsent()
    _ = try observe("source-ready")
    sceneStart = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    events = []
    keystrokes = []
    narration = []
    var log: FileHandle?
    defer {
      if let process = recording {
        if process.isRunning { process.interrupt() }
        process.waitUntilExit()
        recording = nil
      }
      try? log?.close()
      try? writeJSON(events, to: output.appendingPathComponent("timeline.json"))
      try? writeJSON(keystrokes, to: output.appendingPathComponent("keystrokes.json"))
      try? writeJSON(narration, to: output.appendingPathComponent("narration.json"))
      try? writeScene()
    }
    if sceneMode == "record" {
      let recorder = try args.required("recorder")
      recorderSHA256 = try digest(URL(fileURLWithPath: recorder))
      let pidfile = output.appendingPathComponent("capture-demo.pid")
      let ready = pidfile.deletingPathExtension().appendingPathExtension("ready.json")
      let logURL = output.appendingPathComponent("capture-demo.log")
      FileManager.default.createFile(atPath: logURL.path, contents: nil)
      log = try FileHandle(forWritingTo: logURL)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: recorder)
      process.arguments = [
        "--output",
        output.appendingPathComponent("capture-demo.mov").path,
        "--fps",
        args.values["fps"] ?? "30",
        "--duration-seconds",
        "120",
        "--pidfile",
        pidfile.path,
        "--codec",
        requestedCodec,
        "--bitrate-mbps",
        bitrateMbps,
      ]
      process.standardOutput = log
      process.standardError = log
      try process.run()
      recording = process
      let deadline = ProcessInfo.processInfo.systemUptime + 10
      while !FileManager.default.fileExists(atPath: ready.path) {
        guard
          process.isRunning,
          ProcessInfo.processInfo.systemUptime < deadline
        else { throw QAError("Recorder did not encode its first frame") }
        pause(0.1)
      }
      guard
        let data = try JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Any],
        let epoch = data["firstFrameUptimeNanoseconds"] as? NSNumber
      else { throw QAError("Recorder ready metadata lacks first-frame clock") }
      recordingEpoch = epoch.uint64Value
      sceneStart = epoch.doubleValue / 1_000_000_000
      event("recording ready")
    }
    do {
      cue(selectedFilm + ".intro")
      if sceneMode == "record" { pause(2) }
      switch selectedFilm {
      case "tour":
        try selectSource(primary, live: false, stage: "capture", narrationID: "tour.capture")
        if sceneMode == "record" { pause(2) }
        let text = try copyText(
          original: false,
          expected: primary.expectedTranslation,
          stage: "copiedTranslation",
          narrationID: "tour.copy"
        )
        try pasteIntoNote(text, narrationID: "tour.paste")
        guard let secondary = scenario.sources.dropFirst().first else { throw QAError("Tour requires live secondary source") }
        try activatePreparedSecondarySource(secondary)
        try selectSource(secondary, live: true, stage: "live", narrationID: "tour.live")
        guard let changed = secondary.changedTranslation else { throw QAError("Missing departure update") }
        try changeNativeSource(
          secondary,
          control: "play",
          expected: changed,
          absent: [],
          stage: "departure-update",
          narrationID: "tour.changed"
        )
        if sceneMode == "record" { pause(3) }

      case "capture":
        try selectSource(primary, live: false, stage: "capture", narrationID: "capture.select")
        cue("capture.translated")
        if sceneMode == "record" { pause(3) }
        try pasteImageIntoPreview()

      case "layout":
        try selectSource(primary, live: false, stage: "layout", narrationID: "layout.select")
        cue("layout.translated")
        if sceneMode == "record" { pause(3) }
        let text = try copyText(
          original: true,
          expected: primary.expectedOriginal,
          stage: "copiedOriginal",
          narrationID: "layout.copy"
        )
        guard
          let order = scenario.originalReadingOrder,
          order.count > 1
        else { throw QAError("Layout requires explicit original reading order") }
        let normalizedText = normalized(text)
        var remaining = normalizedText.startIndex
        for fragment in order {
          guard let match = normalizedText.range(of: normalized(fragment), range: remaining..<normalizedText.endIndex) else {
            actionVerification["originalReadingOrderFailure"] = fragment
            throw QAError("Actual Copy Original does not preserve reading order at: \(fragment)")
          }
          remaining = match.upperBound
        }
        actionVerification["originalReadingOrderVerified"] = true
        actionVerification["originalReadingOrder"] = scenario.originalReadingOrder ?? []
        try pasteIntoNote(text, narrationID: "layout.order")

      case "live":
        try selectSource(primary, live: true, stage: "live", narrationID: "live.select")
        guard
          let changed = primary.changedTranslation,
          let later = primary.laterTranslation
        else { throw QAError("Science source requires three phases") }
        try changeNativeSource(
          primary,
          control: "play",
          expected: changed,
          absent: [],
          stage: "science-second",
          narrationID: "live.play"
        )
        cue("live.second")
        _ = try waitFor("third science subtitle", timeout: 20) { later.allSatisfy($0.contains) }
        cue("live.third")
        actionVerification["scienceThirdCaptionVerified"] = true
        _ = try observe("science-third")
        if sceneMode == "record" { pause(3) }

      case "compare":
        try selectSource(primary, live: true, stage: "live", narrationID: "compare.select")
        if sceneMode == "record" { pause(2) }
        try compareLiveModes(primary)

      default: throw QAError("Unreachable film")
      }
      try settingsAbsent()
      if let process = recording {
        if let last = narration.last?["seconds"] as? Double {
          let elapsed = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - sceneStart - last
          if elapsed < 2.6 { pause(2.6 - elapsed) }
        }
        process.interrupt()
        process.waitUntilExit()
        recording = nil
        guard process.terminationStatus == 0 else { throw QAError("Recorder failed") }
        try writePresentation()
      }
      _ = try observe("independent-final-after-recording")
      actionVerification["storyCompleted"] = true
      if selectedFilm == "compare" {
        try showStoryMenu()
        try click("description:" + label("In-place"))
        try closeStoryMenu()
        actionVerification["postTakeDisplayModeRestored"] = true
      }
    } catch {
      actionVerification["storyFailure"] = String(describing: error)
      _ = try? observe("story-failed")
      throw error
    }
  }

  // MARK: Private

  private func activate(_ bundle: String) throws {
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first,
      app.activate()
    else { throw QAError("Could not activate \(bundle)") }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while NativeInteractionDriver.frontmostBundleIdentifier() != bundle {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("App did not become frontmost: \(bundle)") }
      pause(0.1)
    }
    pause(0.3)
  }

  private func cue(_ id: String) {
    var seconds = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - sceneStart
    if sceneMode == "record", let previous = narration.last?["seconds"] as? Double, seconds - previous < 2.4 {
      pause(2.4 - (seconds - previous))
      seconds = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 - sceneStart
    }
    let cueSeconds: Double = narration.isEmpty ? 0 : seconds
    narration.append(["seconds": cueSeconds, "id": id])
    event("narration: " + id)
  }

  private func writePresentation() throws {
    guard let film, let scenariosURL, let recordingEpoch else { return }
    let statsURL = output.appendingPathComponent("capture-demo.json")
    guard
      let stats = try JSONSerialization.jsonObject(with: Data(contentsOf: statsURL)) as? [String: Any],
      stats["status"] as? String == "ok", let duration = stats["durationSeconds"] as? Double
    else {
      throw QAError("Recorder did not finalize successful duration statistics")
    }
    var tracks: [[String: Any]]
    if film == "capture" {
      guard
        let openingStart = actionVerification["previewPasteOpeningStartSeconds"] as? Double,
        let openingEnd = actionVerification["previewPasteOpeningEndSeconds"] as? Double,
        openingStart.isFinite, openingEnd.isFinite,
        openingStart > 0, openingEnd > openingStart, openingEnd < duration
      else { throw QAError("Preview opening interval is outside the recording") }
      tracks = [
        ["track": "chapter", "id": film + ".chapter", "start": 0, "end": openingStart],
        ["track": "chapter", "id": film + ".chapter", "start": openingEnd, "end": duration],
      ]
    } else {
      tracks = [["track": "chapter", "id": film + ".chapter", "start": 0, "end": duration]]
    }
    for (index, cue) in narration.enumerated() {
      guard let start = cue["seconds"] as? Double, let id = cue["id"] as? String else { throw QAError("Invalid narration cue") }
      let end = index + 1 < narration.count ? narration[index + 1]["seconds"] as! Double : duration
      guard end - start >= 2.4 else { throw QAError("Caption too short: \(id)") }
      tracks.append(["track": "caption", "id": id, "start": start, "end": end])
    }
    // Caret positioning remains in the actual input evidence but is not a demonstrated product shortcut.
    let shownKeystrokes = keystrokes.filter { $0["chord"] as? String != "cmd - down" }
    for (index, key) in shownKeystrokes.enumerated() {
      guard let start = key["seconds"] as? Double, let chord = key["chord"] as? String, start >= 0, start < duration else {
        throw QAError("Actual keystroke is outside recorded duration")
      }
      let next = index + 1 < shownKeystrokes.count ? shownKeystrokes[index + 1]["seconds"] as! Double : duration
      tracks.append(["track": "keys", "chord": chord, "start": start, "end": min(start + 2, next, duration)])
    }
    try writeJSON([
      "schemaVersion": 1,
      "film": film,
      "uiLanguage": language,
      "captureEpochUptimeNanoseconds": recordingEpoch,
      "scenariosSHA256": try digest(scenariosURL),
      "durationSeconds": duration,
      "events": tracks,
    ], to: output.appendingPathComponent("presentation.json"))
    print("final recorded duration: \(duration)")
  }

  private func closeFixtureWindows(_ bundle: String) throws {
    guard !NSRunningApplication.runningApplications(withBundleIdentifier: bundle).isEmpty else { return }
    for _ in 0..<12 {
      let before = try NativeInteractionDriver.snapshot(bundleIdentifier: bundle)
      if !before.split(separator: "\n").contains(where: { $0.hasPrefix(" AXWindow ") }) { return }
      try activate(bundle)
      if before.contains("AXIdentifier=DontSaveButton") {
        try NativeInteractionDriver.click(bundleIdentifier: bundle, identifier: "DontSaveButton")
      } else {
        try NativeInteractionDriver.closeMainWindow(bundleIdentifier: bundle)
      }
      pause(0.3)
      let after = try NativeInteractionDriver.snapshot(bundleIdentifier: bundle)
      if after.contains("AXIdentifier=DontSaveButton") {
        try NativeInteractionDriver.click(bundleIdentifier: bundle, identifier: "DontSaveButton")
        pause(0.3)
      }
    }
    throw QAError("Fixture windows did not close: \(bundle)")
  }

  private func fixture(_ name: String) throws -> URL {
    guard !name.contains("/"), name != ".." else { throw QAError("Invalid fixture name") }
    let url = source.deletingLastPathComponent().appendingPathComponent(name)
    guard let expected = sourceAssets["Fixtures/" + name], try digest(url) == expected else {
      throw QAError("Fixture hash mismatch: \(name)")
    }
    return url
  }

  private func openSource(_ item: ScenarioSource) throws {
    activeSource = item
    switch item.kind {
    case "image":
      guard let name = item.asset else { throw QAError("Image source requires asset") }
      try run("/usr/bin/open", ["-a", "Preview", try fixture(name).path])
      pause(0.5)
      try activate(item.bundleID)
      guard try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID).contains("AXTitle=" + name) else {
        throw QAError("Preview did not open \(name)")
      }
      let actual = try NativeInteractionDriver.arrangeMainWindow(
        bundleIdentifier: item.bundleID,
        frame: scenarioRect(item.windowFrame)
      )
      // Preview's real Zoom to Fit shortcut. Cmd+0 is Actual Size in Preview.
      try press("cmd - 9")
      pause(0.8)
      actionVerification[item.id + "SourceWindowFrame"] = NSStringFromRect(actual)

    case "native":
      guard
        let sourceAppURL, let scene = item.scene,
        Bundle(url: sourceAppURL)?.bundleIdentifier == item.bundleID
      else { throw QAError("Native source app does not match scenario") }
      for app in NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID) { app.terminate() }
      let deadline = ProcessInfo.processInfo.systemUptime + 5
      while !NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).isEmpty {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("Previous source app did not terminate") }
        pause(0.1)
      }
      try run(
        "/usr/bin/open",
        ["-na", sourceAppURL.path, "--args", "--scene", scene, "--fixtures", source.deletingLastPathComponent().path]
      )
      pause(0.7)
      try activate(item.bundleID)
      let actual = try NativeInteractionDriver.arrangeMainWindow(
        bundleIdentifier: item.bundleID,
        frame: scenarioRect(item.windowFrame)
      )
      try NativeInteractionDriver.click(bundleIdentifier: item.bundleID, identifier: "reset")
      pause(0.3)
      let canvas = try NativeInteractionDriver.controlFrame(bundleIdentifier: item.bundleID, identifier: "source-canvas")
      actionVerification[item.id + "SourceWindowFrame"] = NSStringFromRect(actual)
      actionVerification[item.id + "SourceCanvasFrame"] = NSStringFromRect(canvas)

    default: throw QAError("Unknown source kind: \(item.kind)")
    }
    try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
      .write(to: output.appendingPathComponent(item.id + "-source-ready-ax.txt"), atomically: true, encoding: .utf8)
    event(item.id + " source ready")
  }

  private func prepareSecondarySource(_ item: ScenarioSource) throws {
    guard item.kind == "native", item.scene != nil else { throw QAError("Secondary source must be a native scene") }
    try openSource(item)
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: item.bundleID).first,
      let description = try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
        .split(separator: "\n").first(where: { $0.hasPrefix(" AXWindow ") })
    else {
      throw QAError("Prepared secondary source has no process or window")
    }
    let frame = try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: item.bundleID)
    let canvas = try NativeInteractionDriver.controlFrame(bundleIdentifier: item.bundleID, identifier: "source-canvas")
    preparedSecondarySource = PreparedNativeSource(
      source: item,
      processID: app.processIdentifier,
      windowFrame: frame,
      canvasFrame: canvas,
      windowDescription: String(description)
    )
    try NativeInteractionDriver.hideApplication(bundleIdentifier: item.bundleID)
    actionVerification["secondaryPreparedProcessID"] = Int(app.processIdentifier)
    actionVerification["secondaryPreparedScene"] = item.scene!
    actionVerification["secondaryPreparedWindowDescription"] = String(description)
    actionVerification["secondaryPreparedBeforeRecording"] = true
  }

  private func activatePreparedSecondarySource(_ item: ScenarioSource) throws {
    guard
      let prepared = preparedSecondarySource, prepared.source == item,
      let app = NSRunningApplication(processIdentifier: prepared.processID),
      app.bundleIdentifier == item.bundleID, !app.isTerminated
    else {
      throw QAError("Prepared secondary source process or scene changed")
    }
    try activate(item.bundleID)
    let ax = try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
    guard
      NativeInteractionDriver.frontmostBundleIdentifier() == item.bundleID,
      app.processIdentifier == prepared.processID,
      ax.split(separator: "\n").contains(Substring(prepared.windowDescription)),
      try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: item.bundleID) == prepared.windowFrame,
      try NativeInteractionDriver.controlFrame(bundleIdentifier: item.bundleID, identifier: "source-canvas") == prepared
        .canvasFrame
    else {
      throw QAError("Prepared secondary source identity or geometry changed")
    }
    activeSource = item
    actionVerification["secondaryActivatedProcessID"] = Int(app.processIdentifier)
    actionVerification["secondaryActivatedWithoutLaunchOrResize"] = true
    try ax.write(to: output.appendingPathComponent("secondary-activated-ax.txt"), atomically: true, encoding: .utf8)
    event("prepared secondary source activated")
  }

  private func prepareNote() throws {
    let paragraph = NSMutableParagraphStyle()
    paragraph.paragraphSpacing = 16
    let heading = NSAttributedString(string: noteHeading, attributes: [
      .font: NSFont.systemFont(ofSize: film == "layout" ? 28 : 36),
      .foregroundColor: NSColor.textColor,
      .paragraphStyle: paragraph,
    ])
    let data = try heading.data(
      from: NSRange(location: 0, length: heading.length),
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    )
    // TextEdit autosave requires a local filesystem with coherent file versions;
    // VirtioFS output shares may report our own writes as an external edit.
    let noteDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftyCrow-demo-notes-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: noteDirectory, withIntermediateDirectories: true)
    let note = noteDirectory.appendingPathComponent("Source notes.rtf")
    try data.write(to: note)
    try data.write(to: output.appendingPathComponent("Blank source notes.rtf"))
    actionVerification["actualTextEditDocumentPath"] = note.path
    try run("/usr/bin/open", ["-a", "TextEdit", note.path])
    pause(0.5)
    _ = try NativeInteractionDriver.arrangeMainWindow(
      bundleIdentifier: "com.apple.TextEdit",
      frame: CGRect(x: 180, y: 110, width: 1560, height: 880)
    )
    try NativeInteractionDriver.click(bundleIdentifier: "com.apple.TextEdit", identifier: "First Text View")
    try press("cmd - down")
    guard try NativeInteractionDriver.value(bundleIdentifier: "com.apple.TextEdit", identifier: "First Text View") == noteHeading
    else {
      throw QAError("Prepared note differs from scenario heading")
    }
    actionVerification["notePreparedWithoutTranslation"] = true
  }

  private func selectSource(_ item: ScenarioSource, live: Bool, stage: String, narrationID: String?) throws {
    try settingsAbsent()
    try activate(item.bundleID)
    if let narrationID { cue(narrationID) }
    let shortcut = live ? "liveOverlay" : "selectRegion"
    guard let chord = configuredShortcuts[shortcut] else { throw QAError("Missing configured shortcut: \(shortcut)") }
    try press(chord)
    event(live ? "Live Overlay shortcut" : "Capture Region shortcut")
    _ = try observe(stage + "-selector")
    let rect = try scenarioRect(item.selectionFrame)
    try NativeInteractionDriver.drag(from: rect.origin, to: CGPoint(x: rect.maxX, y: rect.maxY))
    actionVerification[stage + "SelectionFrame"] = NSStringFromRect(rect)
    event(stage + " region selected")
    _ = try waitFor(stage + " real translation", timeout: 40) { text in
      item.expectedTranslation.allSatisfy(text.contains) && !text.contains("AXIdentifier=exclamationmark.triangle.fill")
    }
    actionVerification[stage + "ExpectedFragments"] = item.expectedTranslation
    actionVerification[stage + "TranslationVerified"] = true
    event(stage + " translation verified")
    // Keep the result window inside the same caption safe area as its source.
    if !live {
      // The capture's image-size observer and SwiftUI intrinsic-size pass finish
      // asynchronously after text first appears. Arrange only after that frame
      // settles, so our explicit placement is not overwritten by initial layout.
      var frame = try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: bundleID)
      var stableSince = ProcessInfo.processInfo.systemUptime
      let deadline = stableSince + 5
      while ProcessInfo.processInfo.systemUptime - stableSince < 0.7 {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("Capture result frame did not settle") }
        pause(0.1)
        let current = try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: bundleID)
        if current != frame { stableSince = ProcessInfo.processInfo.systemUptime
          frame = current
        }
      }
      _ = try NativeInteractionDriver.arrangeMainWindow(
        bundleIdentifier: bundleID,
        frame: CGRect(x: 300, y: 110, width: 1320, height: 880)
      )
      try press("cmd - 0")
      pause(0.4)
    }
    try settingsAbsent()
    _ = try observe(stage + "-translated")
  }

  private func copyText(original: Bool, expected: [String], stage: String, narrationID: String?) throws -> String {
    try activate(bundleID)
    if let narrationID { cue(narrationID) }
    let key = original ? "regionCopyOriginal" : "regionCopyTranslation"
    guard let chord = configuredShortcuts[key] else { throw QAError("Missing configured shortcut: \(key)") }
    let before = NSPasteboard.general.changeCount
    try press(chord)
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while NSPasteboard.general.changeCount == before {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("\(key) did not write clipboard") }
      pause(0.1)
    }
    guard
      let text = NSPasteboard.general.string(forType: .string),
      expected.allSatisfy({ normalized(text).contains(normalized($0)) })
    else {
      throw QAError("Clipboard does not contain expected actual \(stage) text")
    }
    try text.write(to: output.appendingPathComponent(stage + ".txt"), atomically: true, encoding: .utf8)
    actionVerification[stage] = text
    event(stage + " clipboard verified")
    return text
  }

  private func normalized(_ value: String) -> String {
    String(value.filter { !$0.isWhitespace })
  }

  private func pasteIntoNote(_ copied: String, narrationID: String) throws {
    // SwiftyCrow closes a capture result after a successful clipboard copy.
    _ = try waitFor("capture result dismissed after copying") { !$0.contains("AXIdentifier=xmark ") }
    try activate("com.apple.TextEdit")
    cue(narrationID)
    try NativeInteractionDriver.click(bundleIdentifier: "com.apple.TextEdit", identifier: "First Text View")
    try press("cmd - down")
    try press("cmd - v")
    pause(0.5)
    let actual = try NativeInteractionDriver.value(bundleIdentifier: "com.apple.TextEdit", identifier: "First Text View")
    guard actual == noteHeading + copied else { throw QAError("TextEdit does not match actual clipboard text") }
    try NativeInteractionDriver.snapshot(bundleIdentifier: "com.apple.TextEdit")
      .write(to: output.appendingPathComponent("note-pasted-ax.txt"), atomically: true, encoding: .utf8)
    actionVerification["textEditPasteMatchesClipboard"] = true
    event("actual clipboard text pasted into TextEdit")
    _ = try observe("note-pasted")
    if sceneMode == "record" { pause(film == "layout" ? 4 : 2.5) }
  }

  private func pasteImageIntoPreview() throws {
    try activate(bundleID)
    cue("capture.copy")
    let before = NSPasteboard.general.changeCount
    guard let chord = configuredShortcuts["regionCopyImage"] else { throw QAError("Missing Copy Image shortcut") }
    try press(chord)
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    while NSPasteboard.general.changeCount == before {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw QAError("Copy Image did not write clipboard") }
      pause(0.1)
    }
    guard let image = NSImage(pasteboard: .general), image.size.width > 100, image.size.height > 100 else {
      throw QAError("Clipboard does not contain captured translated image")
    }
    actionVerification["copiedImageSize"] = NSStringFromSize(image.size)
    actionVerification["copiedImagePasteboardTypes"] = (NSPasteboard.general.types ?? []).map(\.rawValue)
    event("Copy Image verified")
    if sceneMode == "record" { pause(1.6) }
    _ = try waitFor("capture result dismissed after copying image") { !$0.contains("AXIdentifier=xmark ") }
    try activate("com.apple.Preview")
    actionVerification["previewPasteOpeningStartSeconds"] = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 -
      sceneStart
    event("Preview clipboard document opening started")
    try press("cmd - n")
    pause(0.5)
    let ax = try NativeInteractionDriver.snapshot(bundleIdentifier: "com.apple.Preview")
    guard ax.contains("AXWindow AXIdentifier=PVDocumentWindow | AXTitle=Untitled")
    else { throw QAError("Preview did not create a clipboard image document") }
    let initialFrame = try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: "com.apple.Preview")
    let destination = CGRect(origin: CGPoint(x: 340, y: 70), size: initialFrame.size)
    guard initialFrame.width > 700, destination.maxX < 1900, destination.maxY < 1027 else {
      throw QAError("Native Preview document does not fit the film area")
    }
    // This blank part of Preview's unified titlebar is outside toolbar controls.
    // Keep the document's natural size and move it with the visible real pointer.
    try NativeInteractionDriver.drag(
      from: CGPoint(x: initialFrame.minX + 350, y: initialFrame.minY + 25),
      to: CGPoint(x: destination.minX + 350, y: destination.minY + 25)
    )
    let frame = try NativeInteractionDriver.mainWindowFrame(bundleIdentifier: "com.apple.Preview")
    guard
      frame.size == initialFrame.size,
      abs(frame.minX - destination.minX) <= 1,
      abs(frame.minY - destination.minY) <= 1
    else { throw QAError("Native Preview titlebar drag did not preserve the document size and destination") }
    actionVerification["clipboardPreviewInitialWindowFrame"] = NSStringFromRect(initialFrame)
    actionVerification["clipboardPreviewWindowFrame"] = NSStringFromRect(frame)
    actionVerification["clipboardPreviewMovedByNativeDrag"] = true
    // Preview may select Live Text while its window moves beneath the pointer.
    // A normal click on the blank paper margin leaves the copied image unselected.
    try NativeInteractionDriver.click(at: CGPoint(x: frame.maxX - 24, y: frame.maxY - 40))
    actionVerification["clipboardPreviewBlankMarginClicked"] = true
    actionVerification["previewPasteOpeningEndSeconds"] = Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 -
      sceneStart
    event("Preview clipboard document opening settled")
    cue("capture.pasted")
    try NativeInteractionDriver.snapshot(bundleIdentifier: "com.apple.Preview").write(
      to: output.appendingPathComponent("preview-image-pasted-ax.txt"),
      atomically: true,
      encoding: .utf8
    )
    actionVerification["previewNewFromClipboardCreated"] = true
    _ = try observe("image-pasted")
    if sceneMode == "record" { pause(3) }
  }

  private func changeNativeSource(
    _ item: ScenarioSource,
    control: String,
    expected: [String],
    absent: [String],
    stage: String,
    narrationID: String
  ) throws {
    try activate(item.bundleID)
    cue(narrationID)
    try NativeInteractionDriver.click(bundleIdentifier: item.bundleID, identifier: control)
    event(stage + " source control clicked")
    _ = try waitFor(stage + " refreshed translation", timeout: 35) { text in
      expected.allSatisfy(text.contains) && !absent.contains(where: text.contains)
    }
    actionVerification[stage + "RefreshVerified"] = true
    actionVerification[stage + "ExpectedFragments"] = expected
    event(stage + " refreshed translation verified")
    try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
      .write(to: output.appendingPathComponent(stage + "-source-ax.txt"), atomically: true, encoding: .utf8)
    _ = try observe(stage)
  }

  private func showStoryMenu() throws {
    if !(try snapshot()).contains("AXRadioGroup") { try click("title:SwiftyCrow") }
    _ = try waitFor("menu visible") { $0.contains("AXRadioGroup") }
  }

  private func closeStoryMenu() throws {
    if try snapshot().contains("AXRadioGroup") { try click("title:SwiftyCrow") }
    _ = try waitFor("menu dismissed") { !$0.contains("AXRadioGroup") }
  }

  private func compareLiveModes(_ item: ScenarioSource) throws {
    guard let values = scenario?.translationWindowFrame
    else { throw QAError("Compare scenario requires translation window frame") }
    let expectedFrame = try scenarioRect(values)
    cue("compare.separate")
    try showStoryMenu()
    try click("description:" + label("Window"))
    _ = try waitFor("initial separate translation window", timeout: 8) {
      $0.contains("AXIdentifier=live-translation-result")
    }
    let initialFrame = try NativeInteractionDriver.controlFrame(bundleIdentifier: bundleID, identifier: "live-translation-result")
    guard initialFrame == expectedFrame else {
      throw QAError("Initial separate window did not preserve its prepared frame: \(initialFrame)")
    }
    actionVerification["separateInitialWindowFrame"] = NSStringFromRect(initialFrame)
    try closeStoryMenu()
    _ = try waitFor("separate translation window", timeout: 8) { item.expectedTranslation.allSatisfy($0.contains) }
    let frame = try NativeInteractionDriver.controlFrame(bundleIdentifier: bundleID, identifier: "live-translation-result")
    guard frame == expectedFrame else {
      throw QAError("Separate window did not preserve its prepared frame: \(frame)")
    }
    actionVerification["separateInitialWindowFramePreserved"] = true
    actionVerification["separateTranslationWindowFrame"] = NSStringFromRect(frame)
    actionVerification["separateTranslationWindowVerified"] = true
    _ = try observe("compare-window")
    if sceneMode == "record" { pause(2.5) }
    guard let changed = item.changedTranslation else { throw QAError("Missing changed game translation") }
    try changeNativeSource(
      item,
      control: "next",
      expected: changed,
      absent: item.expectedTranslation,
      stage: "compare-next",
      narrationID: "compare.next"
    )
    if sceneMode == "record" { pause(2.5) }
    cue("compare.hide")
    try showStoryMenu()
    try click("button:" + label("Hide overlay"))
    try closeStoryMenu()
    _ = try waitFor("overlay hidden") { text in !changed.contains(where: text.contains) }
    actionVerification["overlayHiddenVerified"] = true
    _ = try observe("compare-hidden")
    if sceneMode == "record" { pause(2) }
    cue("compare.recall")
    try showStoryMenu()
    try click("button:" + label("Show on last region"))
    try closeStoryMenu()
    _ = try waitFor("same region restored", timeout: 30) { changed.allSatisfy($0.contains) }
    let restoredFrame = try NativeInteractionDriver.controlFrame(
      bundleIdentifier: bundleID,
      identifier: "live-translation-result"
    )
    actionVerification["restoredTranslationWindowFrame"] = NSStringFromRect(restoredFrame)
    guard restoredFrame == frame else { throw QAError("Recalled translation window moved from \(frame) to \(restoredFrame)") }
    actionVerification["lastRegionWindowFramePreserved"] = true
    actionVerification["lastRegionRestoredWithoutSelection"] = true
    _ = try observe("compare-restored")
    if sceneMode == "record" { pause(3) }
  }

  private func prepareCompareWindow(_ item: ScenarioSource) throws {
    guard item.kind == "native", item.scene == "game", let values = scenario?.translationWindowFrame else {
      throw QAError("Compare preparation requires a native source and translation window frame")
    }
    try selectSource(item, live: true, stage: "prewarm-compare", narrationID: nil)
    try showStoryMenu()
    try click("description:" + label("Window"))
    try closeStoryMenu()
    _ = try waitFor("warm separate translation window", timeout: 8) {
      $0.contains("AXIdentifier=live-translation-result") && item.expectedTranslation.allSatisfy($0.contains)
    }
    let frame = try NativeInteractionDriver.arrangeMainWindow(bundleIdentifier: bundleID, frame: scenarioRect(values))
    actionVerification["prewarmedSeparateWindowFrame"] = NSStringFromRect(frame)
    _ = try observe("prewarm-compare-window")
    try showStoryMenu()
    try click("description:" + label("In-place"))
    try closeStoryMenu()
    try showStoryMenu()
    try click("button:" + label("Hide overlay"))
    try closeStoryMenu()
    _ = try waitFor("warm overlay hidden") { text in !item.expectedTranslation.contains(where: text.contains) }
    try activate(item.bundleID)
    try NativeInteractionDriver.click(bundleIdentifier: item.bundleID, identifier: "reset")
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    var sourceText = try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
    while
      !sourceText.contains("AXIdentifier=source-canvas | AXValue=game dialogue 1") ||
      !sourceText.contains("AXIdentifier=source-state | AXValue=Paused · 1")
    {
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw QAError("Compare source did not reset after native window preparation")
      }
      pause(0.1)
      sourceText = try NativeInteractionDriver.snapshot(bundleIdentifier: item.bundleID)
    }
    try sourceText.write(
      to: output.appendingPathComponent("prewarm-compare-source-reset-ax.txt"),
      atomically: true,
      encoding: .utf8
    )
    actionVerification["compareWindowPreparedBeforeRecording"] = true
    _ = try observe("prewarm-compare-reset")
  }

  private func configureScenario(_ args: Arguments, scenario _: FilmScenario) throws {
    let config = URL(fileURLWithPath: try args.required("config"))
    let text = try String(contentsOf: config, encoding: .utf8)
    try text.write(to: output.appendingPathComponent("config-before.toml"), atomically: true, encoding: .utf8)
    var section = ""
    var lines = text.components(separatedBy: "\n")
    var sourceFound = false
    var targetFound = false
    for index in lines.indices {
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("["), line.hasSuffix("]") { section = String(line.dropFirst().dropLast()) }
      if section == "languages.source", line.hasPrefix("code =") { lines[index] = "code = \"\(translationSource)\""
        sourceFound = true
      }
      if section == "languages.target", line.hasPrefix("code =") { lines[index] = "code = \"\(translationTarget)\""
        targetFound = true
      }
      if section == "overlay", line.hasPrefix("liveMode =") { lines[index] = "liveMode = \"inPlace\"" }
      if section == "shortcuts", let equal = line.firstIndex(of: "=") {
        let key = line[..<equal].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("\""), value.hasSuffix("\"") { configuredShortcuts[key] = String(value.dropFirst().dropLast()) }
      }
    }
    guard sourceFound, targetFound else { throw QAError("Demo config must explicitly contain source and target language codes") }
    for key in ["selectRegion", "liveOverlay", "regionCopyOriginal", "regionCopyTranslation", "regionCopyImage"] {
      guard let chord = configuredShortcuts[key] else { throw QAError("Demo config must explicitly configure \(key)") }
      var notes = [String]()
      _ = try ChordParser.parse(chord, notes: &notes)
    }
    try lines.joined(separator: "\n").write(to: config, atomically: true, encoding: .utf8)
    try FileManager.default.copyItem(at: config, to: output.appendingPathComponent("config-active.toml"))
  }

  private func verifyLanguagePair() throws {
    try click("title:SwiftyCrow")
    try click("button:" + label("Settings"))
    _ = try waitFor("Settings language check") { $0.contains("AXWindow AXIdentifier=settings") }
    if try snapshot().contains("AXRadioGroup") { try click("title:SwiftyCrow") }
    try click("text:" + label("Languages"))
    let ax = try observe("language-pair")
    let localized = Locale(identifier: locale)
    let sourceName = localized.localizedString(forIdentifier: translationSource) ?? ""
    let targetName = localized.localizedString(forIdentifier: translationTarget) ?? ""
    let popups = ax.split(separator: "\n").filter { $0.contains("AXPopUpButton AXValue=") }.map(String.init)
    // Apple's language picker may add script names; compare the localized
    // language component while retaining the actual full values as evidence.
    let sourceLanguage = localized
      .localizedString(forLanguageCode: Locale.Language(identifier: translationSource).languageCode!.identifier) ?? sourceName
    let targetLanguage = localized
      .localizedString(forLanguageCode: Locale.Language(identifier: translationTarget).languageCode!.identifier) ?? targetName
    guard
      popups.count == 2, popups[0].localizedCaseInsensitiveContains(sourceLanguage),
      popups[1].localizedCaseInsensitiveContains(targetLanguage)
    else {
      throw QAError("Actual language picker does not match scenario pair: \(popups)")
    }
    actionVerification["actualLanguagePickerValues"] = popups
    actionVerification["actualLanguagePairVerified"] = true
    try closeSettings()
  }

}

// MARK: - DemoQA

@main
struct DemoQA {
  @MainActor
  static func nativeAction(_ args: Arguments) throws {
    let operation = try args.required("operation")
    if operation == "press" {
      var notes = [String]()
      try KeyDriver.press(ChordParser.parse(try args.required("chord"), notes: &notes), holdMilliseconds: 24)
      return
    }
    if operation == "clipboard-info" {
      let board = NSPasteboard.general
      print("changeCount=\(board.changeCount)")
      print("types=\((board.types ?? []).map(\.rawValue).joined(separator: ","))")
      if let text = board.string(forType: .string) { print("text=\(text)") }
      if let image = NSImage(pasteboard: board) { print("imageSize=\(image.size)") }
      return
    }
    let bundle = try args.required("bundle")
    switch operation {
    case "close": try NativeInteractionDriver.closeMainWindow(bundleIdentifier: bundle)

    case "type": try NativeInteractionDriver.type(try args.required("text"), intervalMilliseconds: 10)

    case "snapshot": print(try NativeInteractionDriver.snapshot(bundleIdentifier: bundle))

    case "activate":
      guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first?.activate() == true else {
        throw QAError("Could not activate \(bundle)")
      }
      Thread.sleep(forTimeInterval: 0.3)
      guard NativeInteractionDriver.frontmostBundleIdentifier() == bundle
      else { throw QAError("App did not become frontmost: \(bundle)") }

    case "arrange":
      let values = try args.required("frame").split(separator: ",").compactMap { Double($0) }
      guard values.count == 4 else { throw QAError("--frame expects x,y,width,height") }
      print(try NativeInteractionDriver.arrangeMainWindow(
        bundleIdentifier: bundle,
        frame: CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
      ))

    case "click": try NativeInteractionDriver.click(bundleIdentifier: bundle, identifier: try args.required("identifier"))

    case "scroll":
      guard let pixels = Int(try args.required("pixels")) else { throw QAError("--pixels expects an integer") }
      try NativeInteractionDriver.scroll(bundleIdentifier: bundle, identifier: try args.required("identifier"), pixels: pixels)

    default: throw QAError("Unknown native operation: \(operation)")
    }
  }

  @MainActor
  static func main() {
    do {
      let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
      if args.command == "native" { try nativeAction(args)
        return
      }
      if args.command == "help" || args.command == "--help" {
        print(
          "demoqa story --film tour|capture|live|layout|compare --app PATH --locale en|ko|ja|zh-Hans|zh-Hant --catalog Localizable.xcstrings --source Fixtures/manifest.json --scenarios Fixtures/scenarios.json --source-app DemoScenes.app --output NEW_DIRECTORY --archive APP.zip --config config.toml --mode preview|record [--recorder DemoRecorder --fps 30 --codec hevc|h264 --bitrate-mbps 8]\nAdditional QA commands: collect, capture (legacy HTML probe), native --operation snapshot|activate|arrange|click|scroll|close|type|press|clipboard-info"
        )
        return
      }
      let driver = try SceneDriver(args)
      switch args.command {
      case "collect": try driver.collect()
      case "capture": try driver.capture(args)
      case "story": try driver.story(args)
      default: throw QAError("Unknown command: \(args.command)")
      }
    } catch {
      FileHandle.standardError.write(Data("demoqa: \(error)\n".utf8))
      exit(1)
    }
  }
}
