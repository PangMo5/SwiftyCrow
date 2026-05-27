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
              case .captureOnce:
                await send(.capture(.captureOnceRequested))
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
              (settings.automaticallyChecksForUpdates, settings.updateCheckInterval)
            }) {
              updater.configure(automaticallyChecks: config.0, interval: config.1.seconds)
            }
          }
        )

      case .toggleOverlayRequested:
        state.$settings.withLock { $0.overlayEnabled.toggle() }
        if !state.settings.overlayEnabled, state.capture.isLive {
          return .send(.capture(.setLive(false)))
        }
        return .none
      }
    }
  }
}
