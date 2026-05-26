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
    // Touch the singleton so it starts mirroring settings even before the
    // menu bar popover opens.
    _ = OverlayWindowController.shared

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
          syncOverlay()
        }
      }
    )
    syncOverlay()
  }

  func applicationWillTerminate(_: Notification) {
    for observationTask in observationTasks { observationTask.cancel() }
  }

  // MARK: Private

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

  private func snapshot() -> OverlaySnapshot {
    let capture = appStore.capture
    let settings = appStore.settings
    return OverlaySnapshot(
      lines: capture.overlayLines,
      isTranslating: capture.isTranslating,
      isLive: capture.isLive,
      overlayEnabled: settings.overlayEnabled,
      overlayHideOnHover: settings.overlayHideOnHover
    )
  }

  private func syncOverlay() {
    let snap = snapshot()
    OverlayWindowController.shared.update(
      lines: snap.lines,
      isVisible: snap.overlayEnabled,
      hideOnHover: snap.overlayHideOnHover,
      isTranslating: snap.isTranslating,
      isLive: snap.isLive
    )
    let excluded = OverlayWindowController.shared.windowID.map { [$0] } ?? []
    appStore.send(.capture(.setExcludedWindowIDs(excluded)))
  }
}

// MARK: - OverlaySnapshot

private struct OverlaySnapshot: Equatable {
  var lines: [CaptureFeature.OverlayLine]
  var isTranslating: Bool
  var isLive: Bool
  var overlayEnabled: Bool
  var overlayHideOnHover: Bool
}
