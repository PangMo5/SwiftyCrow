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
        AsyncStream { continuation in
          let task = Task { @MainActor in
            for await value in updater.publisher(for: \.canCheckForUpdates).values {
              continuation.yield(value)
            }
            continuation.finish()
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      },
      checkForUpdates: {
        Task { @MainActor in updater.checkForUpdates() }
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
