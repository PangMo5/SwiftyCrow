import ComposableArchitecture
import Sparkle

// MARK: - UpdaterClient

struct UpdaterClient {
  /// Emits whether the updater can currently start a check.
  var canCheckForUpdates: @Sendable () -> AsyncStream<Bool>
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
          continuation.yield(updater.canCheckForUpdates)
          let cancellable = updater.publisher(for: \.canCheckForUpdates)
            .sink { continuation.yield($0) }
          continuation.onTermination = { _ in cancellable.cancel() }
        }
      },
      checkForUpdates: { updater.checkForUpdates() }
    )
  }()

  static let testValue = UpdaterClient(
    canCheckForUpdates: { AsyncStream { $0.yield(false)
      $0.finish()
    } },
    checkForUpdates: { }
  )
}

extension DependencyValues {
  var updater: UpdaterClient {
    get { self[UpdaterClient.self] }
    set { self[UpdaterClient.self] = newValue }
  }
}
