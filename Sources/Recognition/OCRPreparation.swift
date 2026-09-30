// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import CoreText
import Foundation

/// Starts the same document recognizer once per application lifetime. A capture
/// that arrives during preparation joins that work instead of compiling a second
/// request concurrently. No screen pixels, translation assets or network are used.
actor OCRPreparation {

  // MARK: Lifecycle

  init(operation: @escaping @Sendable () async throws -> Void) {
    self.operation = operation
  }

  // MARK: Internal

  static let shared = OCRPreparation {
    guard let image = preparationImage() else { return }
    let start = ContinuousClock.now
    _ = try await VisionTextRecognizer.document(in: image, language: .auto)
    Log.ocr.log("Background document preparation completed in \(start.duration(to: .now).loggedSeconds, privacy: .public)s")
  }

  func start() {
    guard task == nil, !recognitionStarted else { return }
    task = Task(priority: .utility) {
      do { try await operation() }
      catch is CancellationError { }
      catch { Log.ocr.error("Background document preparation failed: \(error.localizedDescription, privacy: .public)") }
    }
  }

  func beginRecognition() async throws {
    recognitionStarted = true
    // Awaiting raises the utility task's priority for a foreground capture.
    if let task { await task.value }
    try Task.checkCancellation()
  }

  func cancel() {
    task?.cancel()
  }

  // MARK: Private

  private let operation: @Sendable () async throws -> Void
  private var task: Task<Void, Never>?
  private var recognitionStarted = false

  private static func preparationImage() -> CGImage? {
    guard
      let context = CGContext(
        data: nil,
        width: 480,
        height: 120,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 480, height: 120))
    let text = NSAttributedString(string: "Screen text", attributes: [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 28, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
    ])
    context.textPosition = CGPoint(x: 20, y: 50)
    CTLineDraw(CTLineCreateWithAttributedString(text), context)
    return context.makeImage()
  }
}
