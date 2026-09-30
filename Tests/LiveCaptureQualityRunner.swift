// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import SwiftyCrow

/// Native OCR + translation + live reducer across sequential screen changes.
/// The screen capture transport/window compositor itself is not driven here.
enum LiveCaptureQualityRunner {
  @MainActor
  static func run(root: URL, sourceLanguage: String? = nil) async throws -> Int {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var records = [[String: Any]]()
    let codes = CaptureQualityLanguage.all.map(\.code).filter { $0 != "he" }
    if let sourceLanguage, !codes.contains(sourceLanguage) { throw CocoaError(.validationMissingMandatoryProperty) }
    for copy in CaptureQualityLanguage.all
      where codes.contains(copy.code) && (sourceLanguage == nil || sourceLanguage == copy.code)
    {
      var state = withDependencies { $0.defaultFileStorage = .inMemory } operation: { CaptureFeature.State() }
      state.isLive = true
      state.overlayActive = true
      state.$settings.withLock {
        $0.languages.source = Language(code: Language.autoCode)
        $0.languages.target = Language(code: copy.code == "ko" ? "en" : "ko")
        $0.translation.strategy = .lowLatency
        $0.overlay.liveMode = .inPlace
      }
      let store = Store(initialState: state) { CaptureFeature() } withDependencies: {
        $0.ocr = .liveValue
        $0.translation = .liveValue
        $0.languageDetection = .liveValue
      }
      var firstHeadingFont: CGFloat?
      for step in 0..<9 {
        let image = try scene(copy, step: step)
        let started = ContinuousClock.now
        let frame = try LiveFrame(image: image)
        let hashed = ContinuousClock.now
        let before = store.state.recognitionGeneration
        await store.send(.liveFrameResponse(
          generation: store.state.captureGeneration,
          frame: store.state.overlayFrame,
          result: .success(frame)
        )).finish()
        let completed = ContinuousClock.now
        let lines = store.state.overlayLines
        let placements = OverlayLayoutEngine.placements(for: lines, in: frame.imageSize)
        var issues = CaptureQualityMetrics.paragraphIssues(
          texts: lines.map(\.source.text),
          expected: step == 7
            ? []
            : [step == 3 ? copy.note : copy.body]
        ) + CaptureQualityMetrics.layoutIssues(
          placements,
          canvas: frame.imageSize,
          minimumFontRatio: 0.4
        )
        if let error = store.state.lastError { issues.append(error) }
        if step == 1, store.state.recognitionGeneration != before { issues.append("Identical frame reran OCR") }
        if step == 7, !lines.isEmpty { issues.append("Removed content retained an overlay") }
        if lines.contains(where: { !$0.sourcePixelsAreCurrent }) { issues.append("Completed frame remained visually stale") }
        for placement in placements {
          let expected: CGFloat = placement.line.source.text == copy.heading ? 36 : 26
          let measured = placement.line.source.appearance.fontSizeScale * frame.imageSize.height
          if measured > 0, abs(measured / expected - 1) > 0.25 {
            issues.append("Source font calibration drift: \(placement.line.source.text)")
          }
        }
        let heading = placements.first { $0.line.source.text == copy.heading }
        if step != 7, lines.isEmpty { issues.append("No recognized content") }
        if step != 7, heading == nil { issues.append("Missing translated heading") }
        if let heading {
          if let baseline = firstHeadingFont {
            if abs(heading.fontSize / baseline - 1) > 0.15 { issues.append("Unchanged heading font drift exceeded 15%") }
          } else { firstHeadingFont = heading.fontSize }
        }
        let id = "\(copy.code)-\(step)"
        let png = NSMutableData()
        let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        try (png as Data).write(to: root.appendingPathComponent("\(id)-source.png"))
        if let rendered = CaptureResultImage.png(imageData: png as Data, imageSize: frame.imageSize, lines: lines) {
          try rendered.write(to: root.appendingPathComponent("\(id)-result.png"))
        }
        records.append([
          "id": id,
          "language": copy.code,
          "step": step,
          "pattern": [
            "initial",
            "identical",
            "unrelated-animation",
            "sentence-change",
            "reflow",
            "theme",
            "scroll",
            "removed",
            "return",
          ][step],
          "hashMilliseconds": milliseconds(started.duration(to: hashed)),
          "processingMilliseconds": milliseconds(hashed.duration(to: completed)),
          "recognitionGeneration": store.state.recognitionGeneration,
          "headingFont": heading?.fontSize ?? 0,
          "typography": placements.map { placement in
            let source = placement.line.source
            return [
              "source": source.text,
              "sourceFont": source.appearance.fontSizeScale * frame.imageSize.height,
              "renderedFont": placement.fontSize,
              "inkHeight": source.appearance.inkHeightScale * frame.imageSize.height,
              "runs": source.styleRuns.map { run in
                [
                  "text": (source.text as NSString).substring(with: run.range),
                  "font": run.appearance.fontSizeScale * frame.imageSize.height,
                  "ink": run.appearance.inkHeightScale * frame.imageSize.height,
                  "box": [run.box.minX, run.box.minY, run.box.width, run.box.height],
                ] as [String: Any]
              },
            ] as [String: Any]
          },
          "issues": issues,
          "sourceText": lines.map(\.source.text),
          "targetText": lines.map(\.displayedText),
        ])
        try JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys])
          .write(to: root.appendingPathComponent("sequence-results.json"))
        print("\(id): \(issues)")
        fflush(stdout)
      }
      await store.send(.dismissOverlay).finish()
    }
    return records.count { !($0["issues"] as! [String]).isEmpty }
  }

  static func milliseconds(_ value: Duration) -> Double {
    Double(value.components.seconds) * 1000 + Double(value.components.attoseconds) / 1e15
  }

  static func scene(_ copy: CaptureQualityLanguage, step: Int) throws -> CGImage {
    let dark = step == 5 || step == 6
    let ctx = CGContext(
      data: nil,
      width: 1200,
      height: 800,
      bitsPerComponent: 8,
      bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(CGColor(gray: dark ? 0.09 : 0.97, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
    if step == 7 { return ctx.makeImage()! }
    let offset: CGFloat = step == 6 ? 50 : 0
    func text(_ value: String, y: CGFloat, width: CGFloat, size: CGFloat) {
      let paragraph = NSMutableParagraphStyle()
      paragraph.baseWritingDirection = copy.rtl ? .rightToLeft : .leftToRight
      paragraph.alignment = copy.rtl ? .right : .left
      let attributed = NSAttributedString(string: value, attributes: [
        .font: NSFont.systemFont(ofSize: size),
        .paragraphStyle: paragraph,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: dark ? 0.94 : 0.08, alpha: 1),
      ])
      let frame = CTFramesetterCreateFrame(
        CTFramesetterCreateWithAttributedString(attributed),
        CFRange(location: 0, length: 0),
        CGPath(
          rect: CGRect(x: 50, y: 800 - y - offset - 250, width: width, height: 250),
          transform: nil
        ),
        nil
      )
      CTFrameDraw(frame, ctx)
    }
    text(copy.heading, y: 40, width: 1050, size: 36)
    text(step == 3 ? copy.note : copy.body, y: 220, width: step == 4 ? 520 : 1050, size: 26)
    text(copy.labels[3], y: 610, width: 1050, size: 26)
    ctx.setFillColor(CGColor(red: step == 2 ? 0.8 : 0.2, green: 0.5, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 20, y: 20, width: 1160, height: 25))
    return ctx.makeImage()!
  }
}
