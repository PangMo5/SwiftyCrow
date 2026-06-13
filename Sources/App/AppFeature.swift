import ComposableArchitecture
import Sharing

@Reducer
struct AppFeature {
  @ObservableState
  struct State {
    var capture = CaptureFeature.State()
    var settingsScreen = SettingsFeature.State()
    var canCheckForUpdates = false

    @Shared(.settings) var settings
  }

  enum Action {
    case capture(CaptureFeature.Action)
    case settingsScreen(SettingsFeature.Action)
    case task
    case liveOverlayRequested
    case toggleLiveModeRequested
    case setLiveMode(OverlayLiveMode)
    case canCheckForUpdatesChanged(Bool)
    case checkForUpdatesTapped
  }

  @Dependency(\.globalShortcuts) var globalShortcuts
  @Dependency(\.overlay) var overlay
  @Dependency(\.updater) var updater

  var body: some Reducer<State, Action> {
    Scope(state: \.capture, action: \.capture) {
      CaptureFeature()
    }
    Scope(state: \.settingsScreen, action: \.settingsScreen) {
      SettingsFeature()
    }
    Reduce { state, action in
      switch action {
      case .capture:
        return .none

      case .settingsScreen:
        return .none

      case .task:
        return .merge(
          .run { send in
            for await event in globalShortcuts.events() {
              switch event {
              case .selectRegion:
                await send(.capture(.selectRegionRequested))
              case .toggleLive:
                await send(.capture(.toggleLiveRequested))
              case .liveOverlay:
                await send(.liveOverlayRequested)
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
          .run { [overlay] send in
            // Controls drawn on the overlay (LIVE toggle, close) route back here.
            for await action in overlay.events() {
              switch action {
              case .toggleLive:
                await send(.capture(.toggleLiveRequested))
              case .close:
                await send(.capture(.dismissOverlay))
              }
            }
          },
          .run { [globalShortcuts, settings = state.$settings] _ in
            // config.toml is the source of truth for hotkeys; push it into the
            // registrar on launch and whenever it changes (incl. hand edits).
            for await keys in Observations({
              (
                settings.wrappedValue.shortcuts.selectRegion,
                settings.wrappedValue.shortcuts.toggleLive,
                settings.wrappedValue.shortcuts.liveOverlay,
                settings.wrappedValue.shortcuts.toggleLiveMode
              )
            }) {
              globalShortcuts.setShortcut(.selectRegion, keys.0)
              globalShortcuts.setShortcut(.toggleLive, keys.1)
              globalShortcuts.setShortcut(.liveOverlay, keys.2)
              globalShortcuts.setShortcut(.toggleLiveMode, keys.3)
            }
          },
          .run { [updater] send in
            for await value in updater.canCheckForUpdates() {
              await send(.canCheckForUpdatesChanged(value))
            }
          }
        )

      case .liveOverlayRequested:
        // The overlay is placed by selecting a region/window; this just starts
        // that selection (closing is handled by the overlay's own × button).
        return .send(.capture(.liveSelectRequested))

      case .toggleLiveModeRequested:
        state.$settings.withLock {
          $0.overlay.liveMode = $0.overlay.liveMode == .inPlace ? .window : .inPlace
        }
        return .none

      case .setLiveMode(let mode):
        state.$settings.withLock { $0.overlay.liveMode = mode }
        return .none

      case .canCheckForUpdatesChanged(let value):
        state.canCheckForUpdates = value
        return .none

      case .checkForUpdatesTapped:
        return .run { [updater] _ in updater.checkForUpdates() }
      }
    }
  }
}
