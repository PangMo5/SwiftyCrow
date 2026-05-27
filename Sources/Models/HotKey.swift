import Foundation
import KeyboardShortcuts

// MARK: - HotKey

/// A persisted keyboard shortcut.
///
/// Serialized as a human-readable skhd-style string (e.g. `"ctrl + alt - h"`,
/// `"cmd - return"`) so config.toml stays legible. Decoding also accepts the
/// legacy `{ carbonKeyCode, carbonModifiers }` table form.
struct HotKey: Hashable, Sendable {
  var carbonKeyCode: Int
  var carbonModifiers: Int

  init(carbonKeyCode: Int, carbonModifiers: Int) {
    self.carbonKeyCode = carbonKeyCode
    self.carbonModifiers = carbonModifiers
  }
}

extension HotKey {
  init(_ shortcut: KeyboardShortcuts.Shortcut) {
    self.init(
      carbonKeyCode: shortcut.carbonKeyCode,
      carbonModifiers: shortcut.carbonModifiers
    )
  }

  var shortcut: KeyboardShortcuts.Shortcut {
    KeyboardShortcuts.Shortcut(
      carbonKeyCode: carbonKeyCode,
      carbonModifiers: carbonModifiers
    )
  }
}

// MARK: - skhd-style string

extension HotKey {
  // Carbon modifier bit masks.
  private static let cmd = 256
  private static let shift = 512
  private static let option = 2048
  private static let control = 4096

  /// skhd-style description: `"<mods joined by ' + '> - <key>"`.
  var displayString: String {
    var mods = [String]()
    if carbonModifiers & Self.control != 0 { mods.append("ctrl") }
    if carbonModifiers & Self.option != 0 { mods.append("alt") }
    if carbonModifiers & Self.shift != 0 { mods.append("shift") }
    if carbonModifiers & Self.cmd != 0 { mods.append("cmd") }
    let key = Self.keyCodeToName[carbonKeyCode] ?? "0x" + String(carbonKeyCode, radix: 16)
    return mods.isEmpty ? key : mods.joined(separator: " + ") + " - " + key
  }

  /// Parse a skhd-style string. Accepts `"ctrl + alt - h"` and the looser
  /// `"ctrl+alt+h"`. Returns nil on an unknown key/modifier.
  init?(parsing raw: String) {
    let s = raw.lowercased().trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }

    let modPart: String?
    let keyPart: String
    if
      let range = s.range(of: "-", options: .backwards),
      s.distance(from: s.startIndex, to: range.lowerBound) > 0
    {
      // Standard `mods - key`. (Guard against a leading '-' which would be
      // the minus key itself with no modifiers.)
      modPart = String(s[..<range.lowerBound])
      keyPart = String(s[range.upperBound...]).trimmingCharacters(in: .whitespaces)
    } else if s.contains("+") {
      // Loose `ctrl+alt+h`: last token is the key, the rest modifiers.
      var tokens = s.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
      keyPart = tokens.removeLast()
      modPart = tokens.joined(separator: "+")
    } else {
      modPart = nil
      keyPart = s
    }

    var mods = 0
    if let modPart {
      for token in modPart.split(whereSeparator: { $0 == "+" || $0 == "-" }) {
        switch token.trimmingCharacters(in: .whitespaces) {
        case "cmd", "command", "⌘": mods |= Self.cmd
        case "shift", "⇧": mods |= Self.shift
        case "alt", "opt", "option", "⌥": mods |= Self.option
        case "ctrl", "control", "⌃": mods |= Self.control
        case "", "fn": break
        default: return nil
        }
      }
    }

    guard let code = Self.nameToKeyCode[keyPart.trimmingCharacters(in: .whitespaces)] else { return nil }
    self.init(carbonKeyCode: code, carbonModifiers: mods)
  }
}

// MARK: Codable

extension HotKey: Codable {
  private enum CodingKeys: String, CodingKey {
    case carbonKeyCode, carbonModifiers
  }

  init(from decoder: any Decoder) throws {
    // Preferred: skhd-style string.
    if
      let container = try? decoder.singleValueContainer(),
      let string = try? container.decode(String.self),
      let parsed = HotKey(parsing: string)
    {
      self = parsed
      return
    }
    // Legacy: { carbonKeyCode, carbonModifiers } table.
    let keyed = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      carbonKeyCode: try keyed.decode(Int.self, forKey: .carbonKeyCode),
      carbonModifiers: try keyed.decode(Int.self, forKey: .carbonModifiers)
    )
  }

  func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(displayString)
  }
}

// MARK: - US ANSI virtual key codes

extension HotKey {
  fileprivate static let keyCodeToName: [Int: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
    11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
    18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
    26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[",
    34: "i", 35: "p", 36: "return", 37: "l", 38: "j", 39: "'", 40: "k",
    41: ";", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
    48: "tab", 49: "space", 50: "`", 51: "delete", 53: "escape",
    76: "enter", 96: "f5", 97: "f6", 98: "f7", 99: "f3", 100: "f8",
    101: "f9", 103: "f11", 105: "f13", 109: "f10", 111: "f12",
    114: "help", 115: "home", 116: "pageup", 117: "forwarddelete",
    118: "f4", 119: "end", 120: "f2", 121: "pagedown", 122: "f1",
    123: "left", 124: "right", 125: "down", 126: "up",
  ]

  fileprivate static let nameToKeyCode: [String: Int] = {
    var map = [String: Int]()
    for (code, name) in keyCodeToName { map[name] = code }
    // Friendly aliases.
    map["esc"] = 53
    map["backspace"] = 51
    map["del"] = 51
    map["spacebar"] = 49
    map["pgup"] = 116
    map["pgdn"] = 121
    return map
  }()
}
