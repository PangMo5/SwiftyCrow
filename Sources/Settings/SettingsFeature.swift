import ComposableArchitecture
import Sharing

// MARK: - SettingsFeature

/// Owns the Settings screen's side effects — loading the installed language
/// lists, reading/writing the login item, and the updater's availability —
/// so the views stay declarative.
@Reducer
struct SettingsFeature {

  @ObservableState
  struct State {
    var sourceLanguages = [Language]()
    var targetLanguages = [Language]()
    var launchAtLogin = false
    var canCheckForUpdates = false

    @Shared(.settings) var settings
  }

  enum Action {
    case task
    case launchAtLoginLoaded(Bool)
    case launchAtLoginChanged(Bool)
    case languagesLoaded(source: [Language], target: [Language])
    case canCheckForUpdatesChanged(Bool)
    case checkForUpdatesTapped
  }

  @Dependency(\.languageCatalog) var languageCatalog
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.updater) var updater

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        return .merge(
          .run { [loginItem] send in
            await send(.launchAtLoginLoaded(loginItem.isEnabled()))
          },
          .run { [languageCatalog] send in
            // Lists are loaded from Apple Translation · Vision on this device.
            async let source = languageCatalog.supported(intersectedWithOCR: true)
            async let target = languageCatalog.supported(intersectedWithOCR: false)
            await send(.languagesLoaded(source: [.auto] + source, target: target))
          },
          .run { [updater] send in
            for await value in updater.canCheckForUpdates() {
              await send(.canCheckForUpdatesChanged(value))
            }
          }
        )

      case .launchAtLoginLoaded(let enabled):
        state.launchAtLogin = enabled
        return .none

      case .launchAtLoginChanged(let enabled):
        state.launchAtLogin = enabled
        return .run { [loginItem] _ in loginItem.setEnabled(enabled) }

      case .languagesLoaded(let source, let target):
        state.sourceLanguages = source
        state.targetLanguages = target
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
