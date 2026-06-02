import ComposableArchitecture
import DependenciesMacros
import NaturalLanguage

// MARK: - LanguageDetectionClient

/// Detects the dominant language of recognized text, so an "Auto" source can
/// resolve to a concrete language for translation.
@DependencyClient
struct LanguageDetectionClient {
  /// The dominant language of `text`, or nil if undetermined or below
  /// `minConfidence` (0...1). Short strings detect poorly, so per-line callers
  /// pass a threshold and fall back to a whole-capture detection.
  var detect: @Sendable (_ text: String, _ minConfidence: Double) -> Language? = { _, _ in nil }
}

extension LanguageDetectionClient: DependencyKey {
  static let liveValue = LanguageDetectionClient(
    detect: { text, minConfidence in
      let recognizer = NLLanguageRecognizer()
      recognizer.processString(text)
      guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
      if minConfidence > 0 {
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        guard confidence >= minConfidence else { return nil }
      }
      return Language(code: language.rawValue)
    }
  )
}

extension LanguageDetectionClient {
  /// Per-text source language for an Auto capture: detect each line (with a
  /// confidence threshold) and fall back to the whole-capture dominant language
  /// for short or ambiguous lines. For an explicit source, returns it for all.
  func resolveSources(for texts: [String], configured: Language) -> [Language] {
    guard configured.isAuto else { return Array(repeating: configured, count: texts.count) }
    let fallback = detect(texts.joined(separator: "\n"), 0) ?? .defaultSource
    return texts.map { detect($0, 0.65) ?? fallback }
  }
}

extension DependencyValues {
  var languageDetection: LanguageDetectionClient {
    get { self[LanguageDetectionClient.self] }
    set { self[LanguageDetectionClient.self] = newValue }
  }
}
