import ComposableArchitecture
import CoreGraphics

// MARK: - OverlayRenderState

struct OverlayRenderState: Equatable, Sendable {
  var lines: [CaptureFeature.OverlayLine]
  var isVisible: Bool
  var hideOnHover: Bool
  var isTranslating: Bool
  var isLive: Bool
}

// MARK: - OverlayClient

struct OverlayClient {
  var render: @Sendable (OverlayRenderState) async -> Void
  var windowID: @Sendable () async -> CGWindowID?
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
        await resolve().update(
          lines: state.lines,
          isVisible: state.isVisible,
          hideOnHover: state.hideOnHover,
          isTranslating: state.isTranslating,
          isLive: state.isLive
        )
      },
      windowID: { await resolve().windowID }
    )
  }()

  static let testValue = OverlayClient(
    render: { _ in },
    windowID: { nil }
  )
}

extension DependencyValues {
  var overlay: OverlayClient {
    get { self[OverlayClient.self] }
    set { self[OverlayClient.self] = newValue }
  }
}
