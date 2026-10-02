// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Foundation
import ImageIO
import WebKit

// MARK: - FixturePage

/// Independent WebKit pixels and authored expectations; no SwiftyCrow import.
@MainActor
final class FixturePage: NSObject, WKNavigationDelegate {

  // MARK: Lifecycle

  init(size: CGSize) {
    view = WKWebView(frame: CGRect(origin: .zero, size: size))
    super.init()
    view.navigationDelegate = self
  }

  // MARK: Internal

  let view: WKWebView

  func load(_ html: String) async throws {
    try await withCheckedThrowingContinuation { continuation in
      self.continuation = continuation
      view.loadHTMLString(html, baseURL: nil)
    }
  }

  func webView(_: WKWebView, didFinish _: WKNavigation!) {
    continuation?.resume()
    continuation = nil
  }

  func webView(_: WKWebView, didFail _: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  func webView(_: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
    continuation?.resume(throwing: error)
    continuation = nil
  }

  // MARK: Private

  private var continuation: CheckedContinuation<Void, Error>?

}

// MARK: - GenerateWebFixtures

@main
struct GenerateWebFixtures {
  @MainActor
  static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    Task { @MainActor in
      do {
        try await generate()
        exit(0)
      } catch {
        fputs("Fixture generation failed: \(error)\n", stderr)
        exit(1)
      }
    }
    app.run()
  }

  @MainActor
  static func generate() async throws {
    guard CommandLine.arguments.count == 3 else {
      print("Usage: GenerateWebFixtures source.html new-output-directory")
      exit(2)
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    guard !FileManager.default.fileExists(atPath: output.path) else { throw CocoaError(.fileWriteFileExists) }
    let template = try String(contentsOf: input, encoding: .utf8)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    var cases = [[String: Any]]()
    for width in [1_080, 640] {
      for theme in ["light", "dark"] {
        let size = CGSize(width: width, height: width == 640 ? 1_650 : 1_050)
        let page = FixturePage(size: size)
        let window = NSWindow(contentRect: page.view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = page.view
        window.orderFrontRegardless()
        try await page.load(template.replacingOccurrences(of: "{{THEME}}", with: theme))
        let documentHeight = try await page.view.callAsyncJavaScript("""
          await document.fonts.ready;
          return Math.ceil(document.documentElement.scrollHeight);
          """, arguments: [:], in: nil, contentWorld: .page) as! Double
        page.view.setFrameSize(CGSize(width: CGFloat(width), height: max(size.height, documentHeight)))
        window.setContentSize(page.view.frame.size)
        let geometry = try await page.view.callAsyncJavaScript("""
            await document.fonts.ready;
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
            if (document.documentElement.scrollHeight > innerHeight) throw Error(`Fixture is clipped: ${document.documentElement.scrollHeight}/${innerHeight}`);
            return [...document.querySelectorAll('[data-protected]')].map(e => {
              const b = e.getBoundingClientRect();
              return [b.x / innerWidth, b.y / innerHeight, b.width / innerWidth, b.height / innerHeight];
            });
          """, arguments: [:], in: nil, contentWorld: .page) as! [[Double]]
        let snapshot = WKSnapshotConfiguration()
        snapshot.rect = page.view.bounds
        snapshot.afterScreenUpdates = true
        let bitmap = try await page.view.takeSnapshot(configuration: snapshot)
        guard let image = bitmap.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw CocoaError(.coderInvalidValue) }
        let name = "reading-\(width)-\(theme)"
        guard
          let destination = CGImageDestinationCreateWithURL(
            output.appendingPathComponent(name + ".png") as CFURL,
            "public.png" as CFString,
            1,
            nil
          )
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        for target in ["ko", "ar", "de"] {
          cases.append([
            "id": name + "-to-" + target,
            "source": name + ".png",
            "sourceLanguage": "auto",
            "targetLanguage": target,
            "structure": "authored-web-mixed-reading",
            "requiredText": [
              "Workspace overview",
              "Project documents",
              "Integer reference",
              "Reading direction",
              "Vertical reading",
            ],
            "requiredParagraphs": [
              "The report shows each project and its remaining budget. Select a document to review the details."
            ],
            "requiredLiteralText": [
              "proposal.pdf",
              "budget.xlsx",
              "photo.JPEG",
              "i8",
              "u32",
              "isize",
              "usize",
              "scripts/export.sh",
              "report.v2.pdf",
            ],
            "requiredTranslatedText": ["Workspace overview", "Project documents", "Important instructions"],
            "requiredAlignments": [
              ["source": "Workspace overview", "alignment": "center"],
              ["source": "Print", "alignment": "center"],
              ["source": "Share", "alignment": "center"],
              ["source": "Length", "alignment": "leading"],
              ["source": "Signed", "alignment": "leading"],
              ["source": "Unsigned", "alignment": "leading"],
            ],
            "protectedRectangles": geometry,
            "maximumReviewLines": 0,
            "minimumFontRatio": 0.5,
          ])
        }
        window.orderOut(nil)
        print("\(name): \(image.width) × \(image.height)")
      }
    }
    try JSONSerialization.data(withJSONObject: cases, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appendingPathComponent("corpus.json"))
    try template.write(to: output.appendingPathComponent("source.html"), atomically: true, encoding: .utf8)
  }
}
