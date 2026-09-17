// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import DemoDriverKit
import Foundation

// MARK: - ExitCode

enum ExitCode {
  static let ok: Int32 = 0
  static let usage: Int32 = 2
  static let notTrusted: Int32 = 3
  static let runtime: Int32 = 4
}

// MARK: - UsageError

struct UsageError: Error, CustomStringConvertible {
  let message: String

  var description: String { message }
}

// MARK: - Arguments

/// A deliberately small flag parser: `--name value`, `--name=value`, and
/// `--verbose`. The package has no dependencies and this does not need any.
struct Arguments {

  // MARK: Lifecycle

  init(_ raw: [String], allowed: Set<String>) throws {
    var index = 0
    while index < raw.count {
      let token = raw[index]
      if token == "--verbose" || token == "-v" {
        verbose = true
        index += 1
        continue
      }
      guard token.hasPrefix("--") else {
        positional.append(token)
        index += 1
        continue
      }
      let body = String(token.dropFirst(2))
      let name: String
      var value: String?
      if let separator = body.firstIndex(of: "=") {
        name = String(body[..<separator])
        value = String(body[body.index(after: separator)...])
      } else {
        name = body
      }
      guard allowed.contains(name) else { throw UsageError(message: "unknown option \"--\(name)\"") }
      if value == nil {
        guard index + 1 < raw.count else { throw UsageError(message: "option \"--\(name)\" needs a value") }
        value = raw[index + 1]
        index += 1
      }
      values[name] = value
      index += 1
    }
  }

  // MARK: Internal

  private(set) var positional: [String] = []
  private(set) var verbose = false

  func string(_ name: String) -> String? { values[name] }

  func int(_ name: String, default fallback: Int, minimum: Int) throws -> Int {
    guard let raw = values[name] else { return fallback }
    guard let value = Int(raw) else {
      throw UsageError(message: "option \"--\(name)\" expects a whole number, got \"\(raw)\"")
    }
    guard value >= minimum else {
      throw UsageError(message: "option \"--\(name)\" must be at least \(minimum), got \(value)")
    }
    return value
  }

  func unit(_ name: String, default fallback: Double) throws -> Double {
    guard let raw = values[name] else { return fallback }
    guard let value = Double(raw) else {
      throw UsageError(message: "option \"--\(name)\" expects a number, got \"\(raw)\"")
    }
    guard value >= 0, value <= 1 else {
      throw UsageError(message: "option \"--\(name)\" must be between 0 and 1, got \(value)")
    }
    return value
  }

  func requiredPositional(_ description: String) throws -> String {
    guard let first = positional.first else { throw UsageError(message: "missing \(description)") }
    guard positional.count == 1 else {
      throw UsageError(message: "expected one \(description), got \(positional.count): \(positional.joined(separator: " "))")
    }
    return first
  }

  // MARK: Private

  private var values: [String: String] = [:]

}

// MARK: - DemoKey

@MainActor
enum DemoKey {

  // MARK: Internal

  static func main(_ arguments: [String]) -> Int32 {
    do {
      return try run(arguments)
    } catch let error as UsageError {
      complain(error.message)
      complain(usage)
      return ExitCode.usage
    } catch DriverError.notTrusted {
      complain("\(DriverError.notTrusted)")
      complain("the binary needing the grant is: \(executablePath)")
      return ExitCode.notTrusted
    } catch {
      complain("\(error)")
      return ExitCode.runtime
    }
  }

  // MARK: Private

  private static let usage = """
    usage:
      demokey press "<chord>" [--hold-ms N] [--repeat N] [--gap-ms N] [--verbose]
      demokey hold "<modifiers>" --keys "<chord>,<chord>,..." [--gap-ms N] [--release-after-ms N] [--verbose]
      demokey pointer --display N [--x 0.5] [--y 0.5] [--verbose]
      demokey check [--verbose]
      demokey --help

    exit codes: 0 ok, 2 usage error, 3 not trusted for Accessibility, 4 runtime failure
    """

  private static let help = """
    demokey — types Tatami's published shortcuts, exactly as a person would press them.

    It synthesizes key events and moves the cursor. Nothing else: it never talks to
    Tatami's socket, reads its config, or touches its process.

    \(usage)

    press
      Taps one chord. A chord is Tatami's own skhd-style syntax: "ctrl + alt - h",
      "cmd-return", "alt+shift+tab", or a bare key like "tab". Modifiers are
      cmd/command, shift, alt/opt/option, ctrl/control.
      --hold-ms N     key-down to key-up time (default 24)
      --repeat N      tap the chord N times (default 1)
      --gap-ms N      wait between repeats (default 80)

    hold
      Holds modifiers down as real key presses, taps each key in --keys, waits, then
      releases. This is what Tatami's held-modifier switcher needs: it polls the HID
      flags state, which flags on a key event alone never reach.
      --keys LIST         comma-separated chords, e.g. "tab,tab" (required)
      --gap-ms N          wait between taps (default 90)
      --release-after-ms  wait before releasing the modifiers (default 180)
      Per-tap modifiers must be a subset of the held modifiers.

    pointer
      Warps the cursor onto a display, because Tatami places a dynamic workspace on
      the display under the cursor.
      --display N   zero-based index into the screens sorted left to right, top to
                    bottom — the same order Tatami uses (required)
      --x U --y U   unit position on that display, (0,0) top-left, (1,1) bottom-right
                    (default 0.5, 0.5)

    check
      Prints whether this process is trusted for Accessibility. Exits 3 when it is not.
    """

  private static var executablePath: String {
    Bundle.main.executablePath ?? CommandLine.arguments.first ?? "demokey"
  }

  private static func run(_ arguments: [String]) throws -> Int32 {
    guard let command = arguments.first else { throw UsageError(message: "no command given") }
    let rest = Array(arguments.dropFirst())
    switch command {
    case "--help", "-h", "help":
      print(help)
      return ExitCode.ok
    case "press":
      return try press(try Arguments(rest, allowed: ["hold-ms", "repeat", "gap-ms"]))
    case "hold":
      return try hold(try Arguments(rest, allowed: ["keys", "gap-ms", "release-after-ms"]))
    case "pointer":
      return try pointer(try Arguments(rest, allowed: ["display", "x", "y"]))
    case "check":
      return check(try Arguments(rest, allowed: []))
    default:
      throw UsageError(message: "unknown command \"\(command)\"")
    }
  }

  private static func press(_ arguments: Arguments) throws -> Int32 {
    let text = try arguments.requiredPositional("chord, e.g. \"ctrl + alt - h\"")
    let holdMilliseconds = try arguments.int("hold-ms", default: 24, minimum: 0)
    let repeats = try arguments.int("repeat", default: 1, minimum: 1)
    let gapMilliseconds = try arguments.int("gap-ms", default: 80, minimum: 0)

    var notes: [String] = []
    let chord = try ChordParser.parse(text, notes: &notes)
    if arguments.verbose {
      notes.forEach(note)
      note("press \"\(chord.source)\" -> key code \(chord.keyCode), flags \(hex(chord.flags)), \(repeats)x")
    }
    for index in 0..<repeats {
      try KeyDriver.press(chord, holdMilliseconds: holdMilliseconds)
      if index < repeats - 1 { wait(milliseconds: gapMilliseconds) }
    }
    return ExitCode.ok
  }

  private static func hold(_ arguments: Arguments) throws -> Int32 {
    let text = try arguments.requiredPositional("modifier list, e.g. \"alt\"")
    guard let list = arguments.string("keys") else {
      throw UsageError(message: "hold needs --keys, e.g. --keys \"tab,tab\"")
    }
    let gapMilliseconds = try arguments.int("gap-ms", default: 90, minimum: 0)
    let releaseAfterMilliseconds = try arguments.int("release-after-ms", default: 180, minimum: 0)

    let modifiers = try ChordParser.parseModifiers(text)
    guard !modifiers.isEmpty else {
      throw UsageError(message: "\"\(text)\" names no modifier to hold")
    }
    var notes: [String] = []
    var keys: [CGKeyCode] = []
    for entry in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !entry.isEmpty {
      let chord = try ChordParser.parse(entry, notes: &notes)
      // The switcher holds one modifier set for the whole session, so a tap
      // cannot introduce its own. Dropping it silently would press a different
      // shortcut than the caller wrote.
      guard modifiers.contains(chord.flags) else {
        throw UsageError(
          message: "key \"\(entry)\" carries modifiers that are not held — put every modifier in the hold argument"
        )
      }
      keys.append(chord.keyCode)
    }
    guard !keys.isEmpty else { throw UsageError(message: "--keys listed no keys") }

    if arguments.verbose {
      notes.forEach(note)
      let tapped = keys.map(String.init).joined(separator: ", ")
      note("hold \(hex(modifiers)) tapping \(tapped), releasing after \(releaseAfterMilliseconds)ms")
    }
    try KeyDriver.hold(
      modifiers: modifiers,
      tapping: keys,
      gapMilliseconds: gapMilliseconds,
      holdAfterMilliseconds: releaseAfterMilliseconds
    )
    return ExitCode.ok
  }

  private static func pointer(_ arguments: Arguments) throws -> Int32 {
    guard arguments.string("display") != nil else {
      throw UsageError(message: "pointer needs --display N (zero-based)")
    }
    let display = try arguments.int("display", default: 0, minimum: 0)
    let unitX = try arguments.unit("x", default: 0.5)
    let unitY = try arguments.unit("y", default: 0.5)
    if arguments.verbose { note("pointer -> display \(display) at (\(unitX), \(unitY))") }
    try Pointer.warp(toDisplayIndex: display, unitX: unitX, unitY: unitY)
    return ExitCode.ok
  }

  private static func check(_ arguments: Arguments) -> Int32 {
    let trusted = KeyDriver.isTrusted
    print(trusted ? "accessibility: trusted" : "accessibility: not trusted")
    if arguments.verbose { note("binary: \(executablePath)") }
    if !trusted {
      complain("grant Accessibility in System Settings > Privacy & Security > Accessibility for: \(executablePath)")
    }
    return trusted ? ExitCode.ok : ExitCode.notTrusted
  }

  private static func hex(_ flags: CGEventFlags) -> String {
    "0x" + String(flags.rawValue, radix: 16)
  }

  private static func wait(milliseconds: Int) {
    guard milliseconds > 0 else { return }
    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
  }

  private static func note(_ message: String) {
    complain(message)
  }

  private static func complain(_ message: String) {
    FileHandle.standardError.write(Data("demokey: \(message)\n".utf8))
  }

}

// Top-level code runs on the main thread, which is where the driver lives.
exit(MainActor.assumeIsolated { DemoKey.main(Array(CommandLine.arguments.dropFirst())) })
