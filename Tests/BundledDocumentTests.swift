// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Testing
@testable import SwiftyCrow

struct BundledDocumentTests {
  @Test
  func licenseTextIsPreservedVerbatim() {
    let source = "  GNU AFFERO GENERAL PUBLIC LICENSE\n\nCopyright (C) 2007 Free Software Foundation, Inc.\n  Keep spacing, <tags>, and **literal text**.\n"
    let document = ParsedBundledDocument(plainText: source)
    #expect(document.blocks.count == 1)
    #expect(String(document.blocks[0].text.characters) == source)
    if case .code = document.blocks[0].kind { } else { Issue.record("License must render as verbatim text") }
  }

  @Test
  func noticeHeadingsLinksAndFencedLicenseContentRemainDistinct() throws {
    let license = "Copyright (C) Example\n\n# Literal license heading\n<!-- Preserve this notice -->\n    exact indentation"
    let source = "# Notices\n\n[License](LICENSE)\n\n~~~text\n\(license)\n~~~\n"
    let document = try ParsedBundledDocument(markdown: source, document: .thirdPartyNotices)
    let blocks = document.blocks.filter { if case .code = $0.kind { true } else { false } }
    #expect(blocks.count == 1)
    #expect(String(blocks[0].text.characters).trimmingCharacters(in: .newlines) == license)
    #expect(document.blocks.count(where: { if case .heading = $0.kind { true } else { false } }) == 1)
    #expect(document.blocks.contains { $0.text.runs.contains { $0.link?.scheme == "swiftycrow-document" } })
  }

  @Test
  func localizedOverviewLinksToTheEmbeddedOriginalAndLicenseStaysInApp() throws {
    let document = BundledDocument.thirdPartyNotices
    let original = document.resolveLink(try #require(URL(string: "../../THIRD_PARTY_NOTICES.md")), language: "ko")
    #expect(original.scheme == "swiftycrow-document")
    #expect(original.host == "thirdPartyNotices")
    #expect(original.fragment == "original-license-notices")
    let license = document.resolveLink(try #require(URL(string: "../../LICENSE")), language: "ko")
    #expect(license.host == "license")
    let external = try #require(URL(string: "https://github.com/vendor/library/blob/main/LICENSE"))
    #expect(document.resolveLink(external, language: "ko") == external)
  }

  @Test
  func documentLoaderKeepsTheFullOriginalAfterTheLocalizedOverview() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftyCrow-docs-\(UUID().uuidString).bundle")
    defer { try? FileManager.default.removeItem(at: root) }
    let resources = root.appendingPathComponent("Contents/Resources")
    try FileManager.default.createDirectory(at: resources.appendingPathComponent("ko"), withIntermediateDirectories: true)
    let info = ["CFBundleIdentifier": "dev.PangMo5.SwiftyCrow.documentTest", "CFBundlePackageType": "BNDL"]
    let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plist.write(to: root.appendingPathComponent("Contents/Info.plist"))
    try "# 서드파티 고지\n\n[전체 원문](../../THIRD_PARTY_NOTICES.md)\n".write(
      to: resources.appendingPathComponent("ko/THIRD_PARTY_NOTICES.md"),
      atomically: true,
      encoding: .utf8
    )
    try "# Third-Party Notices\n\nScope and copyright preamble.\n\n## Dependency\n\n~~~text\nComplete license text.\n~~~\n".write(
      to: resources.appendingPathComponent("THIRD_PARTY_NOTICES.md"),
      atomically: true,
      encoding: .utf8
    )
    let bundle = try #require(Bundle(url: root))
    let loaded = try await BundledDocumentLoader.shared.load(.thirdPartyNotices, language: "ko", bundle: bundle)
    #expect(loaded.blocks.contains { String($0.text.characters) == "Scope and copyright preamble." })
    #expect(loaded.blocks.contains { String($0.text.characters).contains("Complete license text.") })
    #expect(loaded.anchors["original-license-notices"] != nil)
  }
}
