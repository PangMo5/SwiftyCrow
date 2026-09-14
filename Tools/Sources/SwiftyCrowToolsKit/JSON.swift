// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Dynamic manifest fields use Foundation Codable; no custom JSON grammar or writer.
indirect enum JSON: Sendable, Equatable, Codable {
  case object([(String, JSON)])
  case array([JSON])
  case string(String)
  case number(String)
  case bool(Bool)
  case null

  // MARK: Lifecycle

  init(from decoder: any Decoder) throws {
    let value = try decoder.singleValueContainer()
    if value.decodeNil() { self = .null }
    else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
    else if let text = try? value.decode(String.self) { self = .string(text) }
    else if let number = try? value.decode(Int64.self) { self = .number(String(number)) }
    else if let number = try? value.decode(Double.self) { self = .number(String(number)) }
    else if let array = try? value.decode([JSON].self) { self = .array(array) }
    else {
      let object = try value.decode([String: JSON].self)
      self = .object(object.sorted { $0.key < $1.key }.map { ($0.key, $0.value) })
    }
  }

  // MARK: Internal

  var object: [(String, JSON)] {
    if case .object(let value) = self { return value }
    return []
  }

  var array: [JSON] {
    if case .array(let value) = self { return value }
    return []
  }

  var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  var str: String {
    string ?? ""
  }

  var double: Double {
    if case .number(let value) = self { return Double(value) ?? .nan }
    return Double(str) ?? .nan
  }

  var int: Int {
    double.isFinite ? Int(double) : 0
  }

  var boolean: Bool {
    self == .bool(true)
  }

  var isNull: Bool {
    self == .null
  }

  static func ==(lhs: JSON, rhs: JSON) -> Bool {
    switch (lhs, rhs) {
    case (.object(let a), .object(let b)):
      a.count == b.count && a.allSatisfy { key, value in b.first { $0.0 == key }?.1 == value }
    case (.array(let a), .array(let b)): a == b
    case (.string(let a), .string(let b)): a == b
    case (.number(let a), .number(let b)): Double(a) == Double(b)
    case (.bool(let a), .bool(let b)): a == b
    case (.null, .null): true
    default: false
    }
  }

  static func integer(_ value: Int) -> JSON {
    .number(String(value))
  }

  static func decimal(_ value: Double) -> JSON {
    .number(String(value))
  }

  static func read(_ file: URL) throws -> JSON {
    try parse(file.text())
  }

  static func parse(_ source: String) throws -> JSON {
    try JSONDecoder().decode(JSON.self, from: Data(source.utf8))
  }

  static func quote(_ text: String) -> String {
    // Encoding a String cannot fail; withoutEscapingSlashes matches .strings syntax.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return String(decoding: try! encoder.encode(text), as: UTF8.self)
  }

  subscript(_ key: String) -> JSON {
    get { if case .object(let entries) = self { return entries.first { $0.0 == key }?.1 ?? .null }
      return .null
    }
    set {
      var entries = object
      if let index = entries.firstIndex(where: { $0.0 == key }) { entries[index].1 = newValue }
      else { entries.append((key, newValue)) }
      self = .object(entries)
    }
  }

  subscript(_ index: Int) -> JSON {
    get { array[index] }
    set { var items = array
      items[index] = newValue
      self = .array(items)
    }
  }

  mutating func remove(_ key: String) {
    self = .object(object.filter { $0.0 != key })
  }

  func merging(_ entries: [(String, JSON)]) -> JSON {
    var value = self
    for (key, item) in entries { value[key] = item }
    return value
  }

  func rendered() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(self), as: UTF8.self)
  }

  func write(_ file: URL) throws {
    // Existing scene bytes are referenced by accepted captures. Equivalent data
    // is already current, so changing serializer formatting must not invalidate it.
    if file.exists, try Self.read(file) == self { return }
    try file.write(rendered() + "\n")
  }

  func encode(to encoder: any Encoder) throws {
    var value = encoder.singleValueContainer()
    switch self {
    case .null: try value.encodeNil()
    case .bool(let bool): try value.encode(bool)
    case .string(let text): try value.encode(text)
    case .array(let array): try value.encode(array)
    case .object(let object): try value.encode(Dictionary(uniqueKeysWithValues: object))
    case .number(let number):
      if let integer = Int64(number) { try value.encode(integer) }
      else if let decimal = Double(number), decimal.isFinite { try value.encode(decimal) }
      else { throw ToolError("Invalid JSON number: \(number)") }
    }
  }
}
