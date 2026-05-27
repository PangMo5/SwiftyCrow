import ComposableArchitecture
import SwiftUI

struct MenuBarContent: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CaptureView(store: store.scope(state: \.capture, action: \.capture))

      Toggle("Enable Overlay", isOn: Binding(
        get: { store.settings.overlayEnabled },
        set: { _ in store.send(.toggleOverlayRequested) }
      ))
      .toggleStyle(.switch)
      .controlSize(.small)

      Divider()

      HStack {
        Button("Settings…") {
          openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Button("Check for Updates…") {
          updater.checkForUpdates()
        }
        .disabled(!canCheckForUpdates)
        .task {
          for await value in updater.canCheckForUpdates() {
            canCheckForUpdates = value
          }
        }

        Spacer()

        Button("Quit") {
          NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
      }
      .controlSize(.small)
    }
    .padding(16)
    .frame(width: 520)
  }

  // MARK: Private

  @State private var canCheckForUpdates = false

  @Environment(\.openSettings) private var openSettings

  @Dependency(\.updater) private var updater

}
