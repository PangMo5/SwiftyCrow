// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
@testable import SwiftyCrow

@main
struct CaptureProbe {
  @MainActor
  static func main() async throws {
    guard CommandLine.arguments.count == 3 else {
      print("Usage: CaptureProbe corpus-root new-output-directory")
      exit(2)
    }
    _ = NSApplication.shared
    let root = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: output.path) else {
      throw CocoaError(.fileWriteFileExists)
    }
    let cases = try CaptureQualitySelection.load(root: root)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let runner = CaptureQualityRunner()
    var records = [[String: Any]]()
    for item in cases {
      do {
        let report = try await runner.run(item, root: root, output: output)
        records.append(["id": item.id, "issues": report.issues])
        print("\(item.id): \(report.issues.isEmpty ? "passed" : report.issues.joined(separator: "; "))")
      } catch {
        let issues = [String(describing: error)]
        records.append(["id": item.id, "issues": issues])
        print("\(item.id): \(issues[0])")
      }
      fflush(stdout)
    }
    let failures = records.count { !($0["issues"] as! [String]).isEmpty }
    try JSONSerialization.data(withJSONObject: [
      "operatingSystem": ProcessInfo.processInfo.operatingSystemVersionString,
      "cases": records,
      "failures": failures,
      "sourceAcquisition": "fixture",
      "translation": "installed Apple models",
    ], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("summary.json"))
    print("Completed \(cases.count) cases; \(failures) require review")
    exit(failures == 0 ? 0 : 1)
  }
}
