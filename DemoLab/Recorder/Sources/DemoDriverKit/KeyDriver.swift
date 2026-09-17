// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ApplicationServices
import Carbon
import CoreGraphics
import Foundation

// MARK: - DriverError

public enum DriverError: Error, Equatable, CustomStringConvertible {
  case notTrusted
  case eventSourceUnavailable
  case eventCreationFailed(CGKeyCode)
  case noModifiersToHold
  case noKeysToTap

  // MARK: Public

  public var description: String {
    switch self {
    case .notTrusted:
      "this process is not trusted for Accessibility, so no key events were posted — "
        + "grant it in System Settings > Privacy & Security > Accessibility"
    case .eventSourceUnavailable:
      "CGEventSource(stateID: .hidSystemState) returned nil; no key events were posted"
    case .eventCreationFailed(let keyCode):
      "CGEvent could not be created for key code \(keyCode)"
    case .noModifiersToHold:
      "hold needs at least one modifier — a switcher session stays open only while a modifier is down"
    case .noKeysToTap:
      "hold needs at least one key to tap"
    }
  }

}

// MARK: - HeldKeys

/// The keys this process has posted down and not yet posted up.
///
/// Process-global on purpose. A synthesized modifier key-down enters
/// `CGEventSource.flagsState` and stays there until *something* posts the
/// matching key-up: die in between and the modifier is logically held for the
/// rest of the login session, so every later take records a corrupted machine.
/// The ledger is what lets any thread — including the one that only learns the
/// process is dying — finish the release.
private enum HeldKeys {

  // MARK: Internal

  struct Entry {
    /// The virtual key code posted down.
    let code: CGKeyCode
    /// The HID flag this key contributes while it is down; empty for a key that
    /// is not a modifier.
    let flag: CGEventFlags
  }

  static var isEmpty: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entries.isEmpty
  }

  /// The flags this process currently owns: the union of the modifier keys it
  /// is holding down. Every event it posts carries exactly this set.
  static var flags: CGEventFlags {
    lock.lock()
    defer { lock.unlock() }
    return entries.reduce(into: CGEventFlags()) { $0.formUnion($1.flag) }
  }

  static func add(code: CGKeyCode, flag: CGEventFlags) {
    lock.lock()
    defer { lock.unlock() }
    entries.append(Entry(code: code, flag: flag))
  }

  static func drop(code: CGKeyCode) {
    lock.lock()
    defer { lock.unlock() }
    if let index = entries.lastIndex(where: { $0.code == code }) { entries.remove(at: index) }
  }

  /// Takes everything still held, in press order. Emptying the ledger is what
  /// makes releasing idempotent, so the signal path and the `atexit` path can
  /// both run without posting a key-up twice.
  static func drain() -> [Entry] {
    lock.lock()
    defer { lock.unlock() }
    let taken = entries
    entries.removeAll()
    return taken
  }

  // MARK: Private

  private static let lock = NSLock()

  /// Reached from the main thread and from whichever thread handles a signal,
  /// so `lock` guards every access.
  private nonisolated(unsafe) static var entries: [Entry] = []

}

// MARK: - KeyDriver

/// Synthesizes real key events. It knows nothing about Tatami beyond the
/// shortcut text it is handed: no socket, no config, no process, no state.
@MainActor
public enum KeyDriver {

  // MARK: Public

  /// Whether this process may post events at all. Everything here refuses to
  /// run when it is false — a demo that records nothing happening is worse
  /// than a demo that stops with an error.
  public static var isTrusted: Bool { AXIsProcessTrusted() }

  /// Taps one chord: key down with the modifier flags set, hold, key up with
  /// the same flags. Carbon hotkeys (`RegisterEventHotKey`, which is what
  /// Magnet uses) match on the flags carried by the key event itself.
  public static func press(_ chord: Chord, holdMilliseconds: Int = 24) throws {
    let source = try eventSource()
    // Ledger first, post second: an interrupt landing between the two must err
    // towards a stray key-up, never towards a key left down.
    HeldKeys.add(code: chord.keyCode, flag: [])
    do {
      try post(keyCode: chord.keyCode, keyDown: true, flags: chord.flags, source: source)
      sleep(milliseconds: holdMilliseconds)
      try post(keyCode: chord.keyCode, keyDown: false, flags: chord.flags, source: source)
    } catch {
      releaseHeldKeys(using: source)
      throw error
    }
    HeldKeys.drop(code: chord.keyCode)
  }

  /// Holds `modifiers` down, taps each key in turn, waits, then releases.
  ///
  /// The modifiers are pressed as real key events, not merely set as flags on
  /// the key taps: Tatami's held-modifier app/window switcher polls
  /// `CGEventSource.flagsState`, which flags on a key event alone never reach.
  /// The modifiers are always released — when a tap fails partway, and when the
  /// operator interrupts the take mid-hold (see `installReleaseGuard`).
  public static func hold(
    modifiers: CGEventFlags,
    tapping keys: [CGKeyCode],
    gapMilliseconds: Int,
    holdAfterMilliseconds: Int
  ) throws {
    guard !modifiers.isEmpty else { throw DriverError.noModifiersToHold }
    guard !keys.isEmpty else { throw DriverError.noKeysToTap }
    let source = try eventSource()
    let held = modifierKeys.filter { modifiers.contains($0.flag) }

    do {
      for entry in held {
        HeldKeys.add(code: entry.code, flag: entry.flag)
        try post(keyCode: entry.code, keyDown: true, flags: HeldKeys.flags, source: source)
      }
      sleep(milliseconds: modifierSettleMilliseconds)
      for (index, key) in keys.enumerated() {
        HeldKeys.add(code: key, flag: [])
        try post(keyCode: key, keyDown: true, flags: HeldKeys.flags, source: source)
        sleep(milliseconds: tapHoldMilliseconds)
        try post(keyCode: key, keyDown: false, flags: HeldKeys.flags, source: source)
        HeldKeys.drop(code: key)
        if index < keys.count - 1 { sleep(milliseconds: gapMilliseconds) }
      }
      sleep(milliseconds: holdAfterMilliseconds)
    } catch {
      releaseHeldKeys(using: source)
      throw error
    }
    releaseHeldKeys(using: source)
  }

  // MARK: Fileprivate

  /// Posts the key-up for everything still on the ledger, newest first, in the
  /// exact reverse of the order it went down, and reports how many it released.
  ///
  /// Nonisolated because the interrupt path calls it off the main thread, and
  /// posting a CGEvent does not need the main thread.
  @discardableResult
  fileprivate nonisolated static func releaseHeldKeys(using source: CGEventSource? = nil) -> Int {
    guard let poster = source ?? CGEventSource(stateID: .hidSystemState) else {
      // Draining now would lose the record of what is still down, and nothing
      // could be posted anyway. Say so instead of failing quietly.
      if !HeldKeys.isEmpty {
        complain("no CGEventSource to release the keys this process is holding — they are still down")
      }
      return 0
    }
    let held = HeldKeys.drain()
    var flags = held.reduce(into: CGEventFlags()) { $0.formUnion($1.flag) }
    for entry in held.reversed() {
      flags.remove(entry.flag)
      guard let event = CGEvent(keyboardEventSource: poster, virtualKey: entry.code, keyDown: false) else { continue }
      event.flags = eventFlags(for: entry.code, modifiers: flags)
      event.post(tap: .cghidEventTap)
    }
    return held.count
  }

  fileprivate nonisolated static func complain(_ message: String) {
    let name = ProcessInfo.processInfo.processName
    FileHandle.standardError.write(Data("\(name): \(message)\n".utf8))
  }

  // MARK: Private

  /// Canonical press order, matching how Tatami writes a combo (`ctrl + alt +
  /// shift + cmd`). Release is the exact reverse.
  private static let modifierKeys: [(flag: CGEventFlags, code: CGKeyCode)] = [
    (.maskControl, CGKeyCode(kVK_Control)),
    (.maskAlternate, CGKeyCode(kVK_Option)),
    (.maskShift, CGKeyCode(kVK_Shift)),
    (.maskCommand, CGKeyCode(kVK_Command)),
  ]

  /// Time for a modifier press to reach the HID flags state before the first tap.
  private static let modifierSettleMilliseconds = 32

  /// Down-to-up time of one tap inside a held-modifier session.
  private static let tapHoldMilliseconds = 24

  /// Written once, from the main thread, by the first call that posts anything.
  private nonisolated(unsafe) static var releaseGuardSources: [DispatchSourceSignal] = []

  /// Ctrl-C during a hold is the one interrupt that outlives the process: the
  /// modifier it leaves down stays down system-wide until a physical key
  /// releases it, silently corrupting every take that follows. Installed on the
  /// first posted event rather than in a `main`, so a new entry point cannot
  /// forget it.
  private nonisolated static func installReleaseGuard() {
    guard releaseGuardSources.isEmpty else { return }
    atexit(releaseHeldKeysAtExit)
    // SIGINT and SIGTERM only, the same two DemoRecorder disarms: the guard
    // takes over the process disposition for whatever it names, so it names no
    // signal the operator may have deliberately arranged to ignore.
    for (number, name) in [(SIGINT, "SIGINT"), (SIGTERM, "SIGTERM")] {
      // The dispatch source only sees the signal once the default disposition,
      // which kills the process outright, is disarmed.
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global(qos: .userInitiated))
      source.setEventHandler {
        let released = releaseHeldKeys()
        if released > 0 {
          complain("\(name) arrived mid-keystroke — released \(released) key(s) that were still down")
        }
        exit(128 + number)
      }
      source.resume()
      releaseGuardSources.append(source)
    }
  }

  private static func eventSource() throws -> CGEventSource {
    guard isTrusted else { throw DriverError.notTrusted }
    installReleaseGuard()
    guard let source = CGEventSource(stateID: .hidSystemState) else {
      throw DriverError.eventSourceUnavailable
    }
    return source
  }

  /// Arrow keys carry keypad/function identity in addition to held modifiers.
  /// Dropping those bits made Carbon shortcuts ignore otherwise correct arrow events.
  public nonisolated static func eventFlags(for keyCode: CGKeyCode, modifiers: CGEventFlags) -> CGEventFlags {
    switch keyCode {
    case 123...126: modifiers.union([.maskNumericPad, .maskSecondaryFn])
    default: modifiers
    }
  }

  private static func post(
    keyCode: CGKeyCode,
    keyDown: Bool,
    flags: CGEventFlags,
    source: CGEventSource
  ) throws {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: keyDown) else {
      throw DriverError.eventCreationFailed(keyCode)
    }
    event.flags = eventFlags(for: keyCode, modifiers: flags)
    event.post(tap: .cghidEventTap)
  }

  private static func sleep(milliseconds: Int) {
    guard milliseconds > 0 else { return }
    Thread.sleep(forTimeInterval: Double(milliseconds) / 1000)
  }

}

// MARK: - releaseHeldKeysAtExit

/// `atexit` takes a C function, so this is a free function: it can carry no
/// captured context and no actor isolation. It covers the orderly exits a
/// signal source never sees — an error path that ends in `exit`, above all.
private func releaseHeldKeysAtExit() {
  let released = KeyDriver.releaseHeldKeys()
  if released > 0 {
    KeyDriver.complain("released \(released) key(s) that were still down at exit")
  }
}
