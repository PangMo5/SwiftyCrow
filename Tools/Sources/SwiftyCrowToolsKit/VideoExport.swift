// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation

struct VideoExport {

  let workspace: Workspace

  func probe(_ file: URL) async throws -> JSON {
    let output = try await runProcess(
      [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-count_frames",
        "-show_entries",
        "stream=codec_name,pix_fmt,width,height,nb_read_frames,avg_frame_rate,duration",
        "-of",
        "json",
        file.path,
      ],
      capture: true
    )
    let streams = try JSON.parse(output)["streams"].array
    try require(streams.count == 1, "Expected one video stream")
    return streams[0]
  }

  func export(source: URL, film: String, locale: String, posterSeconds: Double, review: URL, mediaRoot: URL? = nil) async throws {
    try require(locales.contains(locale), "Unsupported interface locale")
    let films = try CatalogChecks(workspace: workspace).films()
    try require(!films[film].isNull, "Unknown film: \(film)")
    let pair = try FilmLanguagePair(film: films[film], locale: locale)
    let scene = try JSON.read(source.deletingLastPathComponent().at("scene.json"))
    try require(scene["film"].str == film && scene["uiLanguage"].str == locale, "Recording does not match film and locale")
    try require(
      scene["translationSource"].str == pair.source && scene["translationTarget"].str == pair.target,
      "Recorded language pair differs from the film"
    )
    try require(review.exists, "Visual review evidence is required")
    let stats = try JSON.read(source.replacingExtension("json"))
    try require(stats["status"].str == "ok" && stats["error"].isNull, "Recorder did not finish successfully")
    let dropped = stats["dropped"].double
    let frames = stats["frames"].double
    try require(frames > 0 && dropped >= 0 && dropped / (frames + dropped) <= 0.01, "Dropped frames exceed 1%")
    let original = try await probe(source)
    try require(original["nb_read_frames"].double == frames, "Camera frame count differs from recorder metadata")
    let timelineURL = source.deletingLastPathComponent().at("presentation.json")
    let timeline = try JSON.read(timelineURL)
    try FilmNarration.validate(timeline, film: film, locale: locale, duration: stats["durationSeconds"].double)
    let ready = try JSON.read(source.deletingLastPathComponent().at("capture-demo.ready.json"))
    try require(
      timeline["captureEpochUptimeNanoseconds"] == ready["firstFrameUptimeNanoseconds"],
      "Narration does not use the first captured frame epoch"
    )
    var hostClockEvidence = JSON.null
    if !ready["hostFirstFrameUptimeNanoseconds"].isNull {
      let clockURL = source.replacingExtension("clock.json")
      let hostReadyURL = source.replacingExtension("host-ready.json")
      let clock = try JSON.read(clockURL)
      let hostReady = try JSON.read(hostReadyURL)
      try require(
        clock["before"].array.count == 9 && clock["after"].array.count == 9
          && clock["maximumAlignmentErrorNanoseconds"].double < 1e9 / 30
          && clock["mappedFirstFrameUptimeNanoseconds"] == ready["firstFrameUptimeNanoseconds"]
          && hostReady["firstFrameUptimeNanoseconds"] == ready["hostFirstFrameUptimeNanoseconds"]
          && stats["hostRecorderSHA256"].str.count == 64
          && stats["hostRecorderSHA256"] == hostReady["hostRecorderSHA256"]
          && stats["geometryUnchanged"] == .bool(true),
        "Host recording lacks aligned clocks, stable geometry or executable provenance"
      )
      hostClockEvidence = try .object([
        ("clock", clock),
        ("clockSHA256", .string(sha(clockURL))),
        ("hostReady", hostReady),
        ("hostReadySHA256", .string(sha(hostReadyURL))),
      ])
    }
    try require(
      timeline["scenariosSHA256"].str.count == 64 && timeline["scenariosSHA256"] == scene["scenariosSHA256"],
      "Narration scenarios differ from the recording"
    )
    try require(posterSeconds >= 0 && posterSeconds < original["duration"].double, "Poster must be inside the take")
    let directory = (mediaRoot ?? workspace.root.at("DemoLab/Edits/media")).at(locale)
    try directory.makeDirectory()
    let movie = directory.at("\(film).mp4")
    let poster = directory.at("\(film).jpg")
    let subtitles = directory.at("\(film).ass")
    try require(
      !movie.exists && !poster.exists && !subtitles.exists,
      "Export already exists; choose whether to replace it explicitly"
    )
    let scratch = fm.temporaryDirectory.at("swiftycrow-export-" + UUID().uuidString)
    try scratch.makeDirectory()
    defer { try? fm.removeItem(at: scratch) }
    let narration = try await FilmNarration(workspace: workspace).render(
      timeline: timeline,
      locale: locale,
      width: original["width"].int,
      height: original["height"].int
    )
    try scratch.at("film.ass").write(narration)
    let encoder = ProcessInfo.processInfo.environment["SWIFTYCROW_FFMPEG"] ?? "ffmpeg"
    let filters = try await runProcess([encoder, "-hide_banner", "-filters"], capture: true)
    try require(
      filters.contains(" ass "),
      "Video export requires FFmpeg with libass; set SWIFTYCROW_FFMPEG to a libass-enabled binary"
    )
    try await runProcess([
      encoder,
      "-nostdin",
      "-v",
      "error",
      "-i",
      source.path,
      "-an",
      "-vf",
      "ass=film.ass",
      "-c:v",
      "libx264",
      "-threads",
      "2",
      "-preset",
      "slow",
      "-crf",
      "20",
      "-pix_fmt",
      "yuv420p",
      "-fps_mode",
      "passthrough",
      "-movflags",
      "+faststart",
      movie.path,
    ], cwd: scratch)
    try await runProcess(["ffmpeg", "-nostdin", "-v", "error", "-xerror", "-i", movie.path, "-f", "null", "-"])
    let encoded = try await probe(movie)
    for field in ["width", "height", "nb_read_frames"] {
      try require(original[field] == encoded[field], "Export changed \(field)")
    }
    try require(abs(original["duration"].double - encoded["duration"].double) <= 0.04, "Export changed duration")
    try require(encoded["codec_name"].str == "h264" && encoded["pix_fmt"].str == "yuv420p", "Invalid publication codec")
    try subtitles.write(narration)
    try await runProcess([
      "ffmpeg",
      "-nostdin",
      "-v",
      "error",
      "-ss",
      String(posterSeconds),
      "-i",
      movie.path,
      "-frames:v",
      "1",
      "-q:v",
      "2",
      poster.path,
    ])
    let metadata = try JSON.object([
      ("film", .string(film)),
      ("uiLanguage", .string(locale)),
      ("sourceLanguage", .string(pair.source)),
      ("translationLanguage", .string(pair.target)),
      ("cameraOriginal", .string(relativePath(source, from: workspace.root))),
      ("cameraSHA256", .string(sha(source))),
      ("recorder", stats),
      ("hostClockEvidence", hostClockEvidence),
      ("originalVideo", original),
      ("exportVideo", encoded),
      ("movie", .string(relativePath(movie, from: workspace.root))),
      ("movieSHA256", .string(sha(movie))),
      ("poster", .string(relativePath(poster, from: workspace.root))),
      ("posterSHA256", .string(sha(poster))),
      ("posterSeconds", .decimal(posterSeconds)),
      ("presentationTimeline", .string(relativePath(timelineURL, from: workspace.root))),
      ("presentationTimelineSHA256", .string(sha(timelineURL))),
      ("subtitles", .string(relativePath(subtitles, from: workspace.root))),
      ("subtitlesSHA256", .string(sha(subtitles))),
      ("narrationCatalogSHA256", .string(sha(workspace.root.at("DemoLab/Localization/Narration.json")))),
      (
        "presentation",
        .string(
          "Localized chapter, stage captions, and actual recorded input chords burned over the complete camera take; no cuts, speed changes, or replacement app pixels."
        )
      ),
      ("encoderVersion", .string(await runProcess([encoder, "-version"], capture: true))),
      ("visualReviewEvidence", .string(relativePath(review, from: workspace.root))),
    ])
    try metadata.write(movie.replacingExtension("json"))
    try print(metadata.rendered())
  }

}
