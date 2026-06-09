import ComposableArchitecture
import SwiftUI

struct CaptureView: View {

  // MARK: Internal

  let store: StoreOf<CaptureFeature>

  var body: some View {
    VStack(spacing: 8) {
      Button {
        store.send(.selectRegionRequested)
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "viewfinder")
          Text("Capture Region")
        }
        .font(.body.weight(.medium))
        .frame(maxWidth: .infinity)
      }
      .buttonStyle(.glassProminent)
      .controlSize(.large)
      .keyboardShortcut(.defaultAction)

      if let error = store.lastError {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .transition(.opacity)
      }
    }
    .animation(.easeOut(duration: 0.15), value: store.lastError)
  }
}
