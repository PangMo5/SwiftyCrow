// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// MARK: - AppSettings

struct AppSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppSettings()
    languages = try c.decodeIfPresent(LanguageSettings.self, forKey: .languages) ?? d.languages
    overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? d.overlay
    shortcuts = try c.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts) ?? d.shortcuts
    translation = try c.decodeIfPresent(TranslationSettings.self, forKey: .translation) ?? d.translation
    updates = try c.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? d.updates
  }

  // MARK: Internal

  var languages = LanguageSettings()
  var overlay = OverlaySettings()
  var shortcuts = ShortcutSettings()
  var translation = TranslationSettings()
  var updates = UpdateSettings()

}

// MARK: - LanguageSettings

struct LanguageSettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = LanguageSettings()
    source = try c.decodeIfPresent(Language.self, forKey: .source) ?? d.source
    target = try c.decodeIfPresent(Language.self, forKey: .target) ?? d.target
  }

  var source = Language.auto
  var target = Language.systemPreferred()
}

// MARK: - OverlaySettings

struct OverlaySettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = OverlaySettings()
    hideOnHover = try c.decodeIfPresent(Bool.self, forKey: .hideOnHover) ?? d.hideOnHover
    liveMode = try c.decodeIfPresent(OverlayLiveMode.self, forKey: .liveMode) ?? d.liveMode
  }

  var hideOnHover = false
  /// How a live translation is shown: drawn in place over the source, or in a
  /// separate window while the overlay stays a thin region frame.
  var liveMode = OverlayLiveMode.inPlace
}

// MARK: - OverlayLiveMode

enum OverlayLiveMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case inPlace
  case window

  var id: String {
    rawValue
  }

  var displayName: LocalizedStringResource {
    switch self {
    case .inPlace: "In-place"
    case .window: "Window"
    }
  }
}

// MARK: - ShortcutSettings

struct ShortcutSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ShortcutSettings()
    func shortcut(_ key: CodingKeys, default value: HotKey? = nil) throws -> HotKey? {
      // An empty string represents an explicitly cleared shortcut in TOML.
      if (try? c.decode(String.self, forKey: key)) == "" { return nil }
      return try c.decodeIfPresent(HotKey.self, forKey: key) ?? value
    }
    selectRegion = try shortcut(.selectRegion, default: d.selectRegion)
    liveOverlay = try shortcut(.liveOverlay, default: d.liveOverlay)
    toggleLive = try shortcut(.toggleLive)
    toggleLiveMode = try shortcut(.toggleLiveMode)
    toggleLiveOverlay = try shortcut(.toggleLiveOverlay)
    regionSave = try shortcut(.regionSave, default: d.regionSave)
    regionCopyImage = try shortcut(.regionCopyImage, default: d.regionCopyImage)
    regionCopyOriginal = try shortcut(.regionCopyOriginal, default: d.regionCopyOriginal)
    regionCopyTranslation = try shortcut(.regionCopyTranslation, default: d.regionCopyTranslation)
  }

  // MARK: Internal

  enum CodingKeys: String, CodingKey {
    case selectRegion
    case liveOverlay
    case toggleLive
    case toggleLiveMode
    case toggleLiveOverlay
    case regionSave
    case regionCopyImage
    case regionCopyOriginal
    case regionCopyTranslation
  }

  /// Default bindings also apply when these keys are omitted from config.toml.
  var selectRegion: HotKey? = HotKey(carbonKeyCode: 18, carbonModifiers: 768) // ⇧⌘1
  /// Starts (or re-places) the live overlay by selecting a region/window.
  /// Renamed from `toggleOverlay` in 2.6.0.
  var liveOverlay: HotKey? = HotKey(carbonKeyCode: 19, carbonModifiers: 768) // ⇧⌘2
  var toggleLive: HotKey?
  var toggleLiveMode: HotKey?
  /// Shows or hides the live overlay on the last-used region — no re-selecting.
  /// The region persists across launches (overlay-frame.json), so this is the
  /// "predefine an area, then flip translation on/off" shortcut (issue #9).
  var toggleLiveOverlay: HotKey?

  // Capture-result-window shortcuts — ⌘ defaults, active only while that window
  // is focused (matched locally, never registered globally).
  var regionSave: HotKey? = HotKey(carbonKeyCode: 1, carbonModifiers: 256) // ⌘S
  var regionCopyImage: HotKey? = HotKey(carbonKeyCode: 8, carbonModifiers: 256) // ⌘C
  var regionCopyOriginal: HotKey? = HotKey(carbonKeyCode: 31, carbonModifiers: 256) // ⌘O
  var regionCopyTranslation: HotKey? = HotKey(carbonKeyCode: 17, carbonModifiers: 256) // ⌘T

  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    if let selectRegion { try c.encode(selectRegion, forKey: .selectRegion) }
    else { try c.encode("", forKey: .selectRegion) }
    if let liveOverlay { try c.encode(liveOverlay, forKey: .liveOverlay) }
    else { try c.encode("", forKey: .liveOverlay) }
    if let toggleLive { try c.encode(toggleLive, forKey: .toggleLive) }
    else { try c.encode("", forKey: .toggleLive) }
    if let toggleLiveMode { try c.encode(toggleLiveMode, forKey: .toggleLiveMode) }
    else { try c.encode("", forKey: .toggleLiveMode) }
    if let toggleLiveOverlay { try c.encode(toggleLiveOverlay, forKey: .toggleLiveOverlay) }
    else { try c.encode("", forKey: .toggleLiveOverlay) }
    if let regionSave { try c.encode(regionSave, forKey: .regionSave) }
    else { try c.encode("", forKey: .regionSave) }
    if let regionCopyImage { try c.encode(regionCopyImage, forKey: .regionCopyImage) }
    else { try c.encode("", forKey: .regionCopyImage) }
    if let regionCopyOriginal { try c.encode(regionCopyOriginal, forKey: .regionCopyOriginal) }
    else { try c.encode("", forKey: .regionCopyOriginal) }
    if let regionCopyTranslation { try c.encode(regionCopyTranslation, forKey: .regionCopyTranslation) }
    else { try c.encode("", forKey: .regionCopyTranslation) }
  }

}

// MARK: - TranslationSettings

struct TranslationSettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = TranslationSettings()
    strategy = try c.decodeIfPresent(TranslationStrategy.self, forKey: .strategy) ?? d.strategy
  }

  var strategy = TranslationStrategy.lowLatency
}

// MARK: - UpdateSettings

struct UpdateSettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = UpdateSettings()
    automaticChecks = try c.decodeIfPresent(Bool.self, forKey: .automaticChecks) ?? d.automaticChecks
    checkInterval = try c.decodeIfPresent(UpdateCheckInterval.self, forKey: .checkInterval) ?? d.checkInterval
  }

  var automaticChecks = true
  var checkInterval = UpdateCheckInterval.daily
}

// MARK: - UpdateCheckInterval

enum UpdateCheckInterval: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case hourly
  case daily
  case weekly

  // MARK: Internal

  var id: String {
    rawValue
  }

  var seconds: TimeInterval {
    switch self {
    case .hourly: 3600
    case .daily: 86400
    case .weekly: 604_800
    }
  }

  var displayName: LocalizedStringResource {
    switch self {
    case .hourly: "Every hour"
    case .daily: "Every day"
    case .weekly: "Every week"
    }
  }
}

// MARK: - TranslationStrategy

enum TranslationStrategy: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case lowLatency
  case highFidelity

  var id: String {
    rawValue
  }

  var displayName: LocalizedStringResource {
    switch self {
    case .lowLatency: "Low latency"
    case .highFidelity: "High fidelity (Apple Intelligence)"
    }
  }
}

// MARK: - ConfigPath

enum ConfigPath {
  static let fileName = "config.toml"
  static let directoryName = "SwiftyCrow"

  static var url: URL {
    directory.appending(path: fileName)
  }

  static var directory: URL {
    let env = ProcessInfo.processInfo.environment
    if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
      return URL(fileURLWithPath: xdg, isDirectory: true).appending(path: directoryName)
    }
    return URL.homeDirectory
      .appending(path: ".config", directoryHint: .isDirectory)
      .appending(path: directoryName, directoryHint: .isDirectory)
  }
}
