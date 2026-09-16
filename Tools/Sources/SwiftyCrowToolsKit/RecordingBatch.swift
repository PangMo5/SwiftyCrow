// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

/// Runs inside the explicitly prepared recording VM. Transport and VM ownership stay external.
struct RecordingBatch {

  // MARK: Internal

  let workspace: Workspace

  func requests(_ plan: JSON) throws -> [(take: JSON, arguments: [String], fingerprint: JSON)] {
    let library = TakeLibrary(workspace: workspace)
    let takes = plan["takes"].array
    try library.unique(takes)
    var arguments = [String]()
    var inputs = [(String, JSON)]()
    for (key, option) in [
      ("demoqa", ""),
      ("app", "--app"),
      ("archive", "--archive"),
      ("catalog", "--catalog"),
      ("source", "--source"),
      ("scenarios", "--scenarios"),
      ("sourceApp", "--source-app"),
      ("config", "--config"),
      ("recorder", "--recorder"),
    ] {
      let file = try library.path(plan[key].str)
      try require(file.exists, "Recording input missing: \(key)")
      if key == "demoqa" { arguments += [file.path, "story"] }
      else { arguments += [option, file.path] }
      // Config is mutable: selecting a language/region updates it during the batch.
      // Its path is fixed, while code, archives, catalogs, and fixtures are fingerprinted.
      if key != "config" { inputs.append((key, try inputFingerprint(file))) }
    }
    let scenarios = try JSON.read(library.path(plan["scenarios"].str))
    try require(scenarios["version"].int == 2, "Batch recording requires a locale-specific scenario matrix")
    let films = try JSON.read(workspace.root.at("DemoLab/Localization/Films.json"))["films"]
    var directories = Set<String>()
    return try takes.map { take in
      let id = try library.key(take)
      let directory = try library.path(take["directory"].str).resolvingSymlinksInPath()
      try require(directories.insert(directory.path).inserted, "Two takes share an output directory")
      let scenario = scenarios["locales"][take["locale"].str][take["film"].str]
      let pair = try FilmLanguagePair(film: films[take["film"].str], locale: take["locale"].str)
      try require(
        scenario["targetLanguage"].str == pair.target
          && scenario["sources"].array.first?["language"].str == pair.source,
        "Batch scenario language mismatch: \(id)"
      )
      let argv = arguments + [
        "--locale",
        take["locale"].str,
        "--film",
        take["film"].str,
        "--output",
        directory.path,
        "--mode",
        "record",
        "--fps",
        "30",
        "--codec",
        "hevc",
        "--bitrate-mbps",
        "8",
      ]
      return (take, argv, .object([("arguments", .array(argv.map(JSON.string))), ("inputs", .object(inputs))]))
    }
  }

  func record(
    source: URL,
    output: URL,
    check: Bool,
    execute: ([String]) async throws -> Void = { arguments in
      try await runProcess(arguments, removingEnvironment: [
        "SWIFTYCROW_QA_OCR_DIRECTORY",
        "SWIFTYCROW_QA_LIVE_FRAMES",
        "SWIFTYCROW_HOST_MOUSE_CONFIG",
        "SWIFTYCROW_HOST_CAPTURE_ROOT",
      ])
    }
  ) async throws {
    try require(source.resolvingSymlinksInPath() != output.resolvingSymlinksInPath(), "Batch report must not replace its plan")
    let library = TakeLibrary(workspace: workspace)
    let requests = try requests(JSON.read(source))
    for request in requests {
      let directory = try library.path(request.take["directory"].str).resolvingSymlinksInPath().path
      try require(
        !output.resolvingSymlinksInPath().path.hasPrefix(directory + "/"),
        "Batch report must be outside camera take directories"
      )
    }
    if check {
      try JSON.object([
        ("status", .string("plan validated; no recording started")),
        ("requests", .array(requests.map(\.fingerprint))),
      ]).write(output)
      return
    }
    var results = [JSON]()
    var failures = 0
    for request in requests {
      try Task.checkCancellation()
      let take = request.take
      let directory = try library.path(take["directory"].str)
      // A sidecar is created before recording without pre-creating the recorder's output directory.
      let marker = directory.appendingPathExtension("request.json")
      let id = try library.key(take)
      do {
        var resumed = false
        if directory.exists {
          try require(
            marker.exists && JSON.read(marker) == request.fingerprint,
            "Existing take belongs to another request: \(id)"
          )
          _ = try library.validate(take)
          resumed = true
        } else {
          if marker.exists { try require(
            JSON.read(marker) == request.fingerprint,
            "Changed recording request; choose a new take directory"
          ) }
          try request.fingerprint.write(marker)
          try await execute(request.arguments)
          _ = try library.validate(take)
        }
        results.append(take.merging([("status", .string(resumed ? "resumed" : "recorded"))]))
        print("\(id): \(resumed ? "retained completed take" : "recorded")")
      } catch {
        try Task.checkCancellation()
        failures += 1
        results.append(take.merging([("status", .string("failed")), ("error", .string(String(describing: error)))]))
        print("\(id): \(error). Preserved failed take; use a new directory to retry.")
      }
      try JSON.object([("status", .string("in progress")), ("results", .array(results))]).write(output)
    }
    try JSON.object([("status", .string(failures == 0 ? "passed" : "failed")), ("results", .array(results))]).write(output)
    try require(failures == 0, "\(failures) recording requests failed; see \(output.path)")
  }

  // MARK: Private

  private func inputFingerprint(_ url: URL) throws -> JSON {
    let values = try url.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { return .string(try sha(url)) }
    guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else {
      throw ToolError("Cannot inspect recording bundle: \(url.path)")
    }
    var files = [(String, JSON)]()
    for case let file as URL in enumerator {
      if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
        files.append((relativePath(file, from: url), .string(try sha(file))))
      }
    }
    try require(!files.isEmpty, "Empty recording bundle: \(url.path)")
    return .object(files.sorted { $0.0 < $1.0 })
  }

}
