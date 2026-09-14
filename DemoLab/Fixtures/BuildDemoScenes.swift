// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// Build the independent source application outside the source tree.
// Usage: swift DemoLab/Fixtures/BuildDemoScenes.swift /absolute/output/DemoScenes.app
guard CommandLine.arguments.count == 2 else {
  fputs("Usage: BuildDemoScenes.swift OUTPUT.app\n", stderr)
  exit(2)
}

let app = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
let info: [String: Any] = [
  "CFBundleExecutable": "DemoScenes",
  "CFBundleIdentifier": "dev.PangMo5.SwiftyCrow.DemoScenes",
  "CFBundleName": "Demo Scenes",
  "CFBundlePackageType": "APPL",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "NSHighResolutionCapable": true,
  "LSMinimumSystemVersion": "26.0",
]
try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
  .write(to: app.appendingPathComponent("Contents/Info.plist"))
func run(_ executable: String, _ arguments: [String]) throws {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
}

try run(
  "/usr/bin/xcrun",
  [
    "swiftc",
    "-parse-as-library",
    "-target",
    "arm64-apple-macosx26.0",
    sources.appendingPathComponent("DemoScenes.swift").path,
    "-o",
    app.appendingPathComponent("Contents/MacOS/DemoScenes").path,
  ]
)
try run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
print(app.path)
