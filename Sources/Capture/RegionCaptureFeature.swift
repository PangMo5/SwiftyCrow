import AppKit
import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation
import Sharing
import SwiftUI

// MARK: - RegionCaptureFeature

@Reducer
struct RegionCaptureFeature {

  // MARK: Internal

  @ObservableState
  struct State: Equatable {
    var region: CGRect
    var imageData: Data?
    var imageSize: CGSize = .zero
    var overlayLines = [OverlayLine]()
    /// Screenshot with each box blurred + translation drawn in, built once
    /// translation finishes. Shown on screen and used for copy/save so both
    /// match exactly.
    var composedImageData: Data?
    var isTranslating = false
    var lastError: String?

    @Shared(.settings) var settings
  }

  enum Action {
    case task
    case captured(Result<CapturedRegion, any Error>)
    case translated(id: UUID, text: String)
    case composedReady(Data?)
  }

  @Dependency(OCRClient.self) var ocr
  @Dependency(ScreenCaptureClient.self) var screenCapture
  @Dependency(TranslationClient.self) var translation

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        let region = state.region
        return .run { [settings = state.$settings] send in
          await send(.captured(Result {
            let snapshot = settings.wrappedValue
            let image = try await screenCapture.captureImage(
              region,
              [],
              displayID(coveringMostOf: region),
              Bundle.main.bundleIdentifier
            )
            let result = try await ocr.recognizeText(image, snapshot.languages.source, snapshot.recognition.mode)
            return CapturedRegion(
              pngData: image.pngData,
              size: CGSize(width: image.width, height: image.height),
              lines: result.lines
            )
          }))
        }

      case .captured(.success(let captured)):
        state.imageData = captured.pngData
        state.imageSize = captured.size
        state.overlayLines = captured.lines.map {
          OverlayLine(id: UUID(), box: $0.boundingBoxNormalized, sourceText: $0.text, translated: nil)
        }
        guard !state.overlayLines.isEmpty else { return .none }
        state.isTranslating = true
        let source = state.settings.languages.source.localeLanguage
        let target = state.settings.languages.target.localeLanguage
        let strategy = state.settings.translation.strategy
        let lines = state.overlayLines
        return .run { send in
          await withTaskGroup(of: Void.self) { group in
            for line in lines {
              group.addTask {
                let translated = try? await translation.translate(line.sourceText, source, target, strategy)
                await send(.translated(id: line.id, text: translated ?? line.sourceText))
              }
            }
          }
        }

      case .captured(.failure(let error)):
        state.lastError = error.localizedDescription
        return .none

      case .translated(let id, let text):
        if let index = state.overlayLines.firstIndex(where: { $0.id == id }) {
          state.overlayLines[index].translated = text
        }
        state.isTranslating = state.overlayLines.contains { $0.translated == nil }
        guard !state.isTranslating, let data = state.imageData else { return .none }
        let lines = state.overlayLines
        let size = state.imageSize
        return .run { send in
          let composed = await MainActor.run { composeBlurredImage(baseData: data, lines: lines, pixelSize: size) }
          await send(.composedReady(composed))
        }

      case .composedReady(let data):
        state.composedImageData = data
        return .none
      }
    }
  }
}

// MARK: - CapturedRegion

struct CapturedRegion: Equatable, Sendable {
  var pngData: Data?
  var size: CGSize
  var lines: [OCRResult.Line]
}

// MARK: - CGImage PNG

extension CGImage {
  var pngData: Data? {
    let rep = NSBitmapImageRep(cgImage: self)
    return rep.representation(using: .png, properties: [:])
  }
}

// MARK: - Blurred composition

/// Builds the result image: the screenshot with each recognized box gaussian
/// blurred, darkened for legibility, and the translation drawn on top. Used for
/// both the on-screen preview and copy/save so they're identical.
@MainActor
func composeBlurredImage(baseData: Data, lines: [OverlayLine], pixelSize: CGSize) -> Data? {
  guard
    let baseImage = NSImage(data: baseData),
    let baseCG = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil),
    pixelSize.width > 0, pixelSize.height > 0
  else { return nil }

  let result = NSImage(size: pixelSize)
  result.lockFocus()

  let fullRect = CGRect(origin: .zero, size: pixelSize)
  baseImage.draw(in: fullRect)

  // Blur the whole image once, then crop each box region out of it.
  let ciContext = CIContext()
  let ciBase = CIImage(cgImage: baseCG)
  let blurredCI = ciBase
    .clampedToExtent()
    .applyingGaussianBlur(sigma: max(6, CGFloat(baseCG.height) * 0.012))
    .cropped(to: ciBase.extent)
  let blurredCG = ciContext.createCGImage(blurredCI, from: ciBase.extent)
  let pixelWidth = CGFloat(baseCG.width)
  let pixelHeight = CGFloat(baseCG.height)

  for line in lines {
    let text = line.translated ?? line.sourceText
    guard !text.isEmpty else { continue }

    // box is top-left normalized; convert to AppKit bottom-left points.
    let rect = CGRect(
      x: line.box.minX * pixelSize.width,
      y: (1 - line.box.maxY) * pixelSize.height,
      width: line.box.width * pixelSize.width,
      height: line.box.height * pixelSize.height
    )

    // Crop the blurred copy in top-left pixel coords and draw it in the box.
    let cropRect = CGRect(
      x: line.box.minX * pixelWidth,
      y: line.box.minY * pixelHeight,
      width: line.box.width * pixelWidth,
      height: line.box.height * pixelHeight
    )
    if let blurredCG, let cropped = blurredCG.cropping(to: cropRect) {
      NSImage(cgImage: cropped, size: rect.size).draw(in: rect)
    }

    NSColor.black.withAlphaComponent(0.35).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()

    let fontSize = max(8, rect.height * 0.58)
    let style = NSMutableParagraphStyle()
    style.lineBreakMode = .byTruncatingTail
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
      .foregroundColor: NSColor.white,
      .paragraphStyle: style,
    ]
    let inset = max(0, (rect.height - fontSize * 1.2) / 2)
    let textRect = rect.insetBy(dx: 6, dy: inset)
    (text as NSString).draw(in: textRect, withAttributes: attrs)
  }

  result.unlockFocus()

  guard let tiff = result.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
  return rep.representation(using: .png, properties: [:])
}

// MARK: - RegionResultClient

@DependencyClient
struct RegionResultClient {
  /// Captures `region`, runs OCR + per-line translation, and shows the result
  /// window with the translation drawn in place over the screenshot.
  var present: @Sendable (_ region: CGRect) async -> Void
}

extension RegionResultClient: DependencyKey {
  static let liveValue: RegionResultClient = {
    // The controller touches AppKit, so build it lazily on the main actor.
    nonisolated(unsafe) var controller: RegionResultWindowController?
    @MainActor
    func resolve() -> RegionResultWindowController {
      if let controller { return controller }
      let new = RegionResultWindowController()
      controller = new
      return new
    }
    return RegionResultClient(
      present: { region in await resolve().present(region: region) }
    )
  }()
}

extension DependencyValues {
  var regionResult: RegionResultClient {
    get { self[RegionResultClient.self] }
    set { self[RegionResultClient.self] = newValue }
  }
}

// MARK: - RegionResultWindowController

@MainActor
private final class RegionResultWindowController {

  // MARK: Internal

  func present(region: CGRect) {
    panel?.close()

    // The app is normally a menu-bar agent (.accessory), which can't become
    // frontmost — so it never receives ⌘-key events. Switch to .regular while
    // a result window is open so its shortcuts work, then revert on close.
    NSApp.setActivationPolicy(.regular)

    let store = Store(initialState: RegionCaptureFeature.State(region: region)) {
      RegionCaptureFeature()
    }
    let panel = ResultPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
      styleMask: [.borderless, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.isMovableByWindowBackground = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    // NSHostingController (not NSHostingView) joins the responder chain, so
    // SwiftUI .keyboardShortcut and .help work inside the window.
    let hosting = NSHostingController(rootView: RegionResultView(store: store) { [weak panel] in
      panel?.close()
    })
    panel.contentViewController = hosting

    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.panel = panel
    // Resize the window to the screenshot's aspect ratio once the capture
    // lands, so the image fits without scrolling.
    observeToken = observe { [weak self, weak panel] in
      guard let self, let panel, store.imageSize != .zero else { return }
      fitWindow(panel, toPixelSize: store.imageSize)
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        guard self?.panel === panel else { return }
        self?.panel = nil
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  // MARK: Private

  private var panel: NSWindow?
  private var observeToken: ObserveToken?

  private func fitWindow(_ panel: NSWindow, toPixelSize pixelSize: CGSize) {
    let screen = panel.screen ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    let toolbarHeight: CGFloat = 52
    let padding: CGFloat = 24

    var width = pixelSize.width / scale + padding
    var height = pixelSize.height / scale + padding
    let maxWidth = visible.width * 0.85
    let maxHeight = visible.height * 0.85 - toolbarHeight
    let ratio = min(min(maxWidth / width, maxHeight / height), 1)
    width *= ratio
    height *= ratio

    panel.setContentSize(CGSize(width: max(360, width), height: height + toolbarHeight))
    panel.center()
  }
}

// MARK: - ResultPanel

// A borderless NSWindow (not NSPanel) so it reliably becomes the key window
// and receives ⌘-key events.
private final class ResultPanel: NSWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
}
