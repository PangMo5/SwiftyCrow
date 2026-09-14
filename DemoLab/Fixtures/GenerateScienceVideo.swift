// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import AVFoundation

/// A real, silent source movie with burned-in English captions. This is separate
/// from the camera recorder: no SwiftyCrow output is generated here.
let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("science-light.mp4")
if FileManager.default.fileExists(atPath: output.path) { try FileManager.default.removeItem(at: output) }
let width = 1600
let height = 1000
let fps: Int32 = 24
let seconds = 24
let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
let input = AVAssetWriterInput(
  mediaType: .video,
  outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: width,
    AVVideoHeightKey: height,
    AVVideoCompressionPropertiesKey: [
      AVVideoAverageBitRateKey: 5_000_000,
      AVVideoExpectedSourceFrameRateKey: fps,
      AVVideoMaxKeyFrameIntervalKey: 48,
    ],
  ]
)
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
  assetWriterInput: input,
  sourcePixelBufferAttributes: [
    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
    kCVPixelBufferWidthKey as String: width,
    kCVPixelBufferHeightKey as String: height,
    kCVPixelBufferCGImageCompatibilityKey as String: true,
    kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
  ]
)
writer.add(input)
precondition(writer.startWriting())
writer.startSession(atSourceTime: .zero)
func ink(_ hex: UInt32) -> NSColor {
  NSColor(
    red: CGFloat(hex >> 16 & 255) / 255,
    green: CGFloat(hex >> 8 & 255) / 255,
    blue: CGFloat(hex & 255) / 255,
    alpha: 1
  )
}

func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32, _ r: CGFloat = 0) {
  ink(hex).setFill()
  NSBezierPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r).fill()
}

func ellipse(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ hex: UInt32) {
  ink(hex).setFill()
  NSBezierPath(ovalIn: CGRect(x: x, y: y, width: w, height: h)).fill()
}

func text(
  _ value: String,
  _ x: CGFloat,
  _ y: CGFloat,
  _ w: CGFloat,
  _ h: CGFloat,
  _ size: CGFloat,
  _ hex: UInt32,
  bold: Bool = false
) {
  let p = NSMutableParagraphStyle()
  p.lineSpacing = 10
  (value as NSString).draw(
    in: CGRect(x: x, y: y, width: w, height: h),
    withAttributes: [.font: NSFont.systemFont(
      ofSize: size,
      weight: bold
        ? .bold
        : .regular
    ), .foregroundColor: ink(hex), .paragraphStyle: p]
  )
}

let captions = [
  "A shadow forms when an object blocks the light.",
  "Move the light to change the shadow's direction.",
  "Bring the light closer to make the shadow larger.",
]
for n in 0..<(seconds * Int(fps)) {
  while !input.isReadyForMoreMediaData { precondition(writer.status == .writing, "Video encoder failed")
    usleep(1000)
  }
  autoreleasepool {
    var candidate: CVPixelBuffer?
    precondition(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &candidate) == kCVReturnSuccess)
    let buffer = candidate!
    CVPixelBufferLockBaseAddress(buffer, [])
    let context = CGContext(
      data: CVPixelBufferGetBaseAddress(buffer),
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    let time = Double(n) / Double(fps)
    let stage = min(2, Int(time / 8))
    let phase = CGFloat((time.truncatingRemainder(dividingBy: 8)) / 8)
    box(0, 0, 1600, 1000, 0x10233C)
    text("FIELD NOTES", 70, 45, 1000, 70, 28, 0x8FAED4, bold: true)
    text("Light & shadow", 65, 122, 1420, 110, 76, 0xF5F1E7, bold: true)
    text(
      ["01  BLOCK THE LIGHT", "02  MOVE THE LIGHT", "03  CHANGE THE DISTANCE"][stage],
      75,
      278,
      1300,
      65,
      31,
      0xF0BF6B,
      bold: true
    )
    // The diagram actually moves throughout each caption, not just between cards.
    let lightX: CGFloat = stage == 2 ? 270 + 245 * phase : 270 + 45 * sin(time * 0.6)
    // Keep the entire moving light below the stage heading and above the ground.
    let lightY: CGFloat = stage == 1 ? 520 + 100 * sin(phase * .pi * 2) : 445
    let shadowWidth: CGFloat = stage == 2 ? 310 + 260 * phase : 345
    box(70, 691, 1460, 5, 0x5A7090)
    let beam = NSBezierPath()
    beam.move(to: CGPoint(x: lightX, y: lightY))
    beam.line(to: CGPoint(x: 1390, y: 360))
    beam.line(to: CGPoint(x: 1470, y: 690))
    beam.close()
    ink(0x273B4A).setFill()
    beam.fill()
    ellipse(790 + (lightY - 445) * 0.45, 659, shadowWidth, 44, 0x081423)
    ellipse(700, 497, 190, 190, 0x75A7BE)
    ellipse(711, 509, 125, 125, 0x9BC6CD)
    ellipse(lightX - 58, lightY - 58, 116, 116, 0xEFB95D)
    ellipse(lightX - 38, lightY - 38, 76, 76, 0xFFDE91)
    text("LIGHT", 180, 727, 280, 55, 26, 0xE7BB71, bold: true)
    text("OBJECT", 715, 727, 250, 55, 26, 0xA2CBD8, bold: true)
    text("SHADOW", 1120, 727, 280, 55, 26, 0x8FAED4, bold: true)
    box(58, 824, 1484, 132, 0x07131F, 18)
    text(captions[stage], 90, 859, 1415, 80, 43, 0xFFFFFF)
    box(70, 985, 1460 * CGFloat(time / 24), 4, 0xD7BA76)
    NSGraphicsContext.restoreGraphicsState()
    CVPixelBufferUnlockBaseAddress(buffer, [])
    precondition(
      adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(n), timescale: fps)),
      "Could not encode source frame"
    )
  }
}

input.markAsFinished()
writer.endSession(atSourceTime: CMTime(value: Int64(seconds), timescale: 1))
let finished = DispatchSemaphore(value: 0)
writer.finishWriting { finished.signal() }
finished.wait()
guard writer.status == .completed else { throw writer.error! }
print("Wrote original source movie: \(output.path)")
