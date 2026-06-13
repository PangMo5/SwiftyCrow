import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation

// MARK: - OverlayRenderState

struct OverlayRenderState: Equatable, Sendable {
  var lines: [OverlayLine]
  var isVisible: Bool
  var hideOnHover: Bool
  var isTranslating: Bool
  var isLive: Bool
  /// In-place draws chips on the overlay; window draws a thin region frame and
  /// shows the translation in a detached result window.
  var liveMode: OverlayLiveMode
  /// Blurred screenshot backdrop for the detached window (window mode only).
  var backgroundImageData: Data?
  var imageSize: CGSize
  /// Bumped whenever the overlay is (re)placed onto a new selection, so the
  /// controller snaps the window to the stored frame even if it's already shown.
  var placementID: Int
}

// MARK: - OverlayUserAction

/// Actions the user triggers from controls drawn on the overlay itself, routed
/// back to the store (the overlay is otherwise driven one-way by render state).
enum OverlayUserAction: Sendable {
  case toggleLive
  case close
}

// MARK: - OverlayClient

@DependencyClient
struct OverlayClient {
  var render: @Sendable (_ state: OverlayRenderState) async -> Void
  var windowID: @Sendable () async -> CGWindowID?
  var events: @Sendable () -> AsyncStream<OverlayUserAction> = { .finished }
}

// MARK: DependencyKey

extension OverlayClient: DependencyKey {
  static let liveValue: OverlayClient = {
    // The controller touches AppKit, so it can only be built on the main
    // actor. Create it lazily the first time the client is used there.
    nonisolated(unsafe) var controller: OverlayWindowController?
    @MainActor
    func resolve() -> OverlayWindowController {
      if let controller { return controller }
      let new = OverlayWindowController()
      controller = new
      return new
    }
    return OverlayClient(
      render: { state in
        await resolve().update(state)
      },
      windowID: { await resolve().windowID },
      events: {
        AsyncStream { continuation in
          let task = Task { @MainActor in
            resolve().setEventHandler { action in continuation.yield(action) }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      }
    )
  }()
}

extension DependencyValues {
  var overlay: OverlayClient {
    get { self[OverlayClient.self] }
    set { self[OverlayClient.self] = newValue }
  }
}
