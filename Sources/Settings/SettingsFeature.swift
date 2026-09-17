// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Sharing

// MARK: - SettingsFeature

/// Owns the Settings screen's side effects — loading the installed language
/// lists, reading/writing the login item, and the updater's availability —
/// so the views stay declarative.
@Reducer
struct SettingsFeature {

  @ObservableState
  struct State: Equatable {
    var pane = SettingsPane.general
    var sourceLanguages = [Language]()
    var targetLanguages = [Language]()
    var launchAtLogin = false
    var canCheckForUpdates = false
    var hasScreenRecording = false
    var isRequestingAccess = false
    var isRelaunching = false
    var relaunchError: String?

    @Shared(.settings) var settings
  }

  enum Action {
    case paneSelected(SettingsPane)
    case task
    case taskEnded
    case permissionLoaded(Bool)
    case grantScreenRecordingTapped
    case openScreenRecordingSettingsTapped
    case relaunchTapped
    case relaunchFailed(String)
    case accessRequestFinished(Bool)
    case launchAtLoginLoaded(Bool)
    case launchAtLoginChanged(Bool)
    case languagesLoaded(source: [Language], target: [Language])
    case canCheckForUpdatesChanged(Bool)
    case checkForUpdatesTapped
  }

  enum CancelID { case lifetime }

  @Dependency(\.languageCatalog) var languageCatalog
  @Dependency(\.loginItem) var loginItem
  @Dependency(\.updater) var updater
  @Dependency(\.screenRecordingAccess) var access
  @Dependency(\.appRelaunch) var relaunch

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .paneSelected(let pane):
        state.pane = pane
        return .none

      case .task:
        return .merge(
          .run { [access] send in
            for await _ in access.changes() { await send(.permissionLoaded(access.isGranted())) }
          },
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
        .cancellable(id: CancelID.lifetime, cancelInFlight: true)

      case .taskEnded:
        return .cancel(id: CancelID.lifetime)

      case .permissionLoaded(let granted):
        state.hasScreenRecording = granted
        return .none

      case .grantScreenRecordingTapped:
        guard !state.isRequestingAccess else { return .none }
        state.isRequestingAccess = true
        return .run { [access, relaunch] send in
          await relaunch.prepare()
          _ = await access.request()
          await access.openSettings()
          await send(.accessRequestFinished(access.isGranted()))
        }

      case .accessRequestFinished(let granted):
        state.isRequestingAccess = false
        state.hasScreenRecording = granted
        return .none

      case .openScreenRecordingSettingsTapped:
        return .run { [access, relaunch] _ in
          await relaunch.prepare()
          await access.openSettings()
        }

      case .relaunchTapped:
        guard !state.isRelaunching else { return .none }
        state.isRelaunching = true
        state.relaunchError = nil
        return .run { [relaunch] send in
          await relaunch.prepare()
          do { try await relaunch.relaunch() }
          catch { await send(.relaunchFailed(error.localizedDescription)) }
        }

      case .relaunchFailed(let message):
        state.isRelaunching = false
        state.relaunchError = message
        return .none

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
