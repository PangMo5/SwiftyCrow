import Foundation

// MARK: - AppSettings

struct AppSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AppSettings()
    automaticallyChecksForUpdates = try container
      .decodeIfPresent(Bool.self, forKey: .automaticallyChecksForUpdates) ?? defaults.automaticallyChecksForUpdates
    captureInterval = try container.decodeIfPresent(Double.self, forKey: .captureInterval) ?? defaults.captureInterval
    captureOnceHotKey = try container.decodeIfPresent(HotKey.self, forKey: .captureOnceHotKey)
    ocrMode = try container.decodeIfPresent(OCRMode.self, forKey: .ocrMode) ?? defaults.ocrMode
    overlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? defaults.overlayEnabled
    overlayHideOnHover = try container.decodeIfPresent(Bool.self, forKey: .overlayHideOnHover) ?? defaults.overlayHideOnHover
    sourceLanguage = try container.decodeIfPresent(Language.self, forKey: .sourceLanguage) ?? defaults.sourceLanguage
    targetLanguage = try container.decodeIfPresent(Language.self, forKey: .targetLanguage) ?? defaults.targetLanguage
    toggleLiveHotKey = try container.decodeIfPresent(HotKey.self, forKey: .toggleLiveHotKey)
    toggleOverlayHotKey = try container.decodeIfPresent(HotKey.self, forKey: .toggleOverlayHotKey)
    translationStrategy = try container
      .decodeIfPresent(TranslationStrategy.self, forKey: .translationStrategy) ?? defaults.translationStrategy
    updateCheckInterval = try container
      .decodeIfPresent(UpdateCheckInterval.self, forKey: .updateCheckInterval) ?? defaults.updateCheckInterval
  }

  // MARK: Internal

  var automaticallyChecksForUpdates = true
  var captureInterval = 0.8
  var captureOnceHotKey: HotKey?
  var ocrMode = OCRMode.text
  var overlayEnabled = true
  var overlayHideOnHover = false
  var sourceLanguage = Language.auto
  var targetLanguage = Language.systemPreferred()
  var toggleLiveHotKey: HotKey?
  var toggleOverlayHotKey: HotKey?
  var translationStrategy = TranslationStrategy.lowLatency
  var updateCheckInterval = UpdateCheckInterval.daily

}

// MARK: - UpdateCheckInterval

enum UpdateCheckInterval: String, Codable, Equatable, Sendable, CaseIterable, Identifiable {
  case hourly
  case daily
  case weekly

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
