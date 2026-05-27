import ComposableArchitecture
import DependenciesMacros
import KeyboardShortcuts

// MARK: - KeyboardShortcutEvent

enum KeyboardShortcutEvent: Equatable, CaseIterable {
  case captureOnce
  case toggleLive
  case toggleOverlay

  var name: KeyboardShortcuts.Name {
    switch self {
    case .captureOnce: .captureOnce
    case .toggleLive: .toggleLive
    case .toggleOverlay: .toggleOverlay
    }
  }
}

// MARK: - KeyboardShortcutsClient

@DependencyClient
struct KeyboardShortcutsClient {
  var events: @Sendable () -> AsyncStream<KeyboardShortcutEvent> = { .finished }
  /// Pushes a persisted hotkey (from config) into the underlying registrar.
  /// `nil` clears the shortcut.
  var setShortcut: @Sendable (_ event: KeyboardShortcutEvent, _ hotKey: HotKey?) -> Void
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
    },
    setShortcut: { event, hotKey in
      Task { @MainActor in
        KeyboardShortcuts.setShortcut(hotKey?.shortcut, for: event.name)
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
