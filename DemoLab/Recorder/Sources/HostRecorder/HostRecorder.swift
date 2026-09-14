// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import AVFoundation
import CryptoKit
import DemoRecorderKit
import Foundation
import ScreenCaptureKit

// MARK: - Viewport

private struct Viewport: Codable {
  let ownerPID: Int32
  let windowID: UInt32
  let displayID: UInt32
  let title: String
  let x: Double
  let y: Double
  let width: Double
  let height: Double
  let scale: Double
}

// MARK: - WindowCapture

private final class WindowCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

  // MARK: Lifecycle

  init(writer: CadenceWriter) {
    self.writer = writer
  }

  // MARK: Internal

  let writer: CadenceWriter
  let queue = DispatchQueue(label: "swiftycrow.host.capture", qos: .userInitiated)
  let lock = NSLock()
  var failure: String?

  func stream(_: SCStream, didStopWithError error: any Error) {
    lock.withLock { failure = String(describing: error) }
  }

  func stream(_: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
    guard
      type == .screen, sample.isValid, sample.imageBuffer != nil,
      let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
      let raw = attachments.first?[.status] as? Int,
      let status = SCFrameStatus(rawValue: raw), status == .complete || status == .started
    else { return }
    writer.submit(sample)
  }
}

// MARK: - HostService

private actor HostService {

  // MARK: Lifecycle

  init(root: URL, viewport: Viewport, binaryHash: String) {
    self.root = root
    self.viewport = viewport
    self.binaryHash = binaryHash
  }

  // MARK: Internal

  let root: URL
  let viewport: Viewport
  let binaryHash: String
  var stream: SCStream?
  var capture: WindowCapture?
  var windowFrame: CGRect?
  var takeID: String?
  var takeStarted: UInt64?

  func verifyWindow() async throws -> (SCWindow, SCDisplay) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    guard
      let window = content.windows.first(where: {
        $0.windowID == viewport.windowID && $0.owningApplication?.processID == viewport.ownerPID && $0.title == viewport.title
      }), let display = content.displays.first(where: { $0.displayID == viewport.displayID })
    else {
      throw UsageError("Owned VM window is unavailable")
    }
    let source = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
      .offsetBy(dx: display.frame.minX, dy: display.frame.minY)
    guard
      window.frame.contains(source), display.frame.contains(source),
      abs(viewport.width * viewport.scale - 1920) < 0.001,
      abs(viewport.height * viewport.scale - 1200) < 0.001
    else {
      throw UsageError("Owned viewport must contain all 1920x1200 native pixels")
    }
    return (window, display)
  }

  func start(id: String) async throws -> [String: Any] {
    guard capture == nil, UUID(uuidString: id) != nil else { throw UsageError("Invalid or overlapping take") }
    guard ScreenAccess.isGranted() else { throw RecorderError.noScreenRecordingAccess }
    let (window, display) = try await verifyWindow()
    let filter = SCContentFilter(display: display, including: [window])
    guard abs(Double(filter.pointPixelScale) - viewport.scale) < 0.001 else { throw UsageError("Backing scale changed") }
    let directory = root.appendingPathComponent("takes/" + id)
    guard !FileManager.default.fileExists(atPath: directory.path) else { throw UsageError("Take already exists") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let writer = try CadenceWriter(
      outputURL: directory.appendingPathComponent("capture-demo.mov"),
      width: 1920,
      height: 1200,
      fps: 30,
      requestedCodec: .hevc,
      bitrateMbps: 8,
      label: "host-owned-VM"
    )
    let capture = WindowCapture(writer: writer)
    let config = SCStreamConfiguration()
    config.sourceRect = CGRect(x: viewport.x, y: viewport.y, width: viewport.width, height: viewport.height)
    config.width = 1920
    config.height = 1200
    config.scalesToFit = false
    config.captureResolution = .best
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    config.queueDepth = 6
    config.showsCursor = true
    config.capturesAudio = false
    let stream = SCStream(filter: filter, configuration: config, delegate: capture)
    try stream.addStreamOutput(capture, type: .screen, sampleHandlerQueue: capture.queue)
    self.stream = stream
    self.capture = capture
    windowFrame = window.frame
    takeID = id
    try await stream.startCapture()
    try writer.start()
    guard await writer.awaitFirstFrame(), let epoch = writer.firstFrameUptime else {
      throw UsageError("Host camera did not capture its first frame")
    }
    takeStarted = epoch
    let ready: [String: Any] = [
      "firstFrameUptimeNanoseconds": epoch,
      "clockDomain": "host DispatchTime",
      "hostRecorderSHA256": binaryHash,
      "viewport": try JSONSerialization.jsonObject(with: JSONEncoder().encode(viewport)),
      "width": 1920,
      "height": 1200,
      "fps": 30,
      "showsHostCursor": true,
    ]
    try write(ready, to: directory.appendingPathComponent("capture-demo.host-ready.json"))
    return ready
  }

  func stop(id: String) async throws -> [String: Any] {
    guard id == takeID, let capture, let stream else { throw UsageError("No matching active take") }
    capture.writer.stopCadence()
    try await stream.stopCapture()
    capture.queue.sync(flags: .barrier) { }
    let summary = try await capture.writer.finish()
    let (window, _) = try await verifyWindow()
    let failure = capture.lock.withLock { capture.failure }
    guard window.frame == windowFrame, failure == nil else { throw UsageError(failure ?? "Window geometry changed") }
    let result: [String: Any] = [
      "status": "ok",
      "code": 0,
      "error": NSNull(),
      "stopReason": "guest story completed",
      "frames": summary.frameCount,
      "dropped": summary.droppedFrameCount,
      "captured": summary.capturedFrameCount,
      "durationSeconds": summary.duration,
      "outputs": [summary.outputURL.path],
      "geometryUnchanged": true,
      "width": summary.width,
      "height": summary.height,
      "hostRecorderSHA256": binaryHash,
    ]
    try write(result, to: summary.outputURL.deletingPathExtension().appendingPathExtension("json"))
    self.capture = nil
    self.stream = nil
    takeID = nil
    takeStarted = nil
    return result
  }

  func run() async throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = try await verifyWindow()
    print("Host camera service ready: \(root.path)")
    fflush(stdout)
    while true {
      if let started = takeStarted, Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9 > 120 {
        if let takeID { _ = try await stop(id: takeID) }
        throw UsageError("Guest did not stop the take within 120 seconds")
      }
      let requests = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasSuffix(".request.json") }.sorted { $0.path < $1.path }
      for requestURL in requests {
        let responseURL = root.appendingPathComponent(requestURL.lastPathComponent.replacingOccurrences(
          of: ".request.json",
          with: ".response.json"
        ))
        do {
          guard
            let request = try JSONSerialization.jsonObject(with: Data(contentsOf: requestURL)) as? [String: Any],
            let operation = request["operation"] as? String
          else { throw UsageError("Malformed request") }
          let response: [String: Any]
          switch operation {
          case "start": response = try await start(id: request["takeID"] as? String ?? "")
          case "stop": response = try await stop(id: request["takeID"] as? String ?? "")
          default: throw UsageError("Unknown camera operation")
          }
          try write(response, to: responseURL)
        } catch {
          try write(["error": String(describing: error)], to: responseURL)
          if capture != nil { throw error }
        }
        try FileManager.default.removeItem(at: requestURL)
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }
}

private func write(_ object: [String: Any], to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: url, options: .atomic)
}

// MARK: - HostRecorderMain

@main
enum HostRecorderMain {
  static func main() {
    guard CommandLine.arguments.count == 3 else {
      StandardError.write("HostRecorder viewport.json shared-control-directory")
      exit(2)
    }
    do {
      let viewport = try JSONDecoder().decode(
        Viewport.self,
        from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      )
      let hash = SHA256.hash(data: try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]))).map { String(
        format: "%02x",
        $0
      ) }.joined()
      let service = HostService(root: URL(fileURLWithPath: CommandLine.arguments[2]), viewport: viewport, binaryHash: hash)
      Task {
        do { try await service.run() } catch { StandardError.write(String(describing: error))
          exit(4)
        }
      }
      dispatchMain()
    } catch { StandardError.write(String(describing: error))
      exit(2)
    }
  }
}
