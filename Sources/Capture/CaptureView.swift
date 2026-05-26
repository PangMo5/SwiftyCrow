import ComposableArchitecture
import SwiftUI

struct CaptureView: View {

  // MARK: Internal

  let store: StoreOf<CaptureFeature>

  var body: some View {
    GlassEffectContainer(spacing: 12) {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 12) {
          Button("Capture Once") {
            store.send(.captureOnceRequested)
          }
          .buttonStyle(.glassProminent)
          .keyboardShortcut(.defaultAction)

          Toggle(
            "Live",
            isOn: Binding(
              get: { store.isLive },
              set: { store.send(.setLive($0)) }
            )
          )
          .toggleStyle(.switch)

          if store.isCapturing {
            ProgressView()
              .controlSize(.small)
          }

          Spacer()
        }

        if let error = store.lastError {
          HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(error)
            Spacer()
          }
          .foregroundStyle(.red)
          .padding(.horizontal, 12)
          .padding(.vertical, 8)
          .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        }

        HStack(spacing: 12) {
          textPanel(
            title: "Recognized",
            text: store.overlayLines.map(\.sourceText).joined(separator: "\n"),
            placeholder: "No text recognized yet."
          )
          textPanel(
            title: "Translated",
            text: store.overlayLines.compactMap { $0.translated }.joined(separator: "\n"),
            placeholder: "No translation yet."
          )
        }
      }
    }
  }

  // MARK: Private

  private func textPanel(title: String, text: String, placeholder: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title)
        .font(.headline)
      ScrollView {
        Text(text.isEmpty ? placeholder : text)
          .frame(maxWidth: .infinity, alignment: .leading)
          .textSelection(.enabled)
          .padding(12)
      }
      .frame(minHeight: 160)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 12))
    }
  }
}
