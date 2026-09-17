// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import Foundation
#if os(macOS)
@preconcurrency import AVFoundation
import CoreGraphics
import CoreText
import ImageIO
#endif

// MARK: - VideoAudit

struct VideoAudit {
  let workspace: Workspace

  func audit(source: URL, output: URL) async throws {
    #if os(macOS)
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError("No video track") }
    let reader = try AVAssetReader(asset: asset)
    let stream = AVAssetReaderTrackOutput(
      track: track,
      outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    )
    stream.alwaysCopiesSampleData = false
    try require(reader.canAdd(stream), "Cannot decode video track")
    reader.add(stream)
    try require(reader.startReading(), "Video reader failed: \(String(describing: reader.error))")
    try output.makeDirectory()
    var frames = [JSON]()
    var seen = [String: Int]()
    var sheet = try ContactSheet()
    var sheetCount = 0
    var maxDark = -1
    var maxMagenta = -1
    var darkImage: CGImage?
    var magentaImage: CGImage?
    var darkFrame = JSON.null
    var magentaFrame = JSON.null
    var dimensions = JSON.null
    while let sample = stream.copyNextSampleBuffer() {
      guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw ToolError("Decoded frame has no image buffer") }
      let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
      try require(timestamp.isFinite, "Invalid video timestamp")
      let pixels = try DecodedPixels(buffer)
      let digest = sha(pixels.data)
      let index = frames.count
      let duplicate = seen[digest]
      seen[digest] = duplicate ?? index
      let metrics = pixels.metrics()
      let frame = JSON.object([
        ("frame", .integer(index)),
        ("pts", .decimal(timestamp)),
        ("sha256", .string(digest)),
        ("darkFullPixels", .integer(metrics.dark)),
        ("magentaFullPixels", .integer(metrics.magenta)),
        ("visuallyIdenticalToFrame", .integer(duplicate ?? index)),
      ])
      frames.append(frame)
      dimensions = .object([("width", .integer(pixels.width)), ("height", .integer(pixels.height))])
      if duplicate == nil {
        try sheet.append(
          pixels.image(),
          label: String(format: "f%d  %.3fs  dark=%d  magenta=%d", index, timestamp, metrics.dark, metrics.magenta)
        )
        if sheet.count == 16 {
          sheetCount += 1
          try sheet.write(output.at(String(format: "full-frame-contact-%03d.png", sheetCount)))
          sheet = try ContactSheet()
        }
      }
      if metrics.dark > maxDark {
        maxDark = metrics.dark
        darkFrame = frame
        darkImage = try pixels.image()
      }
      if metrics.magenta > maxMagenta {
        maxMagenta = metrics.magenta
        magentaFrame = frame
        magentaImage = try pixels.image()
      }
    }
    try require(reader.status == .completed, "Video decode failed: \(String(describing: reader.error))")
    try require(!frames.isEmpty, "Video has no decoded frames")
    guard let darkImage, let magentaImage else { throw ToolError("Missing review candidate frames") }
    try writePNG(darkImage, output.at("maximum-dark-full.png"))
    try writePNG(magentaImage, output.at("maximum-magenta-full.png"))
    if sheet.count > 0 {
      sheetCount += 1
      try sheet.write(output.at(String(format: "full-frame-contact-%03d.png", sheetCount)))
    }
    try JSON.array(frames).write(output.at("every-frame.json"))
    let summary = try JSON.object([
      ("cameraOriginal", .string(relativePath(source, from: workspace.root))),
      ("cameraSHA256", .string(sha(source))),
      ("decodedFrames", .integer(frames.count)),
      ("uniqueDecodedPixelFrames", .integer(seen.count)),
      ("dimensions", dimensions),
      ("contactSheets", .integer(sheetCount)),
      ("maximumDark", darkFrame),
      ("maximumMagenta", magentaFrame),
      ("pixelFormat", .string("BGRA8, with row padding removed before hashing")),
      (
        "visualReview",
        .string(
          "Pending. Inspect all full-frame contact sheets and original-resolution suspect frames. Metrics are not acceptance."
        )
      ),
    ])
    try summary.write(output.at("summary.json"))
    print(try summary.rendered())
    #else
    throw ToolError("Native video audit requires macOS")
    #endif
  }
}

#if os(macOS)
struct DecodedPixels {

  // MARK: Lifecycle

  init(_ buffer: CVPixelBuffer) throws {
    width = CVPixelBufferGetWidth(buffer)
    height = CVPixelBufferGetHeight(buffer)
    try require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess, "Cannot read frame pixels")
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw ToolError("Missing frame pixels") }
    let stride = CVPixelBufferGetBytesPerRow(buffer)
    var packed = Data(capacity: width * height * 4)
    for row in 0..<height { packed.append(base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self), count: width * 4) }
    data = packed
  }

  // MARK: Internal

  let width: Int
  let height: Int
  let data: Data

  func metrics() -> (dark: Int, magenta: Int) {
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var dark = 0
      var magenta = 0
      for index in stride(from: 0, to: bytes.count, by: 4) {
        let blue = bytes[index]
        let green = bytes[index + 1]
        let red = bytes[index + 2]
        if red < 12, green < 12, blue < 12 { dark += 1 }
        if red > 180, blue > 180, green < 90 { magenta += 1 }
      }
      return (dark, magenta)
    }
  }

  func image() throws -> CGImage {
    guard
      let provider = CGDataProvider(data: data as CFData), let image = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: [
          .byteOrder32Little,
          CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue),
        ],
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
      )
    else { throw ToolError("Cannot create decoded frame image") }
    return image
  }
}

private struct ContactSheet {

  // MARK: Lifecycle

  init() throws {
    guard
      let context = CGContext(
        data: nil,
        width: 1536,
        height: 1056,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw ToolError("Cannot create contact sheet") }
    context.setFillColor(CGColor(gray: 0.93, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1536, height: 1056))
    context.interpolationQuality = .high
    self.context = context
  }

  // MARK: Internal

  let context: CGContext
  var count = 0

  mutating func append(_ image: CGImage, label: String) throws {
    let x = (count % 4) * 384
    let y = 1056 - (count / 4 + 1) * 264
    let scale = min(384 / Double(image.width), 240 / Double(image.height))
    let width = Double(image.width) * scale
    let height = Double(image.height) * scale
    context.draw(
      image,
      in: CGRect(x: Double(x) + (384 - width) / 2, y: Double(y) + (240 - height) / 2, width: width, height: height)
    )
    let text = NSAttributedString(string: label, attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Menlo" as CFString, 9, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    context.textPosition = CGPoint(x: x + 4, y: y + 246)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    count += 1
  }

  func write(_ file: URL) throws {
    guard let image = context.makeImage() else { throw ToolError("Cannot finalize contact sheet") }
    try writePNG(image, file)
  }
}

private func writePNG(_ image: CGImage, _ file: URL) throws {
  guard let target = CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil)
  else { throw ToolError("Cannot write review image") }
  CGImageDestinationAddImage(target, image, nil)
  try require(CGImageDestinationFinalize(target), "Cannot finalize review image")
}
#endif
