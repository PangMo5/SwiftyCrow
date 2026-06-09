import ComposableArchitecture
import DependenciesMacros
import Sparkle

// MARK: - UpdaterClient

@DependencyClient
struct UpdaterClient {
  /// Emits whether the updater can currently start a check.
  var canCheckForUpdates: @Sendable () -> AsyncStream<Bool> = { .finished }
  /// Triggers a user-initiated update check.
  var checkForUpdates: @Sendable () -> Void
  /// Applies the scheduled-check preferences to the underlying updater.
  var configure: @Sendable (_ automaticallyChecks: Bool, _ interval: TimeInterval) -> Void
}

// MARK: DependencyKey

extension UpdaterClient: DependencyKey {
  static let liveValue: UpdaterClient = {
    let controller = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil
    )
    let updater = controller.updater
    return UpdaterClient(
      canCheckForUpdates: {
        // Sparkle doesn't reliably emit KVO change notifications for
        // canCheckForUpdates, so poll it and yield only on change.
        AsyncStream { continuation in
          let task = Task { @MainActor in
            var last: Bool?
            while !Task.isCancelled {
              let value = updater.canCheckForUpdates
              if value != last {
                last = value
                continuation.yield(value)
              }
              try? await Task.sleep(for: .seconds(1))
            }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      checkForUpdates: {
        Task { @MainActor in updater.checkForUpdates() }
      },
      configure: { automaticallyChecks, interval in
        Task { @MainActor in
          updater.automaticallyChecksForUpdates = automaticallyChecks
          updater.updateCheckInterval = interval
        }
      }
    )
  }()
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
