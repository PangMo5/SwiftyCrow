import ComposableArchitecture
import SwiftUI

struct MenuBarContent: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      CaptureView(store: store.scope(state: \.capture, action: \.capture))
      overlaySection
      footer
    }
    .padding(16)
    .frame(width: 300)
  }

  // MARK: Private

  @Environment(\.openSettings) private var openSettings

  private var header: some View {
    HStack(spacing: 7) {
      Image(systemName: "character.bubble.fill")
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(.tint)
      Text("SwiftyCrow")
        .font(.headline)
      Spacer()
    }
  }

  private var overlaySection: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("OVERLAY")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.leading, 4)

      VStack(spacing: 0) {
        Button {
          store.send(.capture(.liveSelectRequested))
        } label: {
          Label(
            store.capture.overlayActive ? "Move live overlay…" : "Live overlay…",
            systemImage: "viewfinder.rectangular"
          )
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, 8)

        Divider().padding(.leading, 28)

        Toggle(isOn: Binding(
          get: { store.capture.isLive },
          set: { store.send(.capture(.setLive($0))) }
        )) {
          Label("Live translation", systemImage: "dot.radiowaves.left.and.right")
        }
        .disabled(!store.capture.overlayActive)
        .toggleStyle(.switch)
        .controlSize(.small)
        .padding(.vertical, 8)

        Divider().padding(.leading, 28)

        HStack {
          Label("Display", systemImage: "rectangle.on.rectangle.angled")
          Spacer()
          Picker("", selection: Binding(
            get: { store.settings.overlay.liveMode },
            set: { mode in store.send(.setLiveMode(mode)) }
          )) {
            ForEach(OverlayLiveMode.allCases) { mode in
              Text(mode.displayName).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .fixedSize()
        }
        .controlSize(.small)
        .disabled(!store.capture.overlayActive)
        .padding(.vertical, 8)
      }
      .padding(.horizontal, 12)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
  }

  private var footer: some View {
    HStack(spacing: 14) {
      Button {
        openSettings()
      } label: {
        Label("Settings", systemImage: "gearshape")
      }
      .keyboardShortcut(",", modifiers: .command)

      Button {
        store.send(.checkForUpdatesTapped)
      } label: {
        Label("Updates", systemImage: "arrow.triangle.2.circlepath")
      }
      .help("Check for Updates")
      .disabled(!store.canCheckForUpdates)

      Spacer()

      Button {
        NSApplication.shared.terminate(nil)
      } label: {
        Image(systemName: "power")
      }
      .help("Quit SwiftyCrow")
      .keyboardShortcut("q", modifiers: .command)
    }
    .buttonStyle(.plain)
    .font(.callout)
    .foregroundStyle(.secondary)
  }
}
