// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Recorded narration contracts")
struct NarrationTests {
  func timeline() throws -> JSON {
    try JSON
      .parse(
        #"{"schemaVersion":1,"film":"tour","uiLanguage":"ko","captureEpochUptimeNanoseconds":100000,"durationSeconds":10,"events":[{"track":"chapter","id":"tour.chapter","start":0,"end":10},{"track":"caption","id":"tour.intro","start":0,"end":3},{"track":"caption","id":"tour.capture","start":3,"end":10},{"track":"keys","chord":"cmd + shift - 1","start":3.1,"end":5.1}]}"#
      )
  }

  @Test
  func acceptsSynchronizedNarration() throws {
    try FilmNarration.validate(timeline(), film: "tour", locale: "ko", duration: 10)
    #expect(try FilmNarration.displayChord("cmd + shift - 1") == "⇧⌘1")
    #expect(try FilmNarration.displayChord("ctrl + alt - l") == "⌃⌥L")
  }

  @Test(arguments: ["duration", "epoch", "locale", "shortCaption", "overlap", "lateOpening", "fakeKey", "noKey"])
  func rejectsUnreviewableOrMisidentifiedTiming(_ fault: String) throws {
    var value = try timeline()
    var events = value["events"].array
    switch fault {
    case "duration": value["durationSeconds"] = .decimal(11)
    case "epoch": value["captureEpochUptimeNanoseconds"] = .integer(0)
    case "locale": value["uiLanguage"] = .string("ja")
    case "shortCaption": events[1]["end"] = .decimal(0.5)
    case "overlap": events[1]["end"] = .decimal(4)
    case "lateOpening": events[0]["start"] = .decimal(2)
    case "fakeKey": events[3]["id"] = .string("Pretend shortcut")
    default: events.removeLast()
    }
    value["events"] = .array(events)
    #expect(throws: ToolError.self) { try FilmNarration.validate(value, film: "tour", locale: "ko", duration: 10) }
  }

  @Test
  func preservesLiteralASSControlCharacters() {
    #expect(FilmNarration.escape(#"Path \Notes {name}"#) == #"Path \{}Notes \{name\}"#)
    #expect(FilmNarration.escape("One\nTwo") == #"One\NTwo"#)
  }
}
