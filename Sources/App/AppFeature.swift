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
  }

  @Dependency(KeyboardShortcutsClient.self) var keyboardShortcuts
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
              }
            }
          },
          .run { [updater] _ in
            @Shared(.settings) var settings
            for await config in Observations({
              (settings.updates.automaticChecks, settings.updates.checkInterval)
            }) {
              updater.configure(automaticallyChecks: config.0, interval: config.1.seconds)
            }
          },
          .run { send in
            @Shared(.settings) var settings
            var isFirst = true
            for await _ in Observations({ settings.overlay.enabled }) {
              // Skip the initial emission; only clear on actual toggles so a
              // stale capture doesn't linger when the overlay is switched.
              if isFirst {
                isFirst = false
                continue
              }
              await send(.capture(.clearResults))
            }
          },
          .run { [keyboardShortcuts] _ in
            @Shared(.settings) var settings
            // config.toml is the source of truth for hotkeys; push it into the
            // registrar on launch and whenever it changes (incl. hand edits).
            for await keys in Observations({
              (
                settings.shortcuts.selectRegion,
                settings.shortcuts.toggleLive,
                settings.shortcuts.toggleOverlay
              )
            }) {
              keyboardShortcuts.setShortcut(.selectRegion, keys.0)
              keyboardShortcuts.setShortcut(.toggleLive, keys.1)
              keyboardShortcuts.setShortcut(.toggleOverlay, keys.2)
            }
          }
        )

      case .toggleOverlayRequested:
        state.$settings.withLock { $0.overlay.enabled.toggle() }
        if !state.settings.overlay.enabled, state.capture.isLive {
          return .send(.capture(.setLive(false)))
        }
        return .none
      }
    }
  }
}
