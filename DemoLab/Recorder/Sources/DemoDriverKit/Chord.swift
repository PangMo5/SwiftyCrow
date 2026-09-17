// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Carbon
import CoreGraphics
import Foundation

// MARK: - Chord

/// One keystroke to synthesize: a virtual key code plus the modifier flags to
/// post with it.
///
/// A chord is what Tatami's *published* shortcut string means on this machine
/// right now — the parse resolves the key through the active keyboard layout in
/// the chord's own ⌘ state, because that is the key code Magnet registered with
/// Carbon.
public struct Chord: Equatable, Sendable {

  // MARK: Lifecycle

  public init(keyCode: CGKeyCode, flags: CGEventFlags, source: String) {
    self.keyCode = keyCode
    self.flags = flags
    self.source = source
  }

  // MARK: Public

  /// The virtual key code to post. Not necessarily the QWERTY code: see
  /// `KeyCodes.activeLayout(forCharacter:withCommand:)`.
  public let keyCode: CGKeyCode

  /// Modifier flags, set on both the key-down and the key-up event.
  public let flags: CGEventFlags

  /// The shortcut text this chord was parsed from, verbatim (not lowercased),
  /// so diagnostics can quote what the caller actually wrote.
  public let source: String

}

// MARK: - ChordError

public enum ChordError: Error, Equatable, CustomStringConvertible {
  case emptyInput
  case unknownKey(String)
  case unknownModifier(String)

  // MARK: Public

  public var description: String {
    switch self {
    case .emptyInput:
      "empty shortcut string"
    case .unknownKey(let name):
      "unknown key \"\(name)\" — expected a-z, 0-9, one of ` - = [ ] \\ ; ' , . / "
        + "or a named key (return, enter, tab, space, delete, escape, help, home, end, "
        + "pageup, pagedown, forwarddelete, left, right, up, down, f1-f13)"
    case .unknownModifier(let token):
      "unknown modifier \"\(token)\" — expected cmd/command, shift, alt/opt/option, or ctrl/control"
    }
  }

}

// MARK: - KeyCodes

/// Virtual key codes for the key names Tatami's skhd-style grammar accepts.
///
/// Two answers exist for a printable key, and they differ on a non-QWERTY
/// layout. Tatami *stores* the QWERTY code, but Magnet registers the code of
/// the currently active layout — read in the ⌘ state of the shortcut itself, as
/// Sauce builds Magnet's table — so the physical key a demo must press is the
/// active-layout one.
public enum KeyCodes {

  // MARK: Public

  /// The QWERTY (US ANSI) virtual key code for a key name, aliases included.
  /// Nil for any name outside Tatami's accepted set.
  public static func qwerty(_ name: String) -> CGKeyCode? {
    let key = name.lowercased()
    let resolved = aliases[key] ?? key
    return characterKeys[resolved] ?? namedKeys[resolved]
  }

  /// The virtual key code that produces `character` on the active keyboard
  /// layout, read in the modifier state Sauce used to build Magnet's table.
  ///
  /// `withCommand` must be true whenever the chord carries ⌘. Sauce keys its
  /// key-code map on `(carbonModifiers & cmdKey) != 0` and on nothing else, so
  /// on a layout that rearranges under ⌘ — "Dvorak - QWERTY ⌘" is the shipped
  /// example — a ⌘ chord registers a different code than the unmodified layout
  /// gives. shift/ctrl/alt do not split that table, so they are not passed.
  ///
  /// Nil when the current input source exposes no Unicode layout data (most
  /// input methods, e.g. Korean or Japanese, do not) or when the character is
  /// unreachable in that state on this layout. Callers fall back to QWERTY.
  public static func activeLayout(forCharacter character: Character, withCommand: Bool = false) -> CGKeyCode? {
    guard let layoutData = currentLayoutData() else { return nil }
    let wanted = String(character)
    // Carbon packs the modifier state into UCKeyTranslate's high byte — the
    // same `carbonModifiers >> 8` Sauce feeds it when it builds its tables.
    let modifierKeyState = UInt32(withCommand ? (cmdKey >> 8) & 0xFF : 0)
    return layoutData.withUnsafeBytes { raw -> CGKeyCode? in
      guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
      let keyboardType = UInt32(LMGetKbdType())
      for code in UInt16(0)...UInt16(127) where !keypadKeyCodes.contains(code) {
        var deadKeyState = UInt32(0)
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
          layout,
          code,
          UInt16(kUCKeyActionDown),
          modifierKeyState,
          keyboardType,
          OptionBits(kUCKeyTranslateNoDeadKeysBit),
          &deadKeyState,
          characters.count,
          &length,
          &characters
        )
        guard status == noErr, length > 0 else { continue }
        if String(utf16CodeUnits: characters, count: length) == wanted { return CGKeyCode(code) }
      }
      return nil
    }
  }

  // MARK: Private

  /// QWERTY positions of the printable keys, copied from Tatami's own table so
  /// a config string and a demo keystroke can never drift apart.
  private static let characterKeys: [String: CGKeyCode] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
    "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
    "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
    "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33,
    "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40,
    ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50,
  ]

  /// Keys whose virtual code does not move between keyboard layouts.
  private static let namedKeys: [String: CGKeyCode] = [
    "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "escape": 53,
    "help": 114, "home": 115, "pageup": 116, "forwarddelete": 117, "end": 119,
    "pagedown": 121, "left": 123, "right": 124, "down": 125, "up": 126,
    "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
    "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105,
  ]

  /// Friendly aliases, matching Tatami's table exactly. Note `del`: Tatami maps
  /// it to `delete` (key code 51, the ⌫ key), *not* to `forwarddelete`. Pressing
  /// 117 here would miss a `del` shortcut entirely, so this table follows the
  /// parser that actually registers the hotkey.
  private static let aliases: [String: String] = [
    "esc": "escape",
    "backspace": "delete",
    "del": "delete",
    "spacebar": "space",
    "pgup": "pageup",
    "pgdn": "pagedown",
  ]

  /// Keypad and function-row codes, skipped while scanning the active layout:
  /// the keypad also produces digits, `=`, `/`, `.` and `,`, and the main row
  /// is the key a person would press.
  private static let keypadKeyCodes: ClosedRange<UInt16> = 65...92

  private static func currentLayoutData() -> Data? {
    guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
    guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
    return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
  }

}

// MARK: - ChordParser

/// Parses Tatami's skhd-style shortcut strings.
///
/// The grammar is mirrored from `HotKey.init(parsing:)`, separator search from
/// the END included, so `"ctrl + alt - -"` means what Tatami says it means.
public enum ChordParser {

  // MARK: Public

  public static func parse(_ text: String) throws -> Chord {
    var notes: [String] = []
    return try parse(text, notes: &notes)
  }

  /// Same parse, appending human-readable notes worth showing in verbose mode —
  /// most importantly when the active layout and QWERTY disagree about which
  /// physical key carries a character.
  public static func parse(_ text: String, notes: inout [String]) throws -> Chord {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespaces)
    guard !normalized.isEmpty else { throw ChordError.emptyInput }
    let split = splitModifiersAndKey(normalized)
    let flags = try modifiers(from: split.modifiers)
    let keyName = split.key.trimmingCharacters(in: .whitespaces)
    // The modifiers are read first because the key resolution depends on them:
    // a ⌘ chord is looked up in the layout's ⌘ state.
    let keyCode = try resolve(keyName: keyName, withCommand: flags.contains(.maskCommand), notes: &notes)
    return Chord(keyCode: keyCode, flags: flags, source: text)
  }

  /// Parses a modifier-only string such as `"alt"` or `"ctrl + alt"`, for the
  /// held-modifier switcher. Unknown tokens throw rather than being dropped: a
  /// dropped modifier would press a different, silently wrong shortcut.
  public static func parseModifiers(_ text: String) throws -> CGEventFlags {
    let normalized = text.lowercased().trimmingCharacters(in: .whitespaces)
    guard !normalized.isEmpty else { throw ChordError.emptyInput }
    return try modifiers(from: normalized)
  }

  // MARK: Private

  /// The separator search Tatami performs, in the same order: padded `" - "`
  /// from the end, then a bare `"-"` that is neither first nor last, then a
  /// `"+"` split, then a bare key.
  private static func splitModifiersAndKey(_ text: String) -> (modifiers: String?, key: String) {
    if let range = text.range(of: " - ", options: .backwards) {
      return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
    if
      let range = text.range(of: "-", options: .backwards),
      range.lowerBound != text.startIndex,
      range.upperBound != text.endIndex
    {
      return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
    if text.contains("+") {
      var tokens = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      let key = tokens.popLast() ?? ""
      return (tokens.joined(separator: "+"), key)
    }
    return (nil, text)
  }

  private static func modifiers(from part: String?) throws -> CGEventFlags {
    guard let part else { return [] }
    var flags: CGEventFlags = []
    for token in part.split(whereSeparator: { $0 == "+" || $0 == "-" }) {
      switch token.trimmingCharacters(in: .whitespaces) {
      case "cmd", "command", "⌘": flags.insert(.maskCommand)
      case "shift", "⇧": flags.insert(.maskShift)
      case "alt", "opt", "option", "⌥": flags.insert(.maskAlternate)
      case "ctrl", "control", "⌃": flags.insert(.maskControl)
      case "", "fn": continue
      default: throw ChordError.unknownModifier(String(token))
      }
    }
    return flags
  }

  private static func resolve(keyName: String, withCommand: Bool, notes: inout [String]) throws -> CGKeyCode {
    guard let qwerty = KeyCodes.qwerty(keyName) else { throw ChordError.unknownKey(keyName) }
    guard keyName.count == 1, let character = keyName.first else { return qwerty }
    let state = withCommand ? "the active layout with ⌘ held" : "the active layout"
    guard let active = KeyCodes.activeLayout(forCharacter: character, withCommand: withCommand) else {
      notes.append(
        "key \"\(keyName)\": \(state) exposes no key that produces it; "
          + "using the QWERTY key code \(qwerty), which is wrong if the layout is not QWERTY"
      )
      return qwerty
    }
    if active != qwerty {
      notes.append(
        "key \"\(keyName)\": \(state) says key code \(active), QWERTY says \(qwerty); "
          + "pressing \(active), because that is the code Magnet registered"
      )
    }
    return active
  }

}
