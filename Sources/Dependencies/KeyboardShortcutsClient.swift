import ComposableArchitecture
import DependenciesMacros
import KeyboardShortcuts

// MARK: - KeyboardShortcutEvent

enum KeyboardShortcutEvent: Equatable, CaseIterable {
  case selectRegion
  case toggleLive
  case toggleOverlay
  case togglePassThrough

  var name: KeyboardShortcuts.Name {
    switch self {
    case .selectRegion: .selectRegion
    case .toggleLive: .toggleLive
    case .toggleOverlay: .toggleOverlay
    case .togglePassThrough: .togglePassThrough
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
          KeyboardShortcuts.onKeyUp(for: .selectRegion) {
            continuation.yield(.selectRegion)
          }
          KeyboardShortcuts.onKeyUp(for: .toggleLive) {
            continuation.yield(.toggleLive)
          }
          KeyboardShortcuts.onKeyUp(for: .toggleOverlay) {
            continuation.yield(.toggleOverlay)
          }
          KeyboardShortcuts.onKeyUp(for: .togglePassThrough) {
            continuation.yield(.togglePassThrough)
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
  static let selectRegion = Self("selectRegion")
  static let toggleLive = Self("toggleLive")
  static let toggleOverlay = Self("toggleOverlay")
  static let togglePassThrough = Self("togglePassThrough")

  // Capture-result-window actions. These are matched locally by an NSEvent
  // monitor while the window is focused (never globally registered), so they
  // don't steal ⌘S etc. system-wide.
  static let regionSave = Self("regionSave", default: .init(.s, modifiers: .command))
  static let regionCopyImage = Self("regionCopyImage", default: .init(.c, modifiers: .command))
  static let regionCopyOriginal = Self("regionCopyOriginal", default: .init(.o, modifiers: .command))
  static let regionCopyTranslation = Self("regionCopyTranslation", default: .init(.t, modifiers: .command))
}
