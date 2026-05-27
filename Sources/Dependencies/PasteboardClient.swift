import AppKit
import ComposableArchitecture
import DependenciesMacros

// MARK: - PasteboardClient

@DependencyClient
struct PasteboardClient {
  var copyImage: @Sendable (_ pngData: Data) async -> Void
  var copyString: @Sendable (_ text: String) async -> Void
}

extension PasteboardClient: DependencyKey {
  static var liveValue: PasteboardClient {
    PasteboardClient(
      copyImage: { data in
        await MainActor.run {
          guard let image = NSImage(data: data) else { return }
          NSPasteboard.general.clearContents()
          NSPasteboard.general.writeObjects([image])
        }
      },
      copyString: { text in
        await MainActor.run {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
      }
    )
  }
}

extension DependencyValues {
  var pasteboard: PasteboardClient {
    get { self[PasteboardClient.self] }
    set { self[PasteboardClient.self] = newValue }
  }
}
