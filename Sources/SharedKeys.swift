import Foundation
import Sharing
import TOML

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
