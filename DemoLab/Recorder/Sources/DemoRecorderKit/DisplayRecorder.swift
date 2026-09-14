// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - ScreenAccess

/// The Screen Recording (TCC) gate.
public enum ScreenAccess {

  public static let deniedMessage = """
    DemoRecorder: no Screen Recording access. Two different causes produce this, and they need
    different fixes:

      1. The permission was never granted. Open System Settings > Privacy & Security >
         Screen & System Audio Recording and enable the recorder.

      2. The permission belongs to another process. TCC attributes screen capture to the
         *responsible* process, which for a binary started from a terminal, a script, or an IDE is
         that launcher — Terminal, iTerm, Xcode — and not DemoRecorder. Either grant it to the
         launcher, or launch the bundled DemoRecorder.app directly (`open -a DemoRecorder ...`) so
         DemoRecorder is its own responsible process.

    CGRequestScreenCaptureAccess() is deliberately not called: it returns false without showing any
    prompt when the responsible process is the wrong one, and a grant made while this process runs
    never reaches it. After changing the setting, relaunch DemoRecorder — and relaunch whatever
    launched it too, when that is the process holding the grant.
    """

  public static func isGranted() -> Bool {
    CGPreflightScreenCaptureAccess()
  }

}

// MARK: - DisplayInfo

/// One row of `--list-displays`.
public struct DisplayInfo: Sendable {

  // MARK: Lifecycle

  public init(
    index: Int,
    displayID: CGDirectDisplayID,
    pointSize: CGSize,
    pointPixelScale: CGFloat,
    localizedName: String
  ) {
    self.index = index
    self.displayID = displayID
    self.pointSize = pointSize
    self.pointPixelScale = pointPixelScale
    self.localizedName = localizedName
  }

  // MARK: Public

  /// 1-based, and what `--display <index>` expects.
  public let index: Int
  public let displayID: CGDirectDisplayID
  public let pointSize: CGSize
  public let pointPixelScale: CGFloat
  public let localizedName: String

}

// MARK: - StartedDisplay

/// What one live stream is capturing, reported once at start.
public struct StartedDisplay: Sendable {

  // MARK: Lifecycle

  public init(
    index: Int,
    displayID: CGDirectDisplayID,
    pointSize: CGSize,
    pointPixelScale: CGFloat,
    pixelWidth: Int,
    pixelHeight: Int,
    codec: String,
    outputURL: URL
  ) {
    self.index = index
    self.displayID = displayID
    self.pointSize = pointSize
    self.pointPixelScale = pointPixelScale
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.codec = codec
    self.outputURL = outputURL
  }

  // MARK: Public

  public let index: Int
  public let displayID: CGDirectDisplayID
  public let pointSize: CGSize
  public let pointPixelScale: CGFloat
  public let pixelWidth: Int
  public let pixelHeight: Int
  public let codec: String
  public let outputURL: URL

}

// MARK: - DisplayCatalog

/// Display discovery and selection.
public enum DisplayCatalog {

  /// `SCShareableContent.current` enumerates offscreen windows as well and is
  /// measurably slower; a display filter never needs them.
  public static func shareableContent() async throws -> SCShareableContent {
    try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
  }

  public static func load() async throws -> [DisplayInfo] {
    let content = try await shareableContent()
    let names = await localizedNames()
    return content.displays.enumerated().map { offset, display in
      let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
      return DisplayInfo(
        index: offset + 1,
        displayID: display.displayID,
        pointSize: CGSize(width: display.width, height: display.height),
        pointPixelScale: CGFloat(filter.pointPixelScale),
        localizedName: names[display.displayID] ?? "Display \(display.displayID)"
      )
    }
  }

  /// Returns the selected displays paired with their 1-based catalog index, so
  /// logs, `--display <index>`, and the `-1`/`-2` file suffixes all agree.
  public static func select(
    _ selection: DisplaySelection,
    from displays: [SCDisplay]
  ) throws -> [(index: Int, display: SCDisplay)] {
    guard !displays.isEmpty else {
      throw RecorderError.noDisplaysAvailable
    }
    switch selection {
    case .all:
      return displays.enumerated().map { (index: $0.offset + 1, display: $0.element) }
    case .main:
      let mainID = CGMainDisplayID()
      guard let offset = displays.firstIndex(where: { $0.displayID == mainID }) else {
        throw RecorderError.mainDisplayUnavailable
      }
      return [(index: offset + 1, display: displays[offset])]
    case .index(let index):
      guard index >= 1, index <= displays.count else {
        throw RecorderError.displayIndexOutOfRange(index: index, count: displays.count)
      }
      return [(index: index, display: displays[index - 1])]

    case .identifier(let displayID):
      guard let offset = displays.firstIndex(where: { $0.displayID == displayID }) else {
        throw RecorderError.displayIdentifierUnavailable(displayID: displayID)
      }
      return [(index: offset + 1, display: displays[offset])]
    }
  }

  /// One file per display. There is no ScreenCaptureKit API that captures more
  /// than one display in a single stream, and a filter rect spanning two
  /// displays returns empty frames, so `--display all` fans out into independent
  /// takes that are composited afterwards.
  public static func outputURLs(base: URL, indices: [Int], suffixed: Bool) -> [URL] {
    guard suffixed else { return [base] }
    let directory = base.deletingLastPathComponent()
    let ext = base.pathExtension.isEmpty ? "mov" : base.pathExtension
    let stem = base.deletingPathExtension().lastPathComponent
    return indices.map { index in
      directory.appendingPathComponent("\(stem)-\(index)").appendingPathExtension(ext)
    }
  }

  public static func formatted(_ displays: [DisplayInfo]) -> String {
    var lines = ["index  displayID  points        scale  name"]
    for display in displays {
      let index = String(display.index).padding(toLength: 5, withPad: " ", startingAt: 0)
      let identifier = String(display.displayID).padding(toLength: 9, withPad: " ", startingAt: 0)
      let points = "\(Int(display.pointSize.width)) x \(Int(display.pointSize.height))"
        .padding(toLength: 12, withPad: " ", startingAt: 0)
      let scale = String(format: "%.1fx", Double(display.pointPixelScale))
        .padding(toLength: 5, withPad: " ", startingAt: 0)
      lines.append("\(index)  \(identifier)  \(points)  \(scale)  \(display.localizedName)")
    }
    return lines.joined(separator: "\n")
  }

  /// Prints the catalog from a detached task and exits. The process is a CLI
  /// with a live main queue, so it never returns here.
  public static func printCatalogAndExit() {
    Task.detached {
      guard ScreenAccess.isGranted() else {
        StandardError.write(ScreenAccess.deniedMessage)
        exit(RecorderExit.noScreenRecordingAccess.rawValue)
      }
      do {
        let displays = try await load()
        print(formatted(displays))
        fflush(stdout)
        exit(RecorderExit.ok.rawValue)
      } catch {
        StandardError.write("DemoRecorder: display discovery failed: \(StandardError.describe(error))")
        exit(RecorderExit.captureFailure.rawValue)
      }
    }
  }

  // MARK: Private

  /// `SCDisplay` has no name; `NSScreen` does. AppKit wants the main thread for
  /// it, so the lookup hops there and comes back with a plain dictionary.
  private static func localizedNames() async -> [CGDirectDisplayID: String] {
    await MainActor.run {
      var names = [CGDirectDisplayID: String]()
      for screen in NSScreen.screens {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { continue }
        names[CGDirectDisplayID(number.uint32Value)] = screen.localizedName
      }
      return names
    }
  }

}

// MARK: - DisplayRecorder

/// One display, one ScreenCaptureKit stream, one `.mov`.
///
/// The stream output callback does nothing but hand the newest buffer to the
/// ``CadenceWriter``; all encoding happens on the cadence queue.
public final class DisplayRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

  // MARK: Lifecycle

  public init(
    display: SCDisplay,
    index: Int,
    outputURL: URL,
    options: RecorderOptions,
    excludedApplications: [SCRunningApplication],
    onFailure: @escaping @Sendable (any Error) -> Void
  ) {
    self.index = index
    self.outputURL = outputURL
    self.options = options
    self.onFailure = onFailure
    displayID = display.displayID
    pointSize = CGSize(width: display.width, height: display.height)

    // Excluding by pid rather than by bundle identifier: a SwiftPM executable
    // has no bundle id at all, and the pid is what actually identifies us.
    let filter = SCContentFilter(
      display: display,
      excludingApplications: excludedApplications,
      exceptingWindows: []
    )
    let scale = CGFloat(filter.pointPixelScale)
    let rect = filter.contentRect
    // Backing pixels, never `SCDisplay.width * 2`: the scale is a property of the
    // filter, and encoders reject odd dimensions.
    let width = DisplayRecorder.evenFloor(Int(rect.width * scale))
    let height = DisplayRecorder.evenFloor(Int(rect.height * scale))

    self.filter = filter
    pointPixelScale = scale
    pixelWidth = width
    pixelHeight = height
    configuration = DisplayRecorder.makeConfiguration(width: width, height: height, options: options)
    captureQueue = DispatchQueue(
      label: "dev.pangmo5.demolab.recorder.capture.display-\(index)",
      qos: .userInitiated
    )
    super.init()
  }

  // MARK: Public

  public let index: Int
  public let outputURL: URL
  public let displayID: CGDirectDisplayID
  public let pointSize: CGSize
  public let pointPixelScale: CGFloat
  public let pixelWidth: Int
  public let pixelHeight: Int

  public func start() async throws -> StartedDisplay {
    let writer = try CadenceWriter(
      outputURL: outputURL,
      width: pixelWidth,
      height: pixelHeight,
      fps: options.fps,
      requestedCodec: options.codec,
      bitrateMbps: options.bitrateMbps,
      label: "display-\(index)"
    )
    let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
    try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: captureQueue)

    lock.withLock {
      self.writer = writer
      self.stream = stream
    }

    try await stream.startCapture()
    do {
      // The cadence starts only once frames can actually arrive; buffers
      // delivered in between simply land in the latest-buffer slot.
      try writer.start()
    } catch {
      try? await stream.stopCapture()
      throw error
    }
    return StartedDisplay(
      index: index,
      displayID: displayID,
      pointSize: pointSize,
      pointPixelScale: pointPixelScale,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      codec: writer.codec,
      outputURL: outputURL
    )
  }

  /// Resolves once this stream has produced a frame. `false` means the budget
  /// ran out with the stream live but silent, which is a note rather than a
  /// failure: the caller must not begin a scene without an encoded frame.
  public var firstFrameUptime: UInt64? { lock.withLock { writer?.firstFrameUptime } }

  public func awaitFirstFrame() async -> Bool {
    // `withLock`, not lock/unlock: `NSLock.lock()` is unavailable from an async
    // context.
    guard let target = lock.withLock({ writer }) else { return false }
    return await target.awaitFirstFrame()
  }

  /// The shutdown order is load-bearing: stopping the cadence first, capture
  /// second, and only then finalizing keeps the moov atom consistent with the
  /// samples that were actually written.
  public func stop() async throws -> RecordingSummary {
    let (stream, writer) = lock.withLock { () -> (SCStream?, CadenceWriter?) in
      let live = (self.stream, self.writer)
      self.stream = nil
      return live
    }

    guard let writer else {
      throw RecorderError.noFramesCaptured(outputURL)
    }
    writer.stopCadence()

    if let stream {
      do {
        try await stream.stopCapture()
      } catch {
        // Keep going: the file still has to be finalized, and a stream that is
        // already gone is exactly when that matters most.
        StandardError.write("DemoRecorder: stopCapture failed on display \(index): \(StandardError.describe(error))")
      }
    }
    // Let any in-flight sample handler finish before the writer is torn down.
    captureQueue.sync(flags: .barrier) { }
    return try await writer.finish()
  }

  public func stream(_: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    guard DisplayRecorder.isDeliverable(sampleBuffer, of: type) else { return }
    lock.lock()
    let target = writer
    lock.unlock()
    target?.submit(sampleBuffer)
  }

  public func stream(_: SCStream, didStopWithError error: any Error) {
    StandardError.write("DemoRecorder: stream for display \(index) stopped: \(StandardError.describe(error))")
    onFailure(error)
  }

  // MARK: Private

  private let options: RecorderOptions
  private let filter: SCContentFilter
  private let configuration: SCStreamConfiguration
  private let captureQueue: DispatchQueue
  private let onFailure: @Sendable (any Error) -> Void

  private let lock = NSLock()
  private var stream: SCStream?
  private var writer: CadenceWriter?

  private static func makeConfiguration(width: Int, height: Int, options: RecorderOptions) -> SCStreamConfiguration {
    let configuration = SCStreamConfiguration()
    // Leaving these unset would silently rescale the capture to the header
    // default of 1920x1080.
    configuration.width = width
    configuration.height = height
    // An upper bound on delivery, not a floor: ScreenCaptureKit still sends
    // nothing while the screen is still. The cadence clock supplies the floor.
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(options.fps))
    configuration.queueDepth = 6
    configuration.pixelFormat = kCVPixelFormatType_32BGRA
    configuration.colorSpaceName = CGColorSpace.sRGB
    configuration.showsCursor = options.showsCursor
    configuration.capturesAudio = false
    configuration.captureResolution = .best
    configuration.scalesToFit = false
    return configuration
  }

  /// Every one of these has to hold. An `.idle` buffer carries no samples and no
  /// image buffer; appending it puts `AVAssetWriter` into `.failed`, after which
  /// every later frame is silently lost and the file is unplayable.
  private static func isDeliverable(_ sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) -> Bool {
    guard type == .screen, sampleBuffer.isValid else { return false }
    guard
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]],
      let info = attachments.first,
      let rawStatus = info[.status] as? Int,
      let status = SCFrameStatus(rawValue: rawStatus)
    else { return false }
    guard CMSampleBufferGetNumSamples(sampleBuffer) > 0, sampleBuffer.imageBuffer != nil else { return false }
    // `.started` carries the first frame of the stream and, with an image buffer
    // present, is as usable as `.complete`.
    return status == .complete || status == .started
  }

  private static func evenFloor(_ value: Int) -> Int {
    max(2, value - (value % 2))
  }

}

// MARK: - StopResult

/// The outcome of stopping every stream in a session. Failures never hide a
/// file that did finalize, and a file that did not finalize never reads as
/// success.
public struct StopResult: Sendable {

  // MARK: Lifecycle

  public init(summaries: [RecordingSummary], failures: [String]) {
    self.summaries = summaries
    self.failures = failures
  }

  // MARK: Public

  public let summaries: [RecordingSummary]
  public let failures: [String]

}

// MARK: - RecordingSession

/// One take: one stream and one writer per selected display.
public final class RecordingSession: @unchecked Sendable {

  // MARK: Lifecycle

  public init(options: RecorderOptions) {
    self.options = options
  }

  // MARK: Public

  /// `onFailure` fires when a stream stops on its own — a display disconnecting,
  /// the window server revoking capture — so the take ends loudly instead of
  /// recording a frozen frame.
  public var firstFrameUptime: UInt64? {
    lock.withLock { recorders.compactMap(\.firstFrameUptime).min() }
  }

  public var outputOffsets: [String: Double] {
    lock.withLock {
      guard let origin = recorders.compactMap(\.firstFrameUptime).min() else {return [:]}
      return Dictionary(uniqueKeysWithValues: recorders.compactMap { recorder in
        guard let uptime = recorder.firstFrameUptime else {return nil}
        return (recorder.outputURL.lastPathComponent, Double(uptime-origin)/1_000_000_000)
      })
    }
  }

  public func start(onFailure: @escaping @Sendable (any Error) -> Void) async throws -> [StartedDisplay] {
    guard ScreenAccess.isGranted() else {
      throw RecorderError.noScreenRecordingAccess
    }
    let content = try await DisplayCatalog.shareableContent()
    let selected = try DisplayCatalog.select(options.display, from: content.displays)
    let ownProcess = content.applications.filter { $0.processID == getpid() }
    let urls = DisplayCatalog.outputURLs(
      base: options.output,
      indices: selected.map(\.index),
      suffixed: options.display == .all
    )

    var started: [StartedDisplay] = []
    var live: [DisplayRecorder] = []
    for (offset, selection) in selected.enumerated() {
      let recorder = DisplayRecorder(
        display: selection.display,
        index: selection.index,
        outputURL: urls[offset],
        options: options,
        excludedApplications: ownProcess,
        onFailure: onFailure
      )
      started.append(try await recorder.start())
      live.append(recorder)
      lock.withLock { recorders.append(recorder) }
    }

    // `SCStream.startCapture()` returns before the window server has delivered
    // anything, and the caller announces "capture started" the moment this
    // returns. Holding that announcement until a frame exists is what keeps a
    // take from beginning in the gap and losing its opening seconds.
    for recorder in live {
      let delivered = await recorder.awaitFirstFrame()
      guard !delivered else { continue }
      throw RecorderError.noFramesCaptured(recorder.outputURL)
    }
    return started
  }

  public func stop() async -> StopResult {
    let recorders = lock.withLock { () -> [DisplayRecorder] in
      let started = self.recorders
      self.recorders = []
      return started
    }

    var summaries: [RecordingSummary] = []
    var failures: [String] = []
    for recorder in recorders {
      do {
        summaries.append(try await recorder.stop())
      } catch {
        failures.append("display \(recorder.index): \(StandardError.describe(error))")
      }
    }
    return StopResult(summaries: summaries, failures: failures)
  }

  // MARK: Private

  private let options: RecorderOptions
  private let lock = NSLock()
  private var recorders: [DisplayRecorder] = []

}

// MARK: - RecorderController

/// The process shape around a take.
///
/// A CLI, but not a straight-line one: the capture delegate and the writer both
/// need a live run loop, so `main.swift` hands control to `dispatchMain()` and
/// every path out of the program goes through here. SIGINT and SIGTERM are
/// handled as dispatch sources rather than left at their default disposition —
/// exiting straight from a signal leaves the moov atom unwritten and the `.mov`
/// unplayable.
public final class RecorderController: @unchecked Sendable {

  // MARK: Lifecycle

  public init(options: RecorderOptions) {
    self.options = options
    session = RecordingSession(options: options)
  }

  // MARK: Public

  /// Installs the signal handling, starts the streams, and returns. The caller
  /// then parks the main thread in `dispatchMain()`.
  public func run() {
    // `dispatchMain()` never returns, so no caller's stack frame can own this
    // object. Without the anchor the controller — and with it the streams, the
    // writer, and the signal sources — would be released the moment `run()`
    // returned.
    RecorderController.liveLock.lock()
    RecorderController.live = self
    RecorderController.liveLock.unlock()
    installSignalSources()
    Task.detached { [self] in
      await startRecording()
    }
  }

  // MARK: Private

  private nonisolated(unsafe) static var live: RecorderController?
  private static let liveLock = NSLock()

  private let options: RecorderOptions
  private let controlQueue = DispatchQueue(label: "dev.pangmo5.demolab.recorder.control")
  private let lock = NSLock()

  private let session: RecordingSession

  private var signalSources: [DispatchSourceSignal] = []
  private var durationTimer: DispatchSourceTimer?
  private var isRunning = false
  private var stopRequested = false
  private var isStopping = false
  private var pidfileWritten: URL?

  private var recordedOutputs: [String] = []
  private var recordedFailures: [String] = []
  private var recordedStopReason: String?
  private var recordedStatistics: [String: [String: Int]] = [:]
  private var recordedFrameCount = 0
  private var recordedDroppedCount = 0
  private var recordedDuration = 0.0

  /// The only channel back to the caller. `democtl` launches the recorder
  /// detached through LaunchServices, so neither the exit code nor stderr ever
  /// reaches it; without this file a failed take is indistinguishable from a
  /// good one.
  private var resultFile: URL? {
    options.pidfile.map { $0.deletingPathExtension().appendingPathExtension("json") }
  }

  private func startRecording() async {
    // A result from an earlier run must never be mistaken for this one's: if
    // this process is killed before it writes its own, the caller has to find
    // nothing rather than somebody else's success.
    removeStaleResult()
    guard ScreenAccess.isGranted() else {
      StandardError.write(ScreenAccess.deniedMessage)
      noteFailure("no Screen Recording access")
      exitNow(.noScreenRecordingAccess)
    }
    do {
      let started = try await session.start(onFailure: { [weak self] error in
        self?.requestStop(reason: "stream failure: \(StandardError.describe(error))")
      })
      for display in started {
        let points = "\(Int(display.pointSize.width))x\(Int(display.pointSize.height)) pt"
        let pixels = "\(display.pixelWidth)x\(display.pixelHeight) px"
        let scale = String(format: "%.1fx", Double(display.pointPixelScale))
        print("recording display \(display.index) (id \(display.displayID), \(points) @\(scale)) "
          + "-> \(pixels) \(display.codec) -> \(display.outputURL.path)")
      }
      if started.count > 1 {
        print("note: ScreenCaptureKit has no multi-display stream, so each display is its own file;")
        print("      composite afterwards, e.g. ffmpeg -i a.mov -i b.mov -filter_complex hstack out.mov")
      }
      // There is a file to protect from here on, so a repeat stop has to be
      // absorbed rather than taken as the way out of a hung startup.
      lock.withLock { isRunning = true }
      // Load-bearing placement. `democtl` waits on this file as its "capture
      // really started" barrier, so it may only appear once every stream is live
      // and has produced a frame. Written any earlier — as it used to be — that
      // wait unblocks while ScreenCaptureKit is still negotiating, and the take
      // begins before the recording does.
      if let pidfile = options.pidfile, let uptime = session.firstFrameUptime {
        let ready = pidfile.deletingPathExtension().appendingPathExtension("ready.json")
        try JSONSerialization.data(withJSONObject: [
          "firstFrameUptimeNanoseconds": uptime, "outputOffsets": session.outputOffsets,
          "displays": Dictionary(uniqueKeysWithValues: started.map { display in
            (display.outputURL.lastPathComponent, ["id": Double(display.displayID), "x": CGDisplayBounds(display.displayID).minX, "y": CGDisplayBounds(display.displayID).minY])
          }),
        ])
          .write(to: ready, options: .atomic)
      }
      writePidfile()
      fflush(stdout)
    } catch {
      StandardError.write("DemoRecorder: \(StandardError.describe(error))")
      noteFailure(StandardError.describe(error))
      let failed = await session.stop()
      report(failed)
      exitNow(isAccessError(error) ? .noScreenRecordingAccess : .captureFailure)
    }

    if let seconds = options.durationSeconds {
      scheduleDurationStop(seconds)
    }
    // A stop that landed while the streams were coming up. `stopAndExit` is
    // idempotent, so racing the detached one `requestStop` may already have
    // spawned is harmless.
    let stopAlreadyRequested = lock.withLock { stopRequested }
    if stopAlreadyRequested {
      await stopAndExit(reason: "stop requested during startup")
    }
  }

  private func isAccessError(_ error: any Error) -> Bool {
    guard let recorderError = error as? RecorderError else { return false }
    if case .noScreenRecordingAccess = recorderError { return true }
    return false
  }

  private func installSignalSources() {
    var sources: [DispatchSourceSignal] = []
    for number in [SIGINT, SIGTERM] {
      // The dispatch source only sees the signal if the default disposition,
      // which would kill us mid-file, is disarmed first.
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: controlQueue)
      source.setEventHandler { [weak self] in
        self?.requestStop(reason: number == SIGINT ? "SIGINT" : "SIGTERM")
      }
      source.resume()
      sources.append(source)
    }
    lock.lock()
    signalSources = sources
    lock.unlock()
  }

  private func scheduleDurationStop(_ seconds: Double) {
    let timer = DispatchSource.makeTimerSource(queue: controlQueue)
    timer.schedule(deadline: .now() + seconds, leeway: .milliseconds(2))
    timer.setEventHandler { [weak self] in
      self?.requestStop(reason: String(format: "--duration-seconds %.3f elapsed", seconds))
    }
    lock.lock()
    durationTimer = timer
    lock.unlock()
    timer.resume()
  }

  /// Every stop funnels here, and only the first one wins: a second SIGINT
  /// while the file is being finalized must not tear it in half.
  private func requestStop(reason: String) {
    lock.lock()
    let repeated = stopRequested
    let running = isRunning
    stopRequested = true
    lock.unlock()

    if repeated {
      // A repeat while a file is being finalized is ignored on purpose: a torn
      // moov atom is worse than a slow exit. Before capture is live there is no
      // file to protect, so a second signal is the way out of a hung startup.
      guard !running else { return }
      StandardError.write("DemoRecorder: \(reason) during startup; exiting without a file")
      noteFailure("\(reason) during startup; no file was written")
      noteStopReason(reason)
      exitNow(.captureFailure)
    }
    // Not running yet: `startRecording()` picks the request up as soon as the
    // streams are live, so a half-built session is never torn down.
    guard running else { return }
    Task.detached { [self] in
      await stopAndExit(reason: reason)
    }
  }

  private func stopAndExit(reason: String) async {
    let alreadyStopping = lock.withLock { () -> Bool in
      let stopping = isStopping
      isStopping = true
      return stopping
    }
    guard !alreadyStopping else { return }

    print("stopping: \(reason)")
    noteStopReason(reason)
    let result = await session.stop()
    report(result)
    exitNow(result.failures.isEmpty && !result.summaries.isEmpty ? .ok : .captureFailure)
  }

  private func report(_ result: StopResult) {
    lock.lock()
    // The aggregate across every file of the take: `--display all` fans out into
    // one file per display, and the longest of them is the take's duration.
    recordedOutputs = result.summaries.map(\.outputURL.path)
    recordedStatistics = Dictionary(uniqueKeysWithValues: result.summaries.map {
      ($0.outputURL.lastPathComponent, ["frames": $0.frameCount, "dropped": $0.droppedFrameCount, "width": $0.width, "height": $0.height])
    })
    recordedFailures.append(contentsOf: result.failures)
    recordedFrameCount = result.summaries.reduce(0) { $0 + $1.frameCount }
    recordedDroppedCount = result.summaries.reduce(0) { $0 + $1.droppedFrameCount }
    recordedDuration = result.summaries.map(\.duration).max() ?? 0
    lock.unlock()

    for summary in result.summaries {
      print("wrote \(summary.outputURL.path)")
      print("  \(summary.width)x\(summary.height)  \(summary.codec)  "
        + String(format: "duration %.3f s", summary.duration)
        + "  frames \(summary.frameCount)  captured \(summary.capturedFrameCount)"
        + "  dropped \(summary.droppedFrameCount)")
    }
    if result.summaries.count > 1 {
      print("note: one file per display by design; composite afterwards, e.g. ffmpeg hstack")
    }
    for failure in result.failures {
      StandardError.write("DemoRecorder: \(failure)")
    }
    fflush(stdout)
  }

  private func writePidfile() {
    guard let pidfile = options.pidfile else {
      StandardError.write("DemoRecorder: no --pidfile given and DEMOLAB_ROOT is unset; "
        + "`democtl record stop` cannot signal this process")
      return
    }
    do {
      try FileManager.default.createDirectory(
        at: pidfile.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try Data("\(getpid())\n".utf8).write(to: pidfile, options: .atomic)
      lock.lock()
      pidfileWritten = pidfile
      lock.unlock()
    } catch {
      StandardError.write("DemoRecorder: could not write \(pidfile.path): \(StandardError.describe(error))")
      // Without the pidfile the caller can neither see this process nor signal
      // it, so carrying on would leave an orphan recording forever while
      // `democtl` times out waiting for a take that already started.
      noteFailure("pidfile unwritable; the caller could never stop this take")
      requestStop(reason: "pidfile unwritable")
    }
  }

  private func removePidfile() {
    lock.lock()
    let pidfile = pidfileWritten
    pidfileWritten = nil
    lock.unlock()
    guard let pidfile else { return }
    try? FileManager.default.removeItem(at: pidfile)
  }

  private func noteFailure(_ reason: String) {
    lock.lock()
    recordedFailures.append(reason)
    lock.unlock()
  }

  /// Only the first stop is the real one; later ones are shutdown noise.
  private func noteStopReason(_ reason: String) {
    lock.lock()
    if recordedStopReason == nil { recordedStopReason = reason }
    lock.unlock()
  }

  private func removeStaleResult() {
    guard let resultFile else { return }
    try? FileManager.default.removeItem(at: resultFile)
  }

  /// The take's outcome, for a caller that can read nothing else this process
  /// says. `status` is stricter than the exit code on purpose: a run that
  /// finalized no file, or that hit any failure at all, is not a usable take
  /// however it happened to exit.
  private func writeResult(_ code: RecorderExit) {
    guard let resultFile else { return }
    let (outputs, failures, stopReason, frames, dropped, duration) = lock.withLock {
      (recordedOutputs, recordedFailures, recordedStopReason, recordedFrameCount, recordedDroppedCount, recordedDuration)
    }
    let succeeded = code == .ok && failures.isEmpty && !outputs.isEmpty
    var payload: [String: Any] = [
      "status": succeeded ? "ok" : "failed",
      "code": Int(code.rawValue),
      "outputs": outputs,
      "error": NSNull(),
      "stopReason": NSNull(),
      "outputStatistics": lock.withLock {recordedStatistics},
      "frames": frames,
      "dropped": dropped,
      "durationSeconds": duration,
    ]
    if !failures.isEmpty { payload["error"] = failures.joined(separator: "; ") }
    if let stopReason { payload["stopReason"] = stopReason }
    do {
      let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
      try FileManager.default.createDirectory(
        at: resultFile.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      // `.atomic` is a write to a sibling temp file plus a rename, so a caller
      // racing this exit reads the whole file or no file, never half of one.
      try data.write(to: resultFile, options: .atomic)
    } catch {
      StandardError.write("DemoRecorder: could not write \(resultFile.path): \(StandardError.describe(error))")
    }
  }

  private func exitNow(_ code: RecorderExit) -> Never {
    // Order is the contract: `democtl` treats the pidfile disappearing as "the
    // take is over" and reads the result straight afterwards, so the result has
    // to be on disk before the pidfile goes.
    writeResult(code)
    removePidfile()
    fflush(stdout)
    exit(code.rawValue)
  }

}
