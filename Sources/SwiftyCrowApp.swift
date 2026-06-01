import AppKit
import ComposableArchitecture
import SwiftUI

// MARK: - SwiftyCrowApp

@main
struct SwiftyCrowApp: App {
  var body: some Scene {
    // The App owns the store; the delegate handles menu-bar-app lifetime
    // (keyboard listener + overlay sync), so we hand the store to it here.
    let _ = appDelegate.bind(store)

    MenuBarExtra("SwiftyCrow", systemImage: "character.bubble.fill") {
      MenuBarContent(store: store)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
    }
  }

  @State private var store = Store(initialState: AppFeature.State()) {
    AppFeature()
  }

  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

}

// MARK: - AppDelegate

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

  // MARK: Internal

  func applicationDidFinishLaunching(_: Notification) {
    // Start Sparkle's background check schedule by reading the dependency.
    _ = updater
  }

  func applicationWillTerminate(_: Notification) {
    lifetimeTask?.cancel()
    overlayObservation = nil
  }

  /// Receives the App-owned store once and wires up app-lifetime work.
  func bind(_ store: StoreOf<AppFeature>) {
    guard self.store == nil else { return }
    self.store = store

    // Run the keyboard-shortcut listener for the entire app lifetime.
    lifetimeTask = Task { @MainActor in
      await store.send(.task).finish()
    }

    // Drive the overlay from capture/translation state + settings. `observe`
    // re-runs whenever anything the snapshot reads changes — no polling.
    overlayObservation = observe { [weak self] in
      guard let self, let state = overlaySnapshot() else { return }
      Task { @MainActor [weak self] in await self?.syncOverlay(state) }
    }
  }

  // MARK: Private

  @Dependency(\.overlay) private var overlay
  @Dependency(\.updater) private var updater

  private var store: StoreOf<AppFeature>?
  private var lifetimeTask: Task<Void, Never>?
  private var overlayObservation: ObserveToken?

  private func overlaySnapshot() -> OverlayRenderState? {
    guard let store else { return nil }
    return OverlayRenderState(
      lines: store.capture.overlayLines,
      isVisible: store.settings.overlay.enabled,
      hideOnHover: store.settings.overlay.hideOnHover,
      passThrough: store.settings.overlay.passThrough,
      isTranslating: store.capture.isTranslating,
      isLive: store.capture.isLive,
      showGuide: store.capture.showGuide
    )
  }

  private func syncOverlay(_ state: OverlayRenderState) async {
    await overlay.render(state)
    let excluded = await overlay.windowID().map { [$0] } ?? []
    store?.send(.capture(.setExcludedWindowIDs(excluded)))
  }
}
