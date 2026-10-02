// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import Foundation
import IssueReporting
import Testing

// MARK: - TestRunner

@main
struct TestRunner {
  @MainActor
  static func main() async {
    guard CommandLine.arguments.count >= 2, isTesting else { exit(2) }
    let output = CommandLine.arguments[1]
    guard !FileManager.default.fileExists(atPath: output) else { exit(2) }
    _ = NSApplication.shared
    var arguments = Testing.__CommandLineArguments_v0()
    arguments.experimentalMaximumParallelizationWidth = 4
    arguments.xunitOutput = output
    if CommandLine.arguments.count > 2 { arguments.filter = Array(CommandLine.arguments.dropFirst(2)) }
    let result: Int32 = await Testing.__swiftPMEntryPoint(passing: arguments)
    guard
      let document = try? XMLDocument(contentsOf: URL(fileURLWithPath: output)),
      let cases = try? document.nodes(forXPath: "//testcase"),
      cases.contains(where: { ($0 as? XMLElement)?.elements(forName: "skipped").isEmpty == true })
    else { exit(1) }
    exit(result)
  }
}

@Test
func standaloneRunnerIsolatesDependencies() throws {
  let current = try #require(Test.current)
  guard case .swiftTesting(let context?) = TestContext.current else {
    Issue.record("Swift Testing context is unavailable to dependency libraries")
    return
  }
  #expect(String(reflecting: context.test.id.rawValue.base).contains(current.name))
  @Dependency(\.context) var dependencyContext
  #expect(dependencyContext == .test)
}
