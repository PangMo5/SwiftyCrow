// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

// MARK: - NarrationTests

@Suite("Recorded narration contracts")
struct NarrationTests {

  @Test
  func `accepts synchronized narration`() throws {
    try FilmNarration.validate(NarrationFixture.timeline(), film: "tour", locale: "ko", duration: 10)
    #expect(try FilmNarration.displayChord("cmd + shift - 1") == "⇧⌘1")
    #expect(try FilmNarration.displayChord("ctrl + alt - l") == "⌃⌥L")
  }

  @Test(arguments: ["duration", "epoch", "locale", "shortCaption", "overlap", "lateOpening", "fakeKey"])
  func `rejects unreviewable or misidentified timing`(_ fault: String) throws {
    var value = try NarrationFixture.timeline()
    var events = value["events"].array
    switch fault {
    case "duration": value["durationSeconds"] = .decimal(11)
    case "epoch": value["captureEpochUptimeNanoseconds"] = .integer(0)
    case "locale": value["uiLanguage"] = .string("ja")
    case "shortCaption": events[1]["end"] = .decimal(0.5)
    case "overlap": events[1]["end"] = .decimal(4)
    case "lateOpening": events[0]["start"] = .decimal(2)
    case "fakeKey": events[3]["id"] = .string("Pretend shortcut")
    default: Issue.record("Unexpected fault case")
    }
    value["events"] = .array(events)
    #expect(throws: ToolError.self) { try FilmNarration.validate(value, film: "tour", locale: "ko", duration: 10) }
  }

  @Test
  func `accepts menu only demonstration without invented keycasts`() throws {
    var value = try NarrationFixture.timeline()
    value["events"] = .array(value["events"].array.filter { $0["track"].str != "keys" })
    try FilmNarration.validate(value, film: "tour", locale: "ko", duration: 10)
  }

  @Test
  func `preserves literal ASS control characters`() {
    #expect(FilmNarration.escape(#"Path \Notes {name}"#) == #"Path \{}Notes \{name\}"#)
    #expect(FilmNarration.escape("One\nTwo") == #"One\NTwo"#)
  }

}

// MARK: - NarrationFixture

enum NarrationFixture {
  static func timeline() throws -> JSON {
    try JSON
      .parse(
        #"{"schemaVersion":1,"film":"tour","uiLanguage":"ko","captureEpochUptimeNanoseconds":100000,"durationSeconds":10,"events":[{"track":"chapter","id":"tour.chapter","start":0,"end":10},{"track":"caption","id":"tour.intro","start":0,"end":3},{"track":"caption","id":"tour.capture","start":3,"end":10},{"track":"keys","chord":"cmd + shift - 1","start":3.1,"end":5.1}]}"#
      )
  }
}
