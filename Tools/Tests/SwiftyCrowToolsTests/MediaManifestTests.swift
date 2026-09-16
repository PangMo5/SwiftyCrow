// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
import Testing
@testable import SwiftyCrowToolsKit

@Suite("Reviewed media provenance")
struct MediaManifestTests {
  @Test(arguments: [
    "raw/en/tour-01/capture-demo.mov",
    "raw/en/tour-01/capture-demo.json",
    "raw/en/tour-01/scene.json",
    "raw/en/tour-01/presentation.json",
    "raw/en/tour-01/capture-translated-ax.txt",
    "media/en/tour.mp4",
    "media/en/tour.jpg",
    "media/en/tour.ass",
    "media/en/tour.timeline.json",
    "media/en/tour.json",
    "review.md",
    "DemoLab/Localization/Films.json",
  ])
  func rejectsChangedEvidenceWithoutReplacingTheManifest(_ changed: String) throws {
    let fixture = try ReviewFixture()
    defer { try? fm.removeItem(at: fixture.root) }
    try fixture.assemble()
    let original = try sha(fixture.merged)
    let file = fixture.root.at(changed)
    try file.write(file.text() + " ")
    #expect(throws: (any Error).self) { try fixture.bundle.verify(JSON.read(fixture.merged), portable: false) }
    #expect(try sha(fixture.merged) == original)
  }
}
