import AppKit
import ComposableArchitecture
import SwiftUI

/// Scene id of the settings window, shared by every `openWindow(id:)` call site.
let settingsWindowID = "settings"

extension Notification.Name {
  /// Posted to ask the app to open the settings window from a context without a
  /// scene environment (e.g. the overlay's detached AppKit hosting view). The
  /// always-mounted menu-bar label observes it and calls `openWindow`.
  static let openSettingsWindow = Notification.Name("dev.PangMo5.SwiftyCrow.openSettingsWindow")
}

// MARK: - SwiftyCrowApp

@main
struct SwiftyCrowApp: App {

  // MARK: Internal

  var body: some Scene {
    // The App owns the store; the delegate handles menu-bar-app lifetime
    // (keyboard listener + overlay sync), so we hand the store to it here.
    let _ = appDelegate.bind(store)

    MenuBarExtra {
      MenuBarContent(store: store)
    } label: {
      // The label is always mounted (unlike the on-demand popover), so it's the
      // reliable place to receive "open settings" requests posted from detached
      // AppKit surfaces (e.g. the overlay's ⌘, affordance) and turn them into a
      // scene-level openWindow.
      MenuBarLabel()
    }
    .menuBarExtraStyle(.window)

    // A real Window scene (not the `Settings` scene) so open/close reliably
    // drives the view lifecycle — `.regularWhileOpen()` depends on onAppear/
    // onDisappear firing, which the `Settings` scene doesn't guarantee (its
    // content is cached/hidden on close). Mirrors the sibling Tatami/Amado apps.
    Window("SwiftyCrow Settings", id: settingsWindowID) {
      SettingsView(store: store.scope(state: \.settingsScreen, action: \.settingsScreen))
        .regularWhileOpen()
    }
    .windowResizability(.contentSize)
    .commands {
      // Restore the standard ⌘, / "Settings…" app-menu item (the `Settings`
      // scene used to provide it) now that a plain Window backs settings.
      CommandGroup(replacing: .appSettings) {
        OpenSettingsCommandButton()
      }
    }
  }

  // MARK: Private

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
      isVisible: store.capture.overlayActive,
      hideOnHover: store.settings.overlay.hideOnHover,
      // Drive the overlay spinner off "busy" (capture/OCR in flight OR
      // translating), not just the translation phase — otherwise it only
      // appears after OCR (feels late) and is skipped entirely when a capture
      // has nothing to translate or resolves instantly. isCapturing is the
      // initial capture and is cleared on both success and failure.
      isTranslating: store.capture.isTranslating || store.capture.isCapturing,
      isLive: store.capture.isLive,
      liveMode: store.settings.overlay.liveMode,
      backgroundImageData: store.capture.backgroundImageData,
      imageSize: store.capture.imageSize,
      placementID: store.capture.overlayPlacementID,
      translationUnavailable: store.capture.translationUnavailable
    )
  }

  private func syncOverlay(_ state: OverlayRenderState) async {
    await overlay.render(state)
    let excluded = await overlay.windowID().map { [$0] } ?? []
    store?.send(.capture(.setExcludedWindowIDs(excluded)))
  }
}

// MARK: - MenuBarLabel

/// The always-mounted menu-bar item. Besides drawing the icon, it hosts the
/// bridge that turns an `.openSettingsWindow` notification into a scene-level
/// `openWindow` (see `Notification.Name.openSettingsWindow`).
private struct MenuBarLabel: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(systemName: "character.bubble.fill")
      .accessibilityLabel("SwiftyCrow")
      .onReceive(NotificationCenter.default.publisher(for: .openSettingsWindow)) { _ in
        openWindow(id: settingsWindowID)
        NSApp.activate(ignoringOtherApps: true)
      }
  }
}

// MARK: - OpenSettingsCommandButton

/// Backs the ⌘, / "Settings…" app-menu item. A dedicated view so it can read
/// the `openWindow` environment action from inside `.commands`.
private struct OpenSettingsCommandButton: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button("Settings…") {
      openWindow(id: settingsWindowID)
      NSApp.activate(ignoringOtherApps: true)
    }
    .keyboardShortcut(",", modifiers: .command)
  }
}

// MARK: - Regular-while-open

extension View {
  /// Promote the `LSUIElement` menu-bar agent to a regular app (Dock icon,
  /// normal front-most focus, standard window chrome) while this window is
  /// open, dropping back to accessory once the last such window closes.
  fileprivate func regularWhileOpen() -> some View {
    onAppear { WindowActivation.opened() }
      .onDisappear { WindowActivation.closed() }
  }
}

// MARK: - WindowActivation

/// Reference-counts the windows that need a regular activation policy — the
/// Settings window and capture-result windows — so opening several at once and
/// closing one doesn't prematurely drop the whole app back to accessory
/// (menu-bar-only). The app is otherwise an `LSUIElement` agent with no Dock
/// icon; these are the only surfaces that promote it.
@MainActor
enum WindowActivation {

  // MARK: Internal

  static func opened() {
    openCount += 1
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  static func closed() {
    openCount = max(0, openCount - 1)
    if openCount == 0 {
      NSApp.setActivationPolicy(.accessory)
    }
  }

  // MARK: Private

  private static var openCount = 0
}
