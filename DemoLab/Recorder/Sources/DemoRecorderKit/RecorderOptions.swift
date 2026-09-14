// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Foundation

// MARK: - RecorderExit

/// Process exit codes. `democtl` and the VM bootstrap branch on these, so they
/// are part of the tool's contract and must not be renumbered.
public enum RecorderExit: Int32, Sendable {
  case ok = 0
  case usage = 2
  case noScreenRecordingAccess = 3
  case captureFailure = 4
}

// MARK: - DisplaySelection

/// Which display(s) a take covers.
public enum DisplaySelection: Sendable, Equatable {
  case main
  /// A specific `CGDirectDisplayID`. The unambiguous form, and the one
  /// `democtl` always sends: a positional index depends on which enumeration
  /// you are counting, and the recorder's ScreenCaptureKit order is not the
  /// NSScreen order `democtl displays` prints.
  case identifier(CGDirectDisplayID)
  /// 1-based, matching `--list-displays` and the `-1`, `-2` output suffixes.
  case index(Int)
  case all
}

// MARK: - RecorderOptions

public enum RecordingCodec: String, Sendable {
  case hevc
  case h264
}

/// Everything a recording run needs. Parsed once, then immutable.
public struct RecorderOptions: Sendable {

  // MARK: Lifecycle

  public init(
    output: URL,
    display: DisplaySelection = .main,
    fps: Int = 60,
    codec: RecordingCodec = .hevc,
    durationSeconds: Double? = nil,
    bitrateMbps: Double? = nil,
    showsCursor: Bool = true,
    pidfile: URL? = nil
  ) {
    self.output = output
    self.display = display
    self.fps = fps
    self.codec = codec
    self.durationSeconds = durationSeconds
    self.bitrateMbps = bitrateMbps
    self.showsCursor = showsCursor
    self.pidfile = pidfile
  }

  // MARK: Public

  /// `democtl` passes `--pidfile` explicitly. This fallback keeps a hand-run
  /// recorder signalable and mirrors `LabPaths.recorderPidFile`.
  public static func defaultPidfile() -> URL? {
    guard let root = ProcessInfo.processInfo.environment["DEMOLAB_ROOT"], !root.isEmpty else {
      return nil
    }
    return URL(fileURLWithPath: root, isDirectory: true)
      .appendingPathComponent(".build/lab/run/recorder.pid")
  }

  public let output: URL
  public let display: DisplaySelection
  /// Drives the cadence clock, the capture ceiling, and the encoder hints alike.
  public let fps: Int
  public let codec: RecordingCodec
  /// `nil` means "run until SIGINT/SIGTERM".
  public let durationSeconds: Double?
  /// `nil` means "derive from pixel count".
  public let bitrateMbps: Double?
  public let showsCursor: Bool
  public let pidfile: URL?

}

// MARK: - UsageError

public struct UsageError: Error, CustomStringConvertible, Sendable {

  // MARK: Lifecycle

  public init(_ description: String) {
    self.description = description
  }

  // MARK: Public

  public let description: String

}

// MARK: - RecorderError

public enum RecorderError: Error, CustomStringConvertible, Sendable {
  case noScreenRecordingAccess
  case noDisplaysAvailable
  case mainDisplayUnavailable
  case displayIndexOutOfRange(index: Int, count: Int)
  case displayIdentifierUnavailable(displayID: CGDirectDisplayID)
  case codecUnavailable(codec: RecordingCodec, width: Int, height: Int)
  case writerSetupFailed(String)
  case writerFailed(String)
  case noFramesCaptured(URL)

  // MARK: Public

  public var description: String {
    switch self {
    case .noScreenRecordingAccess:
      "no Screen Recording access"
    case .noDisplaysAvailable:
      "ScreenCaptureKit reported no capturable displays"
    case .mainDisplayUnavailable:
      "the main display is not in ScreenCaptureKit's display list"
    case .displayIdentifierUnavailable(let displayID):
      "no shareable display with id \(displayID); run --list-displays to see what is attached"
    case .displayIndexOutOfRange(let index, let count):
      "--display \(index) is out of range; \(count) display(s) are capturable (indices are 1-based)"
    case .codecUnavailable(let codec, let width, let height):
      "requested \(codec.rawValue) encoder does not accept \(width)x\(height); no codec substitution was attempted"
    case .writerSetupFailed(let reason):
      "AVAssetWriter setup failed: \(reason)"
    case .writerFailed(let reason):
      "AVAssetWriter failed: \(reason)"
    case .noFramesCaptured(let url):
      "no frame ever reached the writer; \(url.path) was not finalized"
    }
  }

}

// MARK: - StandardError

/// stdout carries the result other tools parse; everything diagnostic goes here.
public enum StandardError {

  public static func write(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }

  public static func describe(_ error: any Error) -> String {
    if let recorderError = error as? RecorderError { return recorderError.description }
    if let usageError = error as? UsageError { return usageError.description }
    let nsError = error as NSError
    return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
  }

}

// MARK: - RecorderCommand

/// What the process was asked to do.
///
/// Parsing is hand-rolled on purpose: the Demo Lab package has zero external
/// dependencies so it builds offline with only the Command Line Tools.
public enum RecorderCommand: Sendable {
  case record(RecorderOptions)
  case listDisplays
  case preflight
  case help

  // MARK: Public

  public static let usage = """
    DemoRecorder — 60 fps ScreenCaptureKit display recorder.

    USAGE:
      DemoRecorder --output <path.mov> [options]
      DemoRecorder --list-displays
      DemoRecorder --preflight

    OPTIONS:
      --output, -o <path.mov>     Destination. With `--display all` the basename gains -1, -2, ... suffixes.
      --display <index|main|all>  Display to capture. Indices are 1-based, as printed by --list-displays.
                                  Default: main.
      --fps <n>                   Cadence rate and capture ceiling, 1...240. Default: 60.
      --codec <hevc|h264>          Explicit codec. Default: hevc. Unsupported settings fail.
      --duration-seconds <n>      Stop and finalize after n seconds. Default: run until SIGINT/SIGTERM.
      --bitrate-mbps <n>          Override the average bitrate derived from the pixel count.
      --no-cursor                 Do not draw the pointer into the capture.
      --pidfile <path>            Write this process's pid there for `democtl record stop`; removed on exit.
                                  Written only once capture is live, and the take's outcome lands beside
                                  it as <basename>.json before the pid is removed.
      --list-displays             Print the capturable displays and exit.
      --preflight                 Print the Screen Recording access state; exit 0 (granted) or 3 (denied).
      --help, -h                  This text.

    EXIT CODES:
      0 ok   2 usage   3 no Screen Recording access   4 capture or writer failure
    """

  public static func parse(_ arguments: [String]) throws -> RecorderCommand {
    var output: String?
    var display = DisplaySelection.main
    var fps = 60
    var codec = RecordingCodec.hevc
    var durationSeconds: Double?
    var bitrateMbps: Double?
    var showsCursor = true
    var pidfile: String?
    var cursor = 0

    func nextValue(for option: String) throws -> String {
      cursor += 1
      guard cursor < arguments.count else {
        throw UsageError("\(option) requires a value")
      }
      return arguments[cursor]
    }

    while cursor < arguments.count {
      let argument = arguments[cursor]
      switch argument {
      case "--help", "-h":
        return .help
      case "--list-displays":
        return .listDisplays
      case "--preflight":
        return .preflight
      case "--output", "-o":
        output = try nextValue(for: "--output")
      case "--display":
        display = try parseDisplay(nextValue(for: "--display"))
      case "--fps":
        fps = try parseInt(nextValue(for: "--fps"), option: "--fps", lowerBound: 1, upperBound: 240)
      case "--codec":
        let value = try nextValue(for: "--codec")
        guard let parsed = RecordingCodec(rawValue: value) else { throw UsageError("--codec expects hevc or h264, got '\(value)'") }
        codec = parsed
      case "--duration-seconds":
        durationSeconds = try parsePositiveDouble(nextValue(for: "--duration-seconds"), option: "--duration-seconds")
      case "--bitrate-mbps":
        bitrateMbps = try parsePositiveDouble(nextValue(for: "--bitrate-mbps"), option: "--bitrate-mbps")
      case "--no-cursor":
        showsCursor = false
      case "--pidfile":
        pidfile = try nextValue(for: "--pidfile")
      default:
        throw UsageError("unknown option '\(argument)'")
      }
      cursor += 1
    }

    guard let output else {
      throw UsageError("--output <path.mov> is required")
    }
    return .record(RecorderOptions(
      output: fileURL(output, defaultExtension: "mov"),
      display: display,
      fps: fps,
      codec: codec,
      durationSeconds: durationSeconds,
      bitrateMbps: bitrateMbps,
      showsCursor: showsCursor,
      pidfile: pidfile.map { fileURL($0, defaultExtension: nil) } ?? RecorderOptions.defaultPidfile()
    ))
  }

  // MARK: Private

  private static func parseDisplay(_ value: String) throws -> DisplaySelection {
    switch value {
    case "main":
      return .main
    case "all":
      return .all
    default:
      if value.hasPrefix("id:") {
        guard let raw = UInt32(value.dropFirst(3)), raw != 0 else {
          throw UsageError("--display id: expects a CGDirectDisplayID, got '\(value)'")
        }
        return .identifier(CGDirectDisplayID(raw))
      }
      guard let index = Int(value), index >= 1 else {
        throw UsageError("--display expects 'main', 'all', 'id:<displayID>', or a 1-based index, got '\(value)'")
      }
      return .index(index)
    }
  }

  private static func parseInt(_ value: String, option: String, lowerBound: Int, upperBound: Int) throws -> Int {
    guard let parsed = Int(value), parsed >= lowerBound, parsed <= upperBound else {
      throw UsageError("\(option) expects an integer in \(lowerBound)...\(upperBound), got '\(value)'")
    }
    return parsed
  }

  private static func parsePositiveDouble(_ value: String, option: String) throws -> Double {
    guard let parsed = Double(value), parsed > 0, parsed.isFinite else {
      throw UsageError("\(option) expects a positive number, got '\(value)'")
    }
    return parsed
  }

  private static func fileURL(_ path: String, defaultExtension: String?) -> URL {
    var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    if let defaultExtension, url.pathExtension.isEmpty {
      url = url.appendingPathExtension(defaultExtension)
    }
    return url
  }

}
