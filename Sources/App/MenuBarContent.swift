import ComposableArchitecture
import SwiftUI

struct MenuBarContent: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      CaptureView(store: store.scope(state: \.capture, action: \.capture))

      Divider()

      HStack {
        Button("Settings…") {
          openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

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

  @Environment(\.openSettings) private var openSettings

}
