import Foundation
import Sharing
import TOML

extension SharedKey where Self == FileStorageKey<OverlayFrame>.Default {
  // Window geometry is UI state, not user config — store it as JSON under
  // Application Support instead of the hand-editable config.toml.
  static var overlayFrame: Self {
    let url = URL.applicationSupportDirectory
      .appending(path: "SwiftyCrow", directoryHint: .isDirectory)
      .appending(path: "overlay-frame.json")
    try? FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    return Self[.fileStorage(url), default: .default]
  }
}

extension SharedKey where Self == FileStorageKey<AppSettings>.Default {
  static var settings: Self {
    let url = ConfigPath.url
    try? FileManager.default.createDirectory(at: ConfigPath.directory, withIntermediateDirectories: true)
    return Self[
      .fileStorage(
        url,
        decode: { data in
          guard let string = String(data: data, encoding: .utf8) else {
            throw DecodingError.dataCorrupted(
              .init(codingPath: [], debugDescription: "config.toml is not valid UTF-8")
            )
          }
          return try TOMLDecoder().decode(AppSettings.self, from: string)
        },
        encode: { value in
          try TOMLEncoder().encode(value)
        }
      ),
      default: AppSettings()
    ]
  }
}
