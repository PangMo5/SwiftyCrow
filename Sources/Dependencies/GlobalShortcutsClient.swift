import ComposableArchitecture
import DependenciesMacros
import Magnet

// MARK: - ShortcutEvent

/// A global hotkey action. The raw value is the stable identifier Magnet uses
/// to register/unregister the underlying hotkey.
enum ShortcutEvent: String, Equatable, CaseIterable, Sendable {
  case selectRegion
  case liveOverlay
  case toggleLive
  case toggleLiveMode

  var identifier: String {
    rawValue
  }
}

// MARK: - GlobalShortcutsClient

@DependencyClient
struct GlobalShortcutsClient {
  /// Emits whenever a registered global hotkey fires.
  var events: @Sendable () -> AsyncStream<ShortcutEvent> = { .finished }
  /// Registers the global hotkey for an event, or clears it when `hotKey` is nil.
  var setShortcut: @Sendable (_ event: ShortcutEvent, _ hotKey: HotKey?) -> Void
  /// Temporarily suspends/resumes all global hotkeys — used while the shortcut
  /// recorder is capturing so a press doesn't trigger the action it's binding.
  var setEnabled: @Sendable (_ enabled: Bool) -> Void
}

// MARK: DependencyKey

extension GlobalShortcutsClient: DependencyKey {
  static let liveValue = GlobalShortcutsClient(
    events: {
      AsyncStream { continuation in
        let task = Task { @MainActor in
          GlobalHotKeyRegistrar.shared.setContinuation(continuation)
        }
        continuation.onTermination = { _ in task.cancel() }
      }
    },
    setShortcut: { event, hotKey in
      Task { @MainActor in
        GlobalHotKeyRegistrar.shared.setShortcut(event, hotKey)
      }
    },
    setEnabled: { enabled in
      Task { @MainActor in
        GlobalHotKeyRegistrar.shared.setEnabled(enabled)
      }
    }
  )
}

extension DependencyValues {
  var globalShortcuts: GlobalShortcutsClient {
    get { self[GlobalShortcutsClient.self] }
    set { self[GlobalShortcutsClient.self] = newValue }
  }
}

// MARK: - GlobalHotKeyRegistrar

/// Bridges Magnet's `HotKeyCenter` (a main-actor singleton) to the async event
/// stream: hotkeys are (re)registered as settings change, and each fires the
/// matching `ShortcutEvent` into the stream.
@MainActor
private final class GlobalHotKeyRegistrar {

  // MARK: Internal

  static let shared = GlobalHotKeyRegistrar()

  func setContinuation(_ continuation: AsyncStream<ShortcutEvent>.Continuation) {
    self.continuation = continuation
  }

  func setShortcut(_ event: ShortcutEvent, _ hotKey: HotKey?) {
    HotKeyCenter.shared.unregisterHotKey(with: event.identifier)
    hotKeys[event] = nil
    guard let keyCombo = hotKey?.keyCombo else { return }
    let magnetHotKey = Magnet.HotKey(identifier: event.identifier, keyCombo: keyCombo) { [weak self] _ in
      self?.continuation?.yield(event)
    }
    hotKeys[event] = magnetHotKey
    if enabled {
      HotKeyCenter.shared.register(with: magnetHotKey)
    }
  }

  func setEnabled(_ enabled: Bool) {
    guard enabled != self.enabled else { return }
    self.enabled = enabled
    if enabled {
      for value in hotKeys.values { HotKeyCenter.shared.register(with: value) }
    } else {
      for key in hotKeys.keys { HotKeyCenter.shared.unregisterHotKey(with: key.identifier) }
    }
  }

  // MARK: Private

  private var continuation: AsyncStream<ShortcutEvent>.Continuation?
  /// The currently configured hotkeys, kept so they can be re-registered after
  /// being suspended (registering takes a handler, so we can't rebuild blindly).
  private var hotKeys = [ShortcutEvent: Magnet.HotKey]()
  private var enabled = true
}
