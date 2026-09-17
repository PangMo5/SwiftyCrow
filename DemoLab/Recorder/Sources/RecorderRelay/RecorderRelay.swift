// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import DemoDriverKit
import DemoRecorderKit
import Foundation

// MARK: - ClockSample

private struct ClockSample: Codable {
  let guestBefore: UInt64
  let host: UInt64
  let guestAfter: UInt64

  var roundTrip: Double {
    Double(guestAfter - guestBefore)
  }

  var guestMinusHost: Double {
    Double(guestBefore) + roundTrip / 2 - Double(host)
  }
}

// MARK: - Relay

private final class Relay: @unchecked Sendable {

  // MARK: Lifecycle

  init(root: URL, options: RecorderOptions) {
    self.root = root
    self.options = options
  }

  // MARK: Internal

  let root: URL
  let options: RecorderOptions
  let takeID = UUID().uuidString
  let lock = NSLock()
  var stopped = false
  var signals = [DispatchSourceSignal]()

  func request(_ operation: String, timeout: Double = 10) throws -> [String: Any] {
    let id = UUID().uuidString
    let input = root.appendingPathComponent(id + ".request.json")
    let output = root.appendingPathComponent(id + ".response.json")
    try write(["operation": operation, "takeID": takeID], to: input)
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !FileManager.default.fileExists(atPath: output.path) {
      guard ProcessInfo.processInfo.systemUptime < deadline
      else { throw UsageError("Host camera request timed out: " + operation) }
      Thread.sleep(forTimeInterval: 0.002)
    }
    guard let response = try JSONSerialization.jsonObject(with: Data(contentsOf: output)) as? [String: Any] else {
      throw UsageError("Malformed host response")
    }
    try FileManager.default.removeItem(at: output)
    if let error = response["error"] as? String { throw UsageError(error) }
    return response
  }

  func sampleClocks() throws -> [ClockSample] {
    try (0..<9).map { _ in
      let before = DispatchTime.now().uptimeNanoseconds
      let host = try HostMouseRelayClient.clockUptimeNanoseconds()
      let after = DispatchTime.now().uptimeNanoseconds
      return ClockSample(guestBefore: before, host: host, guestAfter: after)
    }
  }

  func run() throws {
    guard
      options.fps == 30, options.codec == .hevc, options.bitrateMbps == 8,
      let pidfile = options.pidfile
    else { throw UsageError("Host relay requires 30 fps HEVC 8 Mbps and a pidfile") }
    guard
      FileManager.default.fileExists(atPath: root.path),
      !FileManager.default.fileExists(atPath: options.output.path)
    else { throw UsageError("Missing shared control directory or output already exists") }
    for number in [SIGINT, SIGTERM] {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
      source.setEventHandler { [self] in lock.withLock { stopped = true } }
      source.resume()
      signals.append(source)
    }
    try String(getpid()).write(to: pidfile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: pidfile) }
    let beforeSamples = try sampleClocks()
    let before = beforeSamples.min { $0.roundTrip < $1.roundTrip }!
    try write([
      "samples": try JSONSerialization.jsonObject(with: JSONEncoder().encode(beforeSamples)),
      "minimumRoundTripNanoseconds": before.roundTrip,
    ], to: options.output.deletingPathExtension().appendingPathExtension("clock-before.json"))
    guard before.roundTrip < 20_000_000 else {
      throw UsageError("Guest-host clock uncertainty is too large: minimum RTT \(before.roundTrip / 1e6) ms")
    }
    var hostReady = try request("start")
    var active = true
    defer { if active { _ = try? request("stop", timeout: 30) } }
    guard let hostEpoch = hostReady["firstFrameUptimeNanoseconds"] as? NSNumber
    else { throw UsageError("Host has no first frame") }
    let guestEpoch = hostEpoch.doubleValue + before.guestMinusHost
    guard guestEpoch > 0 else { throw UsageError("Mapped guest clock is invalid") }
    let mappedEpoch = UInt64(guestEpoch.rounded())
    let rawReadyURL = options.output.deletingPathExtension().appendingPathExtension("host-ready.json")
    try write(hostReady, to: rawReadyURL)
    hostReady["hostFirstFrameUptimeNanoseconds"] = hostEpoch
    hostReady["firstFrameUptimeNanoseconds"] = mappedEpoch
    hostReady["clockDomain"] = "guest DispatchTime mapped from host using measured RTT"
    hostReady["clockUncertaintyNanoseconds"] = before.roundTrip / 2
    try write(hostReady, to: pidfile.deletingPathExtension().appendingPathExtension("ready.json"))
    print("Host camera first frame mapped into guest clock")
    fflush(stdout)
    let deadline = ProcessInfo.processInfo.systemUptime + 115
    while !lock.withLock({ stopped }) {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageError("Story did not stop recorder") }
      Thread.sleep(forTimeInterval: 0.02)
    }
    var result = try request("stop", timeout: 30)
    active = false
    let afterSamples = try sampleClocks()
    let after = afterSamples.min { $0.roundTrip < $1.roundTrip }!
    let bound = abs(after.guestMinusHost - before.guestMinusHost) + (before.roundTrip + after.roundTrip) / 2
    let clockURL = options.output.deletingPathExtension().appendingPathExtension("clock.json")
    try write([
      "before": try JSONSerialization.jsonObject(with: JSONEncoder().encode(beforeSamples)),
      "after": try JSONSerialization.jsonObject(with: JSONEncoder().encode(afterSamples)),
      "maximumAlignmentErrorNanoseconds": bound,
      "limitNanoseconds": 1e9 / 30,
      "mappedFirstFrameUptimeNanoseconds": mappedEpoch,
    ], to: clockURL)
    guard after.roundTrip < 20_000_000, bound < 1e9 / 30 else { throw UsageError("Guest-host clock drift exceeds one frame") }
    let hostTake = root.appendingPathComponent("takes/" + takeID)
    try FileManager.default.copyItem(at: hostTake.appendingPathComponent("capture-demo.mov"), to: options.output)
    result["hostOutputs"] = result["outputs"]
    result["outputs"] = [options.output.path]
    result["clockAlignmentMaximumErrorNanoseconds"] = bound
    result["hostTakeID"] = takeID
    try write(result, to: options.output.deletingPathExtension().appendingPathExtension("json"))
    print("Host recording finalized with clock alignment verified")
  }
}

private func write(_ object: [String: Any], to url: URL) throws {
  try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
}

// MARK: - RecorderRelayMain

@main
enum RecorderRelayMain {
  static func main() {
    do {
      guard
        case .record(let options) = try RecorderCommand.parse(Array(CommandLine.arguments.dropFirst())),
        let root = ProcessInfo.processInfo.environment["SWIFTYCROW_HOST_CAPTURE_ROOT"]
      else {
        throw UsageError("RecorderRelay requires recorder arguments and SWIFTYCROW_HOST_CAPTURE_ROOT")
      }
      try Relay(root: URL(fileURLWithPath: root), options: options).run()
    } catch { StandardError.write(String(describing: error))
      exit(4)
    }
  }
}
