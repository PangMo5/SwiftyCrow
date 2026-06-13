import Foundation

// MARK: - AppSettings

struct AppSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = AppSettings()
    capture = try c.decodeIfPresent(CaptureSettings.self, forKey: .capture) ?? d.capture
    languages = try c.decodeIfPresent(LanguageSettings.self, forKey: .languages) ?? d.languages
    overlay = try c.decodeIfPresent(OverlaySettings.self, forKey: .overlay) ?? d.overlay
    recognition = try c.decodeIfPresent(RecognitionSettings.self, forKey: .recognition) ?? d.recognition
    shortcuts = try c.decodeIfPresent(ShortcutSettings.self, forKey: .shortcuts) ?? d.shortcuts
    translation = try c.decodeIfPresent(TranslationSettings.self, forKey: .translation) ?? d.translation
    updates = try c.decodeIfPresent(UpdateSettings.self, forKey: .updates) ?? d.updates
  }

  // MARK: Internal

  var capture = CaptureSettings()
  var languages = LanguageSettings()
  var overlay = OverlaySettings()
  var recognition = RecognitionSettings()
  var shortcuts = ShortcutSettings()
  var translation = TranslationSettings()
  var updates = UpdateSettings()

}

// MARK: - CaptureSettings

struct CaptureSettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = CaptureSettings()
    interval = try c.decodeIfPresent(Double.self, forKey: .interval) ?? d.interval
  }

  var interval = 0.8
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

  var displayName: String {
    switch self {
    case .inPlace: "In-place"
    case .window: "Window"
    }
  }
}

// MARK: - RecognitionSettings

struct RecognitionSettings: Codable, Equatable, Sendable {
  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = RecognitionSettings()
    mode = try c.decodeIfPresent(OCRMode.self, forKey: .mode) ?? d.mode
  }

  var mode = OCRMode.text
}

// MARK: - ShortcutSettings

struct ShortcutSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let d = ShortcutSettings()
    selectRegion = try c.decodeIfPresent(HotKey.self, forKey: .selectRegion) ?? d.selectRegion
    liveOverlay = try c.decodeIfPresent(HotKey.self, forKey: .liveOverlay) ?? d.liveOverlay
    toggleLive = try c.decodeIfPresent(HotKey.self, forKey: .toggleLive) ?? d.toggleLive
    toggleLiveMode = try c.decodeIfPresent(HotKey.self, forKey: .toggleLiveMode) ?? d.toggleLiveMode
    regionSave = try c.decodeIfPresent(HotKey.self, forKey: .regionSave) ?? d.regionSave
    regionCopyImage = try c.decodeIfPresent(HotKey.self, forKey: .regionCopyImage) ?? d.regionCopyImage
    regionCopyOriginal = try c.decodeIfPresent(HotKey.self, forKey: .regionCopyOriginal) ?? d.regionCopyOriginal
    regionCopyTranslation = try c.decodeIfPresent(HotKey.self, forKey: .regionCopyTranslation) ?? d.regionCopyTranslation
  }

  // MARK: Internal

  /// Global hotkeys — unbound by default; the user assigns them.
  var selectRegion: HotKey?
  /// Starts (or re-places) the live overlay by selecting a region/window.
  /// Renamed from `toggleOverlay` in 2.6.0.
  var liveOverlay: HotKey?
  var toggleLive: HotKey?
  var toggleLiveMode: HotKey?

  // Capture-result-window shortcuts — ⌘ defaults, active only while that window
  // is focused (matched locally, never registered globally).
  var regionSave: HotKey? = HotKey(carbonKeyCode: 1, carbonModifiers: 256) // ⌘S
  var regionCopyImage: HotKey? = HotKey(carbonKeyCode: 8, carbonModifiers: 256) // ⌘C
  var regionCopyOriginal: HotKey? = HotKey(carbonKeyCode: 31, carbonModifiers: 256) // ⌘O
  var regionCopyTranslation: HotKey? = HotKey(carbonKeyCode: 17, carbonModifiers: 256) // ⌘T
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

  var displayName: String {
    switch self {
    case .hourly: "Every hour"
    case .daily: "Every day"
    case .weekly: "Every week"
    }
  }
}

// MARK: - OCRMode

enum OCRMode: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case text
  case document

  var id: String {
    rawValue
  }

  var displayName: String {
    switch self {
    case .text: "Text"
    case .document: "Document"
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

  var displayName: String {
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
