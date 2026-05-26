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

  var body: some Reducer<State, Action> {
    Scope(state: \.capture, action: \.capture) {
      CaptureFeature()
    }
    Reduce { state, action in
      switch action {
      case .capture:
        return .none

      case .task:
        return .run { send in
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
        }

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
