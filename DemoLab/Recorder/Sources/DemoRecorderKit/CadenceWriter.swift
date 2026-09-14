// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

// MARK: - RecordingSummary

/// What one finished file turned out to be.
public struct RecordingSummary: Sendable {

  // MARK: Lifecycle

  public init(
    outputURL: URL,
    width: Int,
    height: Int,
    codec: String,
    frameCount: Int,
    capturedFrameCount: Int,
    droppedFrameCount: Int,
    duration: Double
  ) {
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.codec = codec
    self.frameCount = frameCount
    self.capturedFrameCount = capturedFrameCount
    self.droppedFrameCount = droppedFrameCount
    self.duration = duration
  }

  // MARK: Public

  public let outputURL: URL
  public let width: Int
  public let height: Int
  public let codec: String
  /// Frames written to the file: cadence ticks, not capture callbacks.
  public let frameCount: Int
  /// Frames ScreenCaptureKit actually delivered. Lower than `frameCount` on a
  /// still screen, which is the cadence doing its job.
  public let capturedFrameCount: Int
  public let droppedFrameCount: Int
  public let duration: Double

}

// MARK: - CadenceWriter

/// A fixed-rate encoder placed in front of an event-driven capture source.
///
/// This is the load-bearing decision of the recorder. ScreenCaptureKit only
/// delivers a frame when something on screen changes, so appending capture
/// buffers as they arrive turns a ten second take of a still desktop into a
/// thirty millisecond file. This class inverts the relationship: a
/// The producer submits a Metal copy of the latest real BGRA pixels at each
/// cadence tick into its bounded pool, preserving the timestamp. An
/// independent encoder queue drains those copies when the writer is ready.
/// Backpressure cannot replace an earlier image with a later image or discard
/// an existing copy. Missed producer ticks remain explicit timestamp gaps.
///
/// The capture callback only swaps the latest-buffer slot under a lock and
/// returns. Encoding on ScreenCaptureKit's own sample handler queue drains the
/// IOSurface pool and stalls capture, so no work beyond the swap happens there.
///
/// Only the latest SCK buffer is retained. Queued images are deep copies, so
/// encoder backpressure cannot exhaust ScreenCaptureKit's IOSurface pool.
public final class CadenceWriter: @unchecked Sendable {

  // MARK: Lifecycle

  public init(
    outputURL: URL,
    width: Int,
    height: Int,
    fps: Int,
    requestedCodec: RecordingCodec = .hevc,
    bitrateMbps: Double?,
    label: String
  ) throws {
    self.outputURL = outputURL
    self.width = width
    self.height = height
    self.fps = fps
    frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
    cadenceQueue = DispatchQueue(label: "dev.pangmo5.demolab.recorder.cadence.\(label)", qos: .userInitiated)
    encoderQueue = DispatchQueue(label: "dev.pangmo5.demolab.recorder.encoder.\(label)", qos: .userInitiated)
    let copyPool = try MetalFrameCopier(width: width, height: height, fps: fps)
    self.copyPool = copyPool
    pendingFrames = BoundedFrameQueue(capacity: copyPool.capacity)

    try FileManager.default.createDirectory(
      at: outputURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
    writer.movieTimeScale = CMTimeScale(fps * 1000)

    let chosenCodec: AVVideoCodecType = requestedCodec == .hevc ? .hevc : .h264
    let settings = CadenceWriter.videoSettings(
      codec: chosenCodec,
      width: width,
      height: height,
      fps: fps,
      bitrateMbps: bitrateMbps
    )
    guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
      throw RecorderError.codecUnavailable(codec: requestedCodec, width: width, height: height)
    }

    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    // Set before `startWriting()`: it tells the writer the source is live and
    // must not be waited on. macOS 26 deprecates this in favour of a 26-only
    // replacement; we target macOS 14, so the deprecation warning stays.
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else {
      throw RecorderError.writerSetupFailed("AVAssetWriter refused the video input for \(width)x\(height)")
    }
    writer.add(input)

    self.writer = writer
    self.input = input
    adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
    codec = CadenceWriter.name(for: chosenCodec)
  }

  // MARK: Public

  public let outputURL: URL
  public let width: Int
  public let height: Int
  /// `hevc` or `h264`, whichever the writer accepted.
  public let codec: String

  /// Starts the writer and the cadence clock. Call once, after capture is live.
  public func start() throws {
    guard writer.startWriting() else {
      throw RecorderError.writerSetupFailed(CadenceWriter.reason(writer.error))
    }
    // `.strict` keeps the timer out of dispatch's coalescing window; a leeway of
    // zero is what makes the cadence a clock rather than a hint.
    let timer = DispatchSource.makeTimerSource(flags: [.strict], queue: cadenceQueue)
    timer.schedule(
      deadline: .now(),
      repeating: .nanoseconds(1_000_000_000 / fps),
      leeway: .nanoseconds(0)
    )
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    lock.lock()
    cadenceTimer = timer
    lock.unlock()
    timer.resume()
  }

  /// Called on ScreenCaptureKit's sample handler queue. Stays O(1) by design.
  public func submit(_ sampleBuffer: CMSampleBuffer) {
    lock.lock()
    if !producerStopped {
      latestBuffer = sampleBuffer
      capturedFrameCount += 1
    }
    lock.unlock()
  }

  /// Startup succeeds only after the first encoded frame. The bounded wait
  /// turns a stalled capture stream into an explicit failure before any action.
  public var firstFrameUptime: UInt64? { lock.withLock { startUptime } }

  public func awaitFirstFrame(timeout: Duration = .seconds(3)) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
      if lock.withLock({ appendedFrameCount > 0 }) { return true }
      if lock.withLock({ failureReason != nil }) { return false }
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// Step 1 of the shutdown sequence. Idempotent.
  public func stopCadence() {
    lock.lock()
    let timer = cadenceTimer
    cadenceTimer = nil
    producerStopped = true
    lock.unlock()
    timer?.cancel()
    // Finish an in-flight copy before closing the producer. Encoding continues
    // independently until every previously collected frame is acknowledged.
    cadenceQueue.sync(flags: .barrier) { }
    lock.withLock {
      latestBuffer = nil
      pendingFrames.finishProducing()
    }
  }

  /// Steps 4 to 7 of the shutdown sequence: finish the input, end the session,
  /// finalize the file, and verify the writer actually completed.
  public func finish() async throws -> RecordingSummary {
    stopCadence()
    do {
      try await copyPool.awaitAllCopies()
    } catch {
      fail("GPU copy shutdown failed: \(error)")
      encoderQueue.sync(flags: .barrier) { }
      writer.cancelWriting()
      throw error
    }
    let drainDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    while true {
      let state = lock.withLock { (pendingFrames.isDrained, failureReason) }
      if let failure = state.1 {
        encoderQueue.sync(flags: .barrier) { }
        writer.cancelWriting()
        throw RecorderError.writerFailed(failure)
      }
      if state.0 { break }
      guard ContinuousClock.now < drainDeadline else {
        fail("Encoder did not drain collected frames within 5 seconds")
        encoderQueue.sync(flags: .barrier) { }
        writer.cancelWriting()
        throw RecorderError.writerFailed("Encoder did not drain collected frames within 5 seconds")
      }
      try? await Task.sleep(for: .milliseconds(5))
    }
    // The acknowledgement of the last queued frame precedes its encoder
    // block's return. Wait for that block before ending the writer session.
    encoderQueue.sync(flags: .barrier) { }

    // `withLock`, not lock/unlock: `NSLock.lock()` is unavailable from an
    // async context.
    let (frames, captured, dropped, start, last) = lock.withLock {
      latestBuffer = nil
      return (appendedFrameCount, capturedFrameCount, accounting.droppedFrameCount, startPTS, lastPresentationTime)
    }
    // Emit after cadence has stopped: diagnostic file I/O must not perturb the
    // timing being measured during the recording.
    for diagnostic in cadenceDiagnostics { StandardError.write(diagnostic) }
    for diagnostic in copyPool.slowOperations { StandardError.write(diagnostic) }
    StandardError.write("copy slow_operation_threshold_seconds=0.005 omitted_slow_operations=\(copyPool.omittedSlowOperations)")
    StandardError.write("cadence totals skipped_slots=\(accounting.skippedFrameCount) rejected_slots=\(accounting.rejectedFrameCount) encoder_backpressure_periods=\(backpressurePeriods) maximum_queue_depth=\(maximumQueueDepth) queue_capacity=\(copyPool.capacity) pool_allocation_limit=\(copyPool.allocationLimit)")

    guard let start, frames > 0 else {
      // Finalizing here would write a .mov with no video samples, which reads as
      // a successful take until someone opens it. Fail loudly instead.
      writer.cancelWriting()
      throw RecorderError.noFramesCaptured(outputURL)
    }

    input.markAsFinished()
    let end = CMTimeAdd(last, frameDuration)
    writer.endSession(atSourceTime: end)
    await finishWriting()

    guard writer.status == .completed else {
      throw RecorderError.writerFailed(CadenceWriter.reason(writer.error))
    }
    return RecordingSummary(
      outputURL: outputURL,
      width: width,
      height: height,
      codec: codec,
      frameCount: frames,
      capturedFrameCount: captured,
      droppedFrameCount: dropped,
      duration: CMTimeGetSeconds(CMTimeSubtract(end, start))
    )
  }

  // MARK: Private

  private let fps: Int
  private let frameDuration: CMTime
  private let writer: AVAssetWriter
  private let input: AVAssetWriterInput
  private let adaptor: AVAssetWriterInputPixelBufferAdaptor
  private let cadenceQueue: DispatchQueue
  private let encoderQueue: DispatchQueue
  private let copyPool: MetalFrameCopier

  private let lock = NSLock()
  /// The single retained capture buffer. Replaced, never consumed: a still
  /// screen keeps re-encoding the last frame it produced.
  private var latestBuffer: CMSampleBuffer?
  private var cadenceTimer: DispatchSourceTimer?
  private var startPTS: CMTime?
  private var startUptime: UInt64?
  private var lastPresentationTime = CMTime.zero
  private var accounting = CadenceAccounting()
  private var cadenceDiagnostics: [String] = []
  private var pendingFrames: BoundedFrameQueue<MetalCopiedFrame>
  private var encoderDrainScheduled = false
  private var maximumQueueDepth = 0
  private var backpressurePeriods = 0
  private var backpressureStart: UInt64?
  private var appendedFrameCount = 0
  private var capturedFrameCount = 0
  private var hasStartedSession = false
  private var producerStopped = false
  private var failureReason: String?

  private static func videoSettings(
    codec: AVVideoCodecType,
    width: Int,
    height: Int,
    fps: Int,
    bitrateMbps: Double?
  ) -> [String: Any] {
    let bitrate = bitrateMbps.map { Int($0 * 1_000_000) }
      ?? defaultBitrate(width: width, height: height, fps: fps, codec: codec)
    var compression: [String: Any] = [
      AVVideoAverageBitRateKey: bitrate,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: fps * 2,
      // Screen content is encoded live and scrubbed frame by frame; B-frames buy
      // nothing here and cost latency.
      AVVideoAllowFrameReorderingKey: false,
    ]
    if codec == .h264 {
      compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
    }
    return [
      AVVideoCodecKey: codec,
      AVVideoWidthKey: width,
      AVVideoHeightKey: height,
      AVVideoCompressionPropertiesKey: compression,
      AVVideoColorPropertiesKey: [
        AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
        AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
      ],
    ]
  }

  /// Bits per pixel per frame, clamped so a 5K panel does not ask for a
  /// gigabit and a small window does not look like a fax.
  private static func defaultBitrate(width: Int, height: Int, fps: Int, codec: AVVideoCodecType) -> Int {
    let bitsPerPixel = codec == .hevc ? 0.09 : 0.16
    let raw = Double(width * height) * Double(fps) * bitsPerPixel
    return Int(min(max(raw, 8_000_000), 120_000_000))
  }

  /// The raw values are the fourcc codes `hvc1` and `avc1`; the log says what a
  /// person would call them.
  private static func name(for codec: AVVideoCodecType) -> String {
    codec == .hevc ? "hevc" : "h264"
  }

  private static func reason(_ error: (any Error)?) -> String {
    guard let error else { return "no error reported" }
    return StandardError.describe(error)
  }

  /// `AVAssetWriter` still exposes the deprecated synchronous `finishWriting()`
  /// next to the completion-handler form, so the bridge is spelled out rather
  /// than left to overload resolution.
  private func finishWriting() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      writer.finishWriting {
        continuation.resume()
      }
    }
  }

  private func tick() {
    lock.lock()
    let source = latestBuffer
    let stopped = producerStopped || failureReason != nil
    lock.unlock()

    // Before the first capture frame there is nothing to duplicate; the session
    // starts at the first frame that actually exists.
    guard !stopped, let source else { return }

    let now = DispatchTime.now().uptimeNanoseconds
    lock.lock()
    if startPTS == nil {
      startPTS = source.presentationTimeStamp
      startUptime = now
    }
    let startedAt = startUptime ?? now
    // Missed ticks (a stalled encoder, a busy machine) advance the index by
    // wall-clock time rather than by one, so the file's duration keeps matching
    // the take instead of quietly shrinking.
    let elapsed = Double(now &- startedAt) / 1_000_000_000
    let skippedBefore = accounting.skippedFrameCount
    let target = accounting.reserve(elapsed: elapsed, fps: fps)
    let skipped = accounting.skippedFrameCount - skippedBefore
    if skipped > 0 {
      cadenceDiagnostics.append("cadence elapsed=\(elapsed) frame_index=\(target) skipped_slots=\(skipped)")
    }
    lock.unlock()
    do {
      guard let sourceImage = CMSampleBufferGetImageBuffer(source) else {
        throw RecorderError.writerFailed("Capture sample has no image buffer")
      }
      let copy = try copyPool.copy(sourceImage, frameIndex: target)
      let schedule = try lock.withLock {
        try pendingFrames.enqueue(index: target, payload: copy)
        maximumQueueDepth = max(maximumQueueDepth, pendingFrames.count)
        guard !encoderDrainScheduled else { return false }
        encoderDrainScheduled = true
        return true
      }
      if schedule { encoderQueue.async { [weak self] in self?.drainEncoder() } }
    } catch {
      lock.withLock { accounting.rejectReservedFrame() }
      fail("Could not preserve cadence frame \(target): \(error)")
    }
  }

  /// There is at most one active or scheduled drain. The producer never waits
  /// for readiness and the encoder never substitutes a later frame's pixels.
  private func drainEncoder() {
    while true {
      let frame = lock.withLock { () -> BoundedFrameQueue<MetalCopiedFrame>.Frame? in
        guard failureReason == nil, let frame = pendingFrames.next(encoderReady: true) else {
          encoderDrainScheduled = false
          return nil
        }
        return frame
      }
      guard let frame else { return }
      switch frame.payload.state {
      case .pending:
        encoderQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.drainEncoder() }
        return
      case .failed(let reason):
        fail(reason)
        return
      case .completed:
        break
      }
      let now = DispatchTime.now().uptimeNanoseconds
      guard input.isReadyForMoreMediaData else {
        lock.withLock {
          if backpressureStart == nil {
            backpressureStart = now
            backpressurePeriods += 1
            cadenceDiagnostics.append("encoder waiting frame_index=\(frame.index) queue_depth=\(pendingFrames.count)")
          }
        }
        encoderQueue.asyncAfter(deadline: .now() + .milliseconds(5)) { [weak self] in self?.drainEncoder() }
        return
      }
      let start = lock.withLock { () -> CMTime in
        if let waitedFrom = backpressureStart {
          cadenceDiagnostics.append("encoder resumed wait_seconds=\(Double(now &- waitedFrom) / 1_000_000_000) queue_depth=\(pendingFrames.count)")
          backpressureStart = nil
        }
        return startPTS ?? .zero
      }
      if !hasStartedSession {
        writer.startSession(atSourceTime: start)
        hasStartedSession = true
      }
      let presentationTime = CMTimeAdd(start, CMTime(value: CMTimeValue(frame.index), timescale: CMTimeScale(fps)))
      guard adaptor.append(frame.payload.pixelBuffer, withPresentationTime: presentationTime) else {
        lock.withLock { accounting.rejectReservedFrame() }
        fail("Encoder append failed: \(CadenceWriter.reason(writer.error))")
        return
      }
      do {
        try lock.withLock {
          try pendingFrames.acknowledge(index: frame.index)
          appendedFrameCount += 1
          lastPresentationTime = presentationTime
        }
      } catch {
        fail("Encoder queue acknowledgement failed: \(error)")
        return
      }
    }
  }

  private func fail(_ reason: String) {
    let firstFailure = lock.withLock {
      guard failureReason == nil else { return false }
      failureReason = reason
      return true
    }
    if firstFailure { StandardError.write("DemoRecorder: \(reason)") }
  }

}
