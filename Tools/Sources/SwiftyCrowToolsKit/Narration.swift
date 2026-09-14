// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
// Presentation conventions and ASS escaping adapted from Tatami Demo Lab.
import Foundation

struct FilmNarration {
  static let fonts = [
    "en": "Helvetica Neue",
    "ko": "Apple SD Gothic Neo",
    "ja": "Hiragino Sans",
    "zh-Hans": "Heiti SC",
    "zh-Hant": "Heiti TC",
  ]

  let workspace: Workspace

  static func validate(_ timeline: JSON, film: String, locale: String, duration: Double) throws {
    try require(timeline["schemaVersion"].int == 1, "Unsupported narration timeline")
    try require(timeline["film"].str == film && timeline["uiLanguage"].str == locale, "Narration film or locale mismatch")
    try require(timeline["captureEpochUptimeNanoseconds"].double > 0, "Narration has no first-frame epoch")
    try require(duration.isFinite && duration > 0, "Invalid narration duration")
    try require(abs(timeline["durationSeconds"].double - duration) <= 0.04, "Narration and movie duration differ")
    let events = timeline["events"].array
    try require(!events.isEmpty, "Narration timeline is empty")
    for event in events {
      let track = event["track"].str
      let start = event["start"].double
      let end = event["end"].double
      try require(["chapter", "caption", "keys"].contains(track), "Unknown narration track")
      try require(
        start.isFinite && end.isFinite && start >= 0 && end > start && end <= duration + 0.04,
        "Narration event is outside the movie"
      )
      if track == "keys" {
        try require(!event["chord"].str.isEmpty && event["id"].isNull, "Keycasts must come from actual input chords")
        _ = try displayChord(event["chord"].str)
      } else {
        try require(event["id"].str.hasPrefix(film + "."), "Narration cue belongs to another film")
        if track == "caption" { try require(end - start >= 2.4, "Caption disappears before it can be read: \(event["id"].str)") }
      }
    }
    for track in ["chapter", "caption", "keys"] {
      let ordered = events.filter { $0["track"].str == track }.sorted { $0["start"].double < $1["start"].double }
      for pair in zip(ordered, ordered.dropFirst()) {
        try require(pair.0["end"].double <= pair.1["start"].double + 0.01, "Overlapping \(track) cues")
      }
      if track != "keys" { try require(ordered.first?["start"].double ?? .infinity <= 1.5, "Opening \(track) arrives late") }
    }
    try require(events.contains { $0["track"].str == "keys" }, "Film has no actual shortcut demonstration")
  }

  static func displayChord(_ raw: String) throws -> String {
    let parts = raw.components(separatedBy: " - ")
    try require(parts.count <= 2, "Invalid recorded chord: \(raw)")
    let modifiers = parts.count == 2 ? parts[0].split(separator: "+").map { trim(String($0)).lowercased() } : []
    let symbols = ["ctrl": "⌃", "control": "⌃", "alt": "⌥", "opt": "⌥", "option": "⌥", "shift": "⇧", "cmd": "⌘", "command": "⌘"]
    let modifierSymbols = try modifiers.map { name in
      guard let symbol = symbols[name] else { throw ToolError("Unknown recorded modifier: \(name)") }
      return symbol
    }
    let key = trim(parts.last ?? "").lowercased()
    let names = [
      "return": "↩",
      "enter": "⌤",
      "tab": "⇥",
      "space": "Space",
      "delete": "⌫",
      "escape": "Esc",
      "left": "←",
      "right": "→",
      "up": "↑",
      "down": "↓",
      "home": "↖",
      "end": "↘",
      "pageup": "⇞",
      "pagedown": "⇟",
      "forwarddelete": "⌦",
    ]
    let displayed: String
    if let value = names[key] { displayed = value }
    else {
      try require(key.count == 1 || fullMatch("f(?:[1-9]|1[0-3])", key), "Unknown recorded key: \(key)")
      displayed = key.uppercased()
    }
    return ["⌃", "⌥", "⇧", "⌘"].filter { modifierSymbols.contains($0) }.joined() + displayed
  }

  static func escape(_ text: String) -> String {
    var value = text.replacingOccurrences(of: "{", with: "\\{").replacingOccurrences(of: "}", with: "\\}")
    value = value.replacingOccurrences(of: "\\\\([nNh])", with: "\\\\{}$1", options: .regularExpression)
    return value.replacingOccurrences(of: "\r\n", with: "\\N").replacingOccurrences(of: "\n", with: "\\N").replacingOccurrences(
      of: "\r",
      with: "\\N"
    )
  }

  static func timestamp(_ seconds: Double) -> String {
    let value = Int((seconds * 100).rounded())
    return String(format: "%d:%02d:%02d.%02d", value / 360000, value / 6000 % 60, value / 100 % 60, value % 100)
  }

  static func requireFont(_ family: String, texts: [String]) async throws {
    let output = try await runProcess(["fc-match", "-f", "%{family}\n%{charset}\n", family], capture: true)
    let result = lines(output)
    func normalized(_ value: String) -> String {
      value.lowercased().filter { !$0.isWhitespace }
    }
    try require(
      result.count >= 2 && result[0].components(separatedBy: ",").map(normalized).contains(normalized(family)),
      "Required narration font is unavailable: \(family)"
    )
    let ranges = try result[1].split(whereSeparator: \.isWhitespace).map { range -> ClosedRange<UInt32> in
      let bounds = range.split(separator: "-")
      guard
        let low = UInt32(bounds[0], radix: 16), let high = UInt32(bounds.last!, radix: 16),
        low <= high
      else { throw ToolError("Invalid font character range") }
      return low...high
    }
    let missing = Set(texts.flatMap(\.unicodeScalars).filter { scalar in
      !CharacterSet.whitespacesAndNewlines.contains(scalar) && !ranges.contains { $0.contains(scalar.value) }
    })
    try require(
      missing.isEmpty,
      "\(family) lacks narration glyphs: \(missing.sorted { $0.value < $1.value }.map(String.init).joined())"
    )
  }

  func catalog() throws -> JSON {
    let value = try JSON.read(workspace.root.at("DemoLab/Localization/Narration.json"))
    try require(value["sourceLanguage"].str == "en", "Narration catalog must use English source text")
    let strings = value["strings"]
    try require(!strings.object.isEmpty, "Narration catalog is empty")
    for (id, entry) in strings.object {
      try require(fullMatch("[a-z][a-z0-9-]*\\.[a-z][a-z0-9-]*", id), "Invalid narration cue: \(id)")
      for locale in locales {
        let text = entry[locale].str
        try require(!trim(text).isEmpty, "Missing narration: \(id)/\(locale)")
        try require(locale == "en" || text != entry["en"].str, "Untranslated narration: \(id)/\(locale)")
        try require(text.components(separatedBy: " | ").count <= 2, "Narration has more than two lines: \(id)/\(locale)")
      }
    }
    return strings
  }

  func render(timeline: JSON, locale: String, width: Int = 1920, height: Int = 1200) async throws -> String {
    let strings = try catalog()
    try Self.validate(timeline, film: timeline["film"].str, locale: locale, duration: timeline["durationSeconds"].double)
    guard let font = Self.fonts[locale] else { throw ToolError("Unsupported narration locale") }
    let events = timeline["events"].array
    let captions = try events.filter { $0["track"].str != "keys" }.map { event in
      let value = strings[event["id"].str][locale].str
      try require(!value.isEmpty, "Unresolved narration cue: \(event["id"].str)/\(locale)")
      return value
    }
    try await Self.requireFont(font, texts: captions)
    try await Self.requireFont(
      "Menlo",
      texts: events.filter { $0["track"].str == "keys" }.map { try Self.displayChord($0["chord"].str) }
    )
    let blocks = matches(#":root\s*\{([^}]+)\}"#, try workspace.root.at("web/style.css").text())
    try require(blocks.count >= 2, "Website dark palette is missing")
    let tokens = Dictionary(uniqueKeysWithValues: matches(#"--([\w-]+)\s*:\s*([^;]+);"#, blocks[1][1])
      .map { ($0[1], trim($0[2])) })
    func bgr(_ key: String) throws -> String {
      guard
        let color = tokens[key],
        fullMatch("#[0-9a-fA-F]{6}", color)
      else { throw ToolError("Missing narration palette color: \(key)") }
      let hex = Array(color.dropFirst())
      return String(hex[4...5] + hex[2...3] + hex[0...1]).uppercased()
    }
    let foreground = try bgr("text")
    let accent = try bgr("blue")
    func scaled(_ n: Int) -> Int {
      Int((Double(n) * Double(height) / 1200).rounded())
    }
    func style(
      _ name: String,
      _ family: String,
      _ size: Int,
      _ color: String,
      _ bold: Int,
      _ alignment: Int,
      _ left: Int,
      _ right: Int,
      _ bottom: Int,
      boxed: Bool = true
    ) -> String {
      "Style: \(name),\(family),\(scaled(size)),&H00\(color),&H00\(color),&H40141414,&H40141414,\(bold),0,0,0,100,100,0,0,\(boxed ? 3 : 1),\(boxed ? 10 : 0),0,\(alignment),\(scaled(left)),\(scaled(right)),\(scaled(bottom)),1"
    }
    var output = [
      "[Script Info]",
      "ScriptType: v4.00+",
      "PlayResX: \(width)",
      "PlayResY: \(height)",
      "WrapStyle: 2",
      "ScaledBorderAndShadow: yes",
      "",
      "[V4+ Styles]",
      "Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding",
      style("Caption", font, 38, foreground, -1, 5, 0, 0, 0, boxed: false),
      style("CaptionDetail", font, 26, foreground, 0, 5, 0, 0, 0, boxed: false),
      style("CaptionPanel", font, 10, "141414", 0, 7, 0, 0, 0, boxed: false),
      style("Chapter", font, 26, accent, -1, 7, 32, 700, 54),
      style("Keys", "Menlo", 38, accent, 0, 9, 1300, 32, 54),
      "",
      "[Events]",
      "Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text",
    ]
    for event in events {
      let track = event["track"].str
      if track == "caption" {
        let parts = strings[event["id"].str][locale].str.components(separatedBy: " | ")
        let start = Self.timestamp(event["start"].double)
        let end = Self.timestamp(event["end"].double)
        let left = (width - scaled(1440)) / 2
        let right = width - left
        let top = scaled(parts.count == 2 ? 1012 : 1030)
        let bottom = scaled(1110)
        output
          .append(
            "Dialogue: 0,\(start),\(end),CaptionPanel,,0,0,0,,{\\an7\\pos(0,0)\\p1\\1a&H45&\\fad(100,100)}m \(left) \(top) l \(right) \(top) \(right) \(bottom) \(left) \(bottom)"
          )
        output
          .append(
            "Dialogue: 1,\(start),\(end),Caption,,0,0,0,,{\\an5\\pos(\(width / 2),\(scaled(parts.count == 2 ? 1044 : 1068)))\\fad(100,100)}\(Self.escape(parts[0]))"
          )
        if parts.count == 2 {
          output
            .append(
              "Dialogue: 1,\(start),\(end),CaptionDetail,,0,0,0,,{\\an5\\pos(\(width / 2),\(scaled(1086)))\\1a&H20&\\fad(100,100)}\(Self.escape(parts[1]))"
            )
        }
        continue
      }
      let text: String
      let name: String
      if track == "keys" { name = "Keys"
        text = try Self.escape(Self.displayChord(event["chord"].str))
      } else {
        name = track == "chapter" ? "Chapter" : "Caption"
        text = Self.escape(strings[event["id"].str][locale].str)
      }
      output
        .append(
          "Dialogue: \(track == "keys" ? 1 : 0),\(Self.timestamp(event["start"].double)),\(Self.timestamp(event["end"].double)),\(name),,0,0,0,,{\\fad(100,100)}\(text)"
        )
    }
    return output.joined(separator: "\n") + "\n"
  }
}
