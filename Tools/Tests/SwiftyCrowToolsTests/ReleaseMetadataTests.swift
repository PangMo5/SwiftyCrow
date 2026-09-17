// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import Testing
@testable import SwiftyCrowToolsKit

// MARK: - ReleaseMetadataTests

@Suite("Localized release metadata")
struct ReleaseMetadataTests {
  var workspace: Workspace {
    Workspace(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent())
  }

  @Test
  func publicationRequiresADateWhileReviewCanUseVersionedDrafts() throws {
    let root = fm.temporaryDirectory.at("release-draft-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    let workspace = Workspace(root: root)
    let builder = DocumentBuilder(workspace: workspace)
    for locale in locales {
      try builder.destination("CHANGELOG.md", locale).write("## 3.0.0 (Unreleased)\n\n- Reviewed changes.\n")
    }
    let metadata = ReleaseMetadata(workspace: workspace)
    try metadata.validateRelease(version: "3.0.0", allowUnreleased: true)
    #expect(throws: ToolError.self) { try metadata.validateRelease(version: "3.0.0", allowUnreleased: false) }
    try root.at("CHANGELOG.md").write("## 3.0.0 (2026-09-17)\n\n- Reviewed changes.\n")
    try metadata.validateRelease(version: "3.0.0", allowUnreleased: false)
  }

  @Test
  func preparedReleaseNotesExistInEveryLocaleAndMissingVersionFails() throws {
    let notes = try ReleaseMetadata(workspace: workspace).localizedNotes(version: "2.10.0")
    #expect(notes.count == locales.count)
    #expect(notes.allSatisfy { $0.1.contains("2.10.0") && $0.1.contains("⇧⌘1") })
    #expect(throws: ToolError.self) { try ReleaseMetadata(workspace: workspace).localizedNotes(version: "99.0.0") }
  }

  @Test
  func notesCoverEveryLocaleAndPreserveTheSignedEnclosure() throws {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try temporary.makeDirectory()
    defer { try? FileManager.default.removeItem(at: temporary) }
    let file = temporary.at("appcast.xml")
    try file.write("""
      <?xml version="1.0" encoding="utf-8"?>
      <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0"><channel><item>
      <title>2.9.1</title><enclosure url="https://example.com/app.dmg" sparkle:edSignature="test-signature" length="123" type="application/octet-stream"/>
      <description>Old English notes</description>
      </item></channel></rss>
      """)
    let metadata = ReleaseMetadata(workspace: workspace)
    try metadata.embedNotes(file: file, version: "2.9.1")
    let document = try XMLDocument(contentsOf: file)
    let descriptions = try document.nodes(forXPath: "/rss/channel/item/description").compactMap { $0 as? XMLElement }
    #expect(Set(descriptions.compactMap { $0.attribute(forName: "xml:lang")?.stringValue }) == Set(locales))
    #expect(descriptions.allSatisfy { ($0.stringValue ?? "").contains("2.9.1") })
    #expect(descriptions.allSatisfy { !($0.stringValue ?? "").contains("Old English notes") })
    let enclosure = try #require(document.nodes(forXPath: "/rss/channel/item/enclosure").first as? XMLElement)
    #expect(enclosure.attribute(forName: "sparkle:edSignature")?.stringValue == "test-signature")
    #expect(enclosure.attribute(forName: "url")?.stringValue == "https://example.com/app.dmg")
    let before = try Data(contentsOf: file)
    try metadata.embedNotes(file: file, version: "2.9.1")
    #expect(try Data(contentsOf: file) == before)
  }

  @Test
  func byteRangesUsedByVideoPlayersAreBounded() throws {
    #expect(try PreviewRange.resolve("bytes=0-1", size: 100) == 0...1)
    #expect(try PreviewRange.resolve("bytes=-10", size: 100) == 90...99)
    #expect(try PreviewRange.resolve("bytes=20-", size: 100) == 20...99)
    #expect(try PreviewRange.resolve("bytes=90-200", size: 100) == 90...99)
    #expect(throws: ToolError.self) { try PreviewRange.resolve("bytes=100-", size: 100) }
    #expect(throws: ToolError.self) { try PreviewRange.resolve("bytes=-0", size: 100) }
    #expect(throws: ToolError.self) { try PreviewRange.resolve("bytes=1-2,5-6", size: 100) }
  }
}
