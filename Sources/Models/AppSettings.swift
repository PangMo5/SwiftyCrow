import Foundation

// MARK: - AppSettings

struct AppSettings: Codable, Equatable, Sendable {

  // MARK: Lifecycle

  init() { }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = AppSettings()
    captureInterval = try container.decodeIfPresent(Double.self, forKey: .captureInterval) ?? defaults.captureInterval
    ocrMode = try container.decodeIfPresent(OCRMode.self, forKey: .ocrMode) ?? defaults.ocrMode
    overlayEnabled = try container.decodeIfPresent(Bool.self, forKey: .overlayEnabled) ?? defaults.overlayEnabled
    overlayFrame = try container.decodeIfPresent(OverlayFrame.self, forKey: .overlayFrame) ?? defaults.overlayFrame
    overlayHideOnHover = try container.decodeIfPresent(Bool.self, forKey: .overlayHideOnHover) ?? defaults.overlayHideOnHover
    sourceLanguage = try container.decodeIfPresent(Language.self, forKey: .sourceLanguage) ?? defaults.sourceLanguage
    targetLanguage = try container.decodeIfPresent(Language.self, forKey: .targetLanguage) ?? defaults.targetLanguage
    translationStrategy = try container
      .decodeIfPresent(TranslationStrategy.self, forKey: .translationStrategy) ?? defaults.translationStrategy
  }

  // MARK: Internal

  var captureInterval = 0.8
  var ocrMode = OCRMode.text
  var overlayEnabled = true
  var overlayFrame = OverlayFrame.default
  var overlayHideOnHover = false
  var sourceLanguage = Language.auto
  var targetLanguage = Language.systemPreferred()
  var translationStrategy = TranslationStrategy.lowLatency

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
