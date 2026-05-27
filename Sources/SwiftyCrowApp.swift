import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

// MARK: - AppStore

@MainActor let appStore = Store(initialState: AppFeature.State()) {
  AppFeature()
}

// MARK: - SwiftyCrowApp

@main
struct SwiftyCrowApp: App {
  var body: some Scene {
    MenuBarExtra("SwiftyCrow", systemImage: "character.bubble.fill") {
      MenuBarContent(store: appStore)
    }
    .menuBarExtraStyle(.window)

    Settings {
      SettingsView()
    }
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

    // Run the keyboard-shortcut listener for the entire app lifetime.
    observationTasks.append(
      Task { @MainActor in
        await appStore.send(.task).finish()
      }
    )

    // Keep the overlay in sync with capture/translation state and settings
    // regardless of which scene (popover, Settings window) is currently shown.
    observationTasks.append(
      Task { @MainActor in
        for await _ in overlayStateStream() {
          await syncOverlay()
        }
      }
    )
    observationTasks.append(Task { @MainActor in await syncOverlay() })
  }

  func applicationWillTerminate(_: Notification) {
    for observationTask in observationTasks { observationTask.cancel() }
  }

  // MARK: Private

  @Dependency(\.overlay) private var overlay
  @Dependency(\.updater) private var updater

  private var observationTasks = [Task<Void, Never>]()

  private func overlayStateStream() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let task = Task { @MainActor in
        var last = snapshot()
        continuation.yield(())
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(100))
          let current = snapshot()
          if current != last {
            last = current
            continuation.yield(())
          }
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  private func snapshot() -> OverlayRenderState {
    let capture = appStore.capture
    let settings = appStore.settings
    return OverlayRenderState(
      lines: capture.overlayLines,
      isVisible: settings.overlayEnabled,
      hideOnHover: settings.overlayHideOnHover,
      isTranslating: capture.isTranslating,
      isLive: capture.isLive
    )
  }

  private func syncOverlay() async {
    await overlay.render(snapshot())
    let excluded = await overlay.windowID().map { [$0] } ?? []
    appStore.send(.capture(.setExcludedWindowIDs(excluded)))
  }
}
