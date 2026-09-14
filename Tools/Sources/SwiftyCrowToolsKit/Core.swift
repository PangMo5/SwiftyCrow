// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Subprocess
#if canImport(System)
import System
#else
import SystemPackage
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

// MARK: - ToolError

struct ToolError: Error, CustomStringConvertible {
  init(_ message: String) {
    description = message
  }

  let description: String
}

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
  if try !condition() { throw ToolError(message) }
}

let locales = ["en", "ko", "ja", "zh-Hans", "zh-Hant"]
let languageNames = ["en": "English", "ko": "한국어", "ja": "日本語", "zh-Hans": "简体中文", "zh-Hant": "繁體中文"]
var fm: FileManager {
  FileManager()
}

extension URL {
  var exists: Bool {
    fm.fileExists(atPath: path)
  }

  var stem: String {
    deletingPathExtension().lastPathComponent
  }

  func at(_ path: String) -> URL {
    appendingPathComponent(path)
  }

  func replacingExtension(_ suffix: String) -> URL {
    deletingPathExtension().appendingPathExtension(suffix)
  }

  func text() throws -> String {
    try String(contentsOf: self, encoding: .utf8)
  }

  func makeDirectory() throws {
    try fm.createDirectory(at: self, withIntermediateDirectories: true)
  }

  func write(_ text: String) throws {
    try deletingLastPathComponent().makeDirectory()
    try Data(text.utf8).write(to: self, options: .atomic)
  }

  func children() throws -> [URL] {
    try fm.contentsOfDirectory(at: self, includingPropertiesForKeys: nil).sorted { $0.lastPathComponent < $1.lastPathComponent }
  }
}

func copy(_ source: URL, _ target: URL) throws {
  try require(source.exists, "Copy source is missing: \(source.path)")
  try require(
    source.resolvingSymlinksInPath() != target.resolvingSymlinksInPath(),
    "Copy source and destination are the same: \(source.path)"
  )
  try target.deletingLastPathComponent().makeDirectory()
  if target.exists { try fm.removeItem(at: target) }
  try fm.copyItem(at: source, to: target)
}

func sha(_ data: Data) -> String {
  SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func sha(_ file: URL) throws -> String {
  let stream = try FileHandle(forReadingFrom: file)
  defer { try? stream.close() }
  var hash = SHA256()
  while let data = try stream.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
  return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

func textKey(_ text: String) -> String {
  String(sha(Data(text.utf8)).prefix(16))
}

func matches(_ pattern: String, _ text: String) -> [[String]] {
  let regex = try! NSRegularExpression(pattern: pattern)
  return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
    (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
  }
}

func replacing(_ pattern: String, in text: String, _ transform: ([String]) throws -> String) rethrows -> String {
  let regex = try! NSRegularExpression(pattern: pattern)
  var result = ""
  var cursor = text.startIndex
  for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
    let groups = (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    let replacement = try transform(groups)
    let range = Range(match.range, in: text)!
    result += text[cursor..<range.lowerBound] + replacement
    cursor = range.upperBound
  }
  return result + text[cursor...]
}

func trim(_ value: String) -> String {
  value.trimmingCharacters(in: .whitespacesAndNewlines)
}

func fullMatch(_ pattern: String, _ text: String) -> Bool {
  !matches("^(?:" + pattern + ")$", text).isEmpty
}

func lines(_ text: String) -> [String] {
  var result = text.components(separatedBy: .newlines)
  if result.last == "" { result.removeLast() }
  return result
}

func relativePath(_ target: URL, from directory: URL) -> String {
  let a = target.standardizedFileURL.pathComponents
  let b = directory.standardizedFileURL.pathComponents
  let common = zip(a, b).prefix { $0 == $1 }.count
  return (Array(repeating: "..", count: b.count - common) + a.dropFirst(common)).joined(separator: "/")
}

/// The package owns pipe draining, cancellation, signal handling and child reaping.
@discardableResult
func runProcess(
  _ arguments: [String],
  cwd: URL? = nil,
  environment: [String: String] = [:],
  capture: Bool = false
) async throws -> String {
  try require(!arguments.isEmpty, "Missing executable")
  let executable: Executable = arguments[0].contains("/") ? .path(FilePath(arguments[0])) : .name(arguments[0])
  let argv = Subprocess.Arguments(Array(arguments.dropFirst()))
  let overrides = Dictionary(uniqueKeysWithValues: environment.map { (
    Subprocess.Environment.Key(stringLiteral: $0.key),
    Optional($0.value)
  ) })
  if capture {
    let result = try await Subprocess.run(
      executable,
      arguments: argv,
      environment: .inherit.updating(overrides),
      workingDirectory: cwd.map { FilePath($0.path) },
      output: .string(limit: 16 * 1024 * 1024),
      error: .currentStandardError
    )
    try require(result.terminationStatus == .exited(0), "\(arguments[0]): \(result.terminationStatus)")
    return result.standardOutput
  }
  let result = try await Subprocess.run(
    executable,
    arguments: argv,
    environment: .inherit.updating(overrides),
    workingDirectory: cwd.map { FilePath($0.path) },
    output: .currentStandardOutput,
    error: .currentStandardError
  )
  try require(result.terminationStatus == .exited(0), "\(arguments[0]): \(result.terminationStatus)")
  return ""
}

// MARK: - Workspace

struct Workspace: Sendable {
  let root: URL

  static func discover(_ explicit: String?) throws -> Self {
    var root = URL(fileURLWithPath: explicit ?? FileManager.default.currentDirectoryPath).standardizedFileURL
    while !root.at("Resources/Localizable.xcstrings").exists || !root.at("Project.swift").exists {
      let parent = root.deletingLastPathComponent()
      try require(parent != root, "Could not locate the SwiftyCrow repository")
      root = parent
    }
    return Self(root: root)
  }
}
