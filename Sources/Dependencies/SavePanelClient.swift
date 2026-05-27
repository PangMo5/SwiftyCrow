import AppKit
import ComposableArchitecture
import DependenciesMacros
import UniformTypeIdentifiers

// MARK: - SavePanelClient

@DependencyClient
struct SavePanelClient {
  /// Presents a PNG save panel and writes `pngData`. Returns whether the user
  /// confirmed (so callers can decide whether to dismiss).
  var savePNG: @Sendable (_ pngData: Data, _ suggestedName: String) async -> Bool = { _, _ in false }
}

extension SavePanelClient: DependencyKey {
  static var liveValue: SavePanelClient {
    SavePanelClient(
      savePNG: { data, suggestedName in
        await MainActor.run {
          let panel = NSSavePanel()
          panel.allowedContentTypes = [.png]
          panel.nameFieldStringValue = suggestedName
          guard panel.runModal() == .OK, let url = panel.url else { return false }
          try? data.write(to: url)
          return true
        }
      }
    )
  }
}

extension DependencyValues {
  var savePanel: SavePanelClient {
    get { self[SavePanelClient.self] }
    set { self[SavePanelClient.self] = newValue }
  }
}
