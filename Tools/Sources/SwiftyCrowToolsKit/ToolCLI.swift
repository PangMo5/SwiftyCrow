// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import ArgumentParser
import Foundation

public struct SwiftyCrowTools: AsyncParsableCommand {

  // MARK: Lifecycle

  public init() { }

  // MARK: Public

  public static let configuration = CommandConfiguration(
    commandName: "swiftycrow-tools",
    abstract: "Validate and build SwiftyCrow localizations, documents, sites, and demo exports."
  )

  public mutating func run() async throws {
    let workspace = try Workspace.discover(root)
    let checks = CatalogChecks(workspace: workspace)
    func required(_ value: String?, _ name: String) throws -> String {
      guard let value else { throw ValidationError("\(name) is required") }
      return value
    }
    switch command {
    case .recordLocales:
      try await RecordingBatch(workspace: workspace).record(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(output, "--output")),
        check: check
      )

    case .selectTakes:
      try TakeLibrary(workspace: workspace).select(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(output, "--output"))
      )

    case .prepareReview:
      try await TakeLibrary(workspace: workspace).prepare(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(output, "--output"))
      )

    case .exportBatch:
      try await TakeLibrary(workspace: workspace).export(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(mediaRoot, "--media-root"))
      )

    case .mergeReviewBundle:
      try ReviewBundle(workspace: workspace).merge(
        selection: URL(fileURLWithPath: required(source, "--source")),
        mediaRoot: URL(fileURLWithPath: required(mediaRoot, "--media-root")),
        output: URL(fileURLWithPath: required(output, "--output")),
        base: baseReview.map { URL(fileURLWithPath: $0) }
      )

    case .verifyMedia:
      try ReviewBundle(workspace: workspace).verify(
        JSON.read(URL(fileURLWithPath: required(source, "--source"))),
        portable: portable
      )

    case .installAssets:
      try ReviewBundle(workspace: workspace).install(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(output, "--output"))
      )

    case .check: try checks.all(locale: locale)

    case .docs: try DocumentBuilder(workspace: workspace).build(check: check, locale: locale)

    case .site: try await SiteBuilder(workspace: workspace).build(
        output: URL(fileURLWithPath: required(output, "--output")),
        version: version,
        locale: locale,
        mediaRoot: mediaRoot.map { URL(fileURLWithPath: $0) }
      )

    case .collectDocs: try checks.collect("docs")

    case .collectWeb: try checks.collect("web")

    case .checkApp: try checks.app(stringsdata.map { URL(fileURLWithPath: $0) }, locale: locale)

    case .syncApp: try checks.syncApp(URL(fileURLWithPath: required(stringsdata, "--stringsdata")))

    case .serve:
      try await PreviewServer(directory: URL(fileURLWithPath: required(output, "--output")), workspace: workspace, port: port)
        .start()

    case .appcastNotes:
      try ReleaseMetadata(workspace: workspace).embedNotes(
        file: URL(fileURLWithPath: required(output, "--output")),
        version: required(version, "--version")
      )

    case .auditVideo:
      try await VideoAudit(workspace: workspace).audit(
        source: URL(fileURLWithPath: required(source, "--source")),
        output: URL(fileURLWithPath: required(output, "--output"))
      )

    case .exportVideo:
      guard let posterSeconds else { throw ValidationError("--poster-seconds is required") }
      try await VideoExport(workspace: workspace).export(
        source: URL(fileURLWithPath: required(source, "--source")),
        film: required(film, "--film"),
        locale: required(locale, "--locale"),
        posterSeconds: posterSeconds,
        review: URL(fileURLWithPath: required(reviewReport, "--review-report")),
        mediaRoot: mediaRoot.map { URL(fileURLWithPath: $0) }
      )

    case .renderNarration:
      let timeline = try JSON.read(URL(fileURLWithPath: required(source, "--source")))
      let rendered = try await FilmNarration(workspace: workspace).render(
        timeline: timeline,
        locale: required(locale, "--locale")
      )
      try URL(fileURLWithPath: required(output, "--output")).write(rendered)
    }
  }

  // MARK: Internal

  enum Command: String, ExpressibleByArgument {
    case recordLocales = "record-locales"
    case selectTakes = "select-takes"
    case prepareReview = "prepare-review"
    case exportBatch = "export-batch", mergeReviewBundle = "merge-review-bundle"
    case verifyMedia = "verify-media", installAssets = "install-assets"
    case check
    case docs
    case site
    case serve
    case collectDocs = "collect-docs"
    case collectWeb = "collect-web"
    case checkApp = "check-app", syncApp = "sync-app"
    case exportVideo = "export-video", appcastNotes = "appcast-notes", auditVideo = "audit-video"
    case renderNarration = "render-narration"
  }

  @Argument(help: "Operation to perform.")
  var command: Command
  @Option(help: "Loopback preview server port.")
  var port: UInt16 = 8085
  @Option(help: "Repository root. Discovered from the current directory when omitted.")
  var root: String?
  @Option(help: "Existing verified review bundle whose unselected films are retained during merging.")
  var baseReview: String?
  @Flag(help: "Verify committed media and preserved evidence without requiring local camera originals.")
  var portable = false
  @Flag(help: "Check documents or validate a recording plan without running it.")
  var check = false
  @Option(help: "Site output directory.")
  var output: String?
  @Option(help: "Media directory for an isolated locale preview, containing locale subdirectories.")
  var mediaRoot: String?
  @Option(help: "Published site version. Defaults to Project.swift.")
  var version: String?
  @Option(help: "Compiler-generated .stringsdata directory.")
  var stringsdata: String?
  @Option(help: "Input movie, recording plan, take decisions, selection, or review manifest.")
  var source: String?
  @Option(help: "App interface locale of the recording.")
  var locale: String?
  @Option(help: "Film identifier from DemoLab/Localization/Films.json.")
  var film: String?
  @Option(help: "Poster timestamp inside the accepted take.")
  var posterSeconds: Double?
  @Option(help: "Existing visual review evidence for the accepted take.")
  var reviewReport: String?

}
