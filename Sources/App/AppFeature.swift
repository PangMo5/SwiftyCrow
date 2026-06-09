import ComposableArchitecture
import Sharing

@Reducer
struct AppFeature {
  @ObservableState
  struct State {
    var capture = CaptureFeature.State()

    @Shared(.settings) var settings
  }

  enum Action {
    case capture(CaptureFeature.Action)
    case task
    case toggleOverlayRequested
    case toggleLiveModeRequested
    case setLiveMode(OverlayLiveMode)
  }

  @Dependency(\.keyboardShortcuts) var keyboardShortcuts
  @Dependency(\.updater) var updater

  var body: some Reducer<State, Action> {
    Scope(state: \.capture, action: \.capture) {
      CaptureFeature()
    }
    Reduce { state, action in
      switch action {
      case .capture:
        return .none

      case .task:
        return .merge(
          .run { send in
            for await event in keyboardShortcuts.events() {
              switch event {
              case .selectRegion:
                await send(.capture(.selectRegionRequested))
              case .toggleLive:
                await send(.capture(.toggleLiveRequested))
              case .toggleOverlay:
                await send(.toggleOverlayRequested)
              case .toggleLiveMode:
                await send(.toggleLiveModeRequested)
              }
            }
          },
          .run { [updater, settings = state.$settings] _ in
            for await config in Observations({
              (settings.wrappedValue.updates.automaticChecks, settings.wrappedValue.updates.checkInterval)
            }) {
              updater.configure(automaticallyChecks: config.0, interval: config.1.seconds)
            }
          },
          .run { [settings = state.$settings] send in
            // Observations re-emits on any settings change (it doesn't dedupe),
            // so track the last value and react only when `enabled` actually
            // flips — otherwise toggling another overlay setting (e.g.
            // pass-through) would re-trigger the guide and clear results.
            var last: Bool?
            for await enabled in Observations({ settings.wrappedValue.overlay.enabled }) {
              defer { last = enabled }
              guard let previous = last, previous != enabled else { continue }
              await send(.capture(.overlayToggled(enabled)))
            }
          },
          .run { [keyboardShortcuts, settings = state.$settings] _ in
            // config.toml is the source of truth for hotkeys; push it into the
            // registrar on launch and whenever it changes (incl. hand edits).
            for await keys in Observations({
              (
                settings.wrappedValue.shortcuts.selectRegion,
                settings.wrappedValue.shortcuts.toggleLive,
                settings.wrappedValue.shortcuts.toggleOverlay,
                settings.wrappedValue.shortcuts.toggleLiveMode
              )
            }) {
              keyboardShortcuts.setShortcut(.selectRegion, keys.0)
              keyboardShortcuts.setShortcut(.toggleLive, keys.1)
              keyboardShortcuts.setShortcut(.toggleOverlay, keys.2)
              keyboardShortcuts.setShortcut(.toggleLiveMode, keys.3)
            }
          }
        )

      case .toggleOverlayRequested:
        state.$settings.withLock { $0.overlay.enabled.toggle() }
        if !state.settings.overlay.enabled, state.capture.isLive {
          return .send(.capture(.setLive(false)))
        }
        return .none

      case .toggleLiveModeRequested:
        state.$settings.withLock {
          $0.overlay.liveMode = $0.overlay.liveMode == .inPlace ? .window : .inPlace
        }
        return .none

      case .setLiveMode(let mode):
        state.$settings.withLock { $0.overlay.liveMode = mode }
        return .none
      }
    }
  }
}
