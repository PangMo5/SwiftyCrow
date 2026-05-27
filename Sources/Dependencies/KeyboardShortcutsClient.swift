import ComposableArchitecture
import DependenciesMacros
import KeyboardShortcuts

// MARK: - KeyboardShortcutEvent

enum KeyboardShortcutEvent: Equatable {
  case captureOnce
  case toggleLive
  case toggleOverlay
}

// MARK: - KeyboardShortcutsClient

@DependencyClient
struct KeyboardShortcutsClient {
  var events: @Sendable () -> AsyncStream<KeyboardShortcutEvent> = { .finished }
}

// MARK: DependencyKey

extension KeyboardShortcutsClient: DependencyKey {
  static let liveValue = KeyboardShortcutsClient(
    events: {
      AsyncStream { continuation in
        let task = Task { @MainActor in
          KeyboardShortcuts.onKeyUp(for: .captureOnce) {
            continuation.yield(.captureOnce)
          }
          KeyboardShortcuts.onKeyUp(for: .toggleLive) {
            continuation.yield(.toggleLive)
          }
          KeyboardShortcuts.onKeyUp(for: .toggleOverlay) {
            continuation.yield(.toggleOverlay)
          }
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    }
  )
}

extension DependencyValues {
  var keyboardShortcuts: KeyboardShortcutsClient {
    get { self[KeyboardShortcutsClient.self] }
    set { self[KeyboardShortcutsClient.self] = newValue }
  }
}

extension KeyboardShortcuts.Name {
  static let captureOnce = Self("captureOnce")
  static let toggleLive = Self("toggleLive")
  static let toggleOverlay = Self("toggleOverlay")
}
