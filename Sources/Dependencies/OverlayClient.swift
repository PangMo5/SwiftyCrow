import ComposableArchitecture
import CoreGraphics
import DependenciesMacros

// MARK: - OverlayRenderState

struct OverlayRenderState: Equatable, Sendable {
  var lines: [OverlayLine]
  var isVisible: Bool
  var hideOnHover: Bool
  var passThrough: Bool
  var isTranslating: Bool
  var isLive: Bool
  var showGuide: Bool
}

// MARK: - OverlayClient

@DependencyClient
struct OverlayClient {
  var render: @Sendable (_ state: OverlayRenderState) async -> Void
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
          passThrough: state.passThrough,
          isTranslating: state.isTranslating,
          isLive: state.isLive,
          showGuide: state.showGuide
        )
      },
      windowID: { await resolve().windowID }
    )
  }()
}

extension DependencyValues {
  var overlay: OverlayClient {
    get { self[OverlayClient.self] }
    set { self[OverlayClient.self] = newValue }
  }
}
