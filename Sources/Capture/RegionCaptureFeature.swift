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
    /// Screenshot with each recognized box blurred (no text) — the backdrop the
    /// glass translation chips are drawn over, so the original text is hidden.
    var backgroundImageData: Data?
    var isTranslating = false
    var lastError: String?
    /// Set once the user copies the text; the window observes this to close.
    /// (Image save/copy is handled by the window controller, which captures
    /// the live glass result on screen and then closes the window itself.)
    var finished = false

    @Shared(.settings) var settings
  }

  enum Action {
    case task
    case captured(Result<CapturedRegion, any Error>)
    case translated(id: UUID, text: String)
    case backgroundReady(Data?)
    case copyOriginalRequested
    case copyTranslationRequested
  }

  @Dependency(\.ocr) var ocr
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.translation) var translation
  @Dependency(\.uuid) var uuid

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
          OverlayLine(id: uuid(), box: $0.boundingBoxNormalized, sourceText: $0.text, translated: nil, rowCount: $0.rowCount)
        }
        guard !state.overlayLines.isEmpty, let data = captured.pngData else { return .none }
        state.isTranslating = true
        let source = state.settings.languages.source.localeLanguage
        let target = state.settings.languages.target.localeLanguage
        let strategy = state.settings.translation.strategy
        let lines = state.overlayLines
        let size = state.imageSize
        // Build the blurred backdrop (boxes blurred, no text) once up front; the
        // glass chips are drawn over it live as translations arrive.
        let background = Effect<Action>.run { send in
          let bg = await MainActor.run { blurredBackground(baseData: data, lines: lines, pixelSize: size) }
          await send(.backgroundReady(bg))
        }
        let translate = Effect<Action>.run { send in
          await withTaskGroup(of: Void.self) { group in
            for line in lines {
              group.addTask {
                let translated = try? await translation.translate(line.sourceText, source, target, strategy)
                await send(.translated(id: line.id, text: translated ?? line.sourceText))
              }
            }
          }
        }
        return .merge(background, translate)

      case .captured(.failure(let error)):
        state.lastError = error.localizedDescription
        return .none

      case .backgroundReady(let data):
        state.backgroundImageData = data
        return .none

      case .translated(let id, let text):
        if let index = state.overlayLines.firstIndex(where: { $0.id == id }) {
          state.overlayLines[index].translated = text
        }
        state.isTranslating = state.overlayLines.contains { $0.translated == nil }
        return .none

      case .copyOriginalRequested:
        let text = state.overlayLines.map(\.sourceText).joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        state.finished = true
        return .run { _ in await pasteboard.copyString(text) }

      case .copyTranslationRequested:
        let text = state.overlayLines.compactMap(\.translated).joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        state.finished = true
        return .run { _ in await pasteboard.copyString(text) }
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

// MARK: - Blurred backdrop

/// The screenshot with each recognized box gaussian blurred (rounded), so the
/// original text behind the translation chips is obscured. The glass chips are
/// drawn over this on screen.
@MainActor
func blurredBackground(baseData: Data, lines: [OverlayLine], pixelSize: CGSize) -> Data? {
  guard
    pixelSize.width > 0, pixelSize.height > 0,
    let baseImage = NSImage(data: baseData),
    let baseCG = baseImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
  else { return nil }

  let result = NSImage(size: pixelSize)
  result.lockFocus()
  baseImage.draw(in: CGRect(origin: .zero, size: pixelSize))

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

  for line in lines where !(line.translated ?? line.sourceText).isEmpty {
    // box is top-left normalized; convert to AppKit bottom-left points.
    let rect = CGRect(
      x: line.box.minX * pixelSize.width,
      y: (1 - line.box.maxY) * pixelSize.height,
      width: line.box.width * pixelSize.width,
      height: line.box.height * pixelSize.height
    )
    let cropRect = CGRect(
      x: line.box.minX * pixelWidth,
      y: line.box.minY * pixelHeight,
      width: line.box.width * pixelWidth,
      height: line.box.height * pixelHeight
    )
    let corner = min(6, rect.height * 0.2)
    let clip = NSBezierPath(roundedRect: rect, xRadius: corner, yRadius: corner)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    if let blurredCG, let cropped = blurredCG.cropping(to: cropRect) {
      NSImage(cgImage: cropped, size: rect.size).draw(in: rect)
    }
    NSGraphicsContext.restoreGraphicsState()
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
    let hosting = NSHostingController(
      rootView: RegionResultView(
        store: store,
        onImageFrame: { [weak self] rect in self?.imageContentFrame = rect },
        onSaveImage: { [weak self] in self?.saveImage() },
        onCopyImage: { [weak self] in self?.copyImage() },
        onClose: { [weak panel] in panel?.close() }
      )
    )
    panel.contentViewController = hosting

    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.panel = panel
    // Resize the window to the screenshot's aspect ratio once the capture
    // lands, so the image fits without scrolling; also remember the source
    // pixel size so save/copy can momentarily resize to 1:1 for capture.
    observeToken = observe { [weak self, weak panel] in
      guard let self, let panel, store.imageSize != .zero else { return }
      capturedPixelSize = store.imageSize
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

  @Dependency(\.date.now) private var now
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.savePanel) private var savePanel
  @Dependency(\.screenCapture) private var screenCapture

  private var panel: NSWindow?
  private var observeToken: ObserveToken?
  /// Latest on-screen rect of the image area, in the window's top-left SwiftUI
  /// coordinates. Used to screen-capture the glass result for save/copy.
  private var imageContentFrame = CGRect.zero
  /// Source-screenshot pixel size; lets capture resize the panel to 1:1 with
  /// the original pixels so the saved PNG isn't limited by on-screen scaling.
  private var capturedPixelSize = CGSize.zero

  /// Captures the live glass result on screen (the image area only), so the
  /// saved/copied PNG is pixel-for-pixel what the user sees — and at the
  /// original screenshot resolution. Briefly resizes the window so the image
  /// area maps 1:1 to source pixels, then restores.
  private func captureContentPNG() async -> Data? {
    guard let panel, let contentView = panel.contentView, imageContentFrame.width > 1 else { return nil }
    let originalFrame = panel.frame
    let didResize = resizeForNativeCapture(panel: panel, contentView: contentView)
    if didResize {
      // Give SwiftUI a tick to relayout so imageContentFrame reflects the new
      // window size before we read it for the capture rect.
      try? await Task.sleep(for: .milliseconds(80))
    }

    // SwiftUI .global is top-left within the window content; AppKit is
    // bottom-left. Flip, then convert window → screen coordinates.
    let f = imageContentFrame
    let windowRect = CGRect(x: f.minX, y: contentView.bounds.height - f.maxY, width: f.width, height: f.height)
    let screenRect = panel.convertToScreen(windowRect)
    let image = try? await screenCapture.captureImage(screenRect, [], displayID(coveringMostOf: screenRect), nil)
    let data = image?.pngData

    if didResize {
      panel.setFrame(originalFrame, display: true)
    }
    return data
  }

  /// Resizes the panel so the image area matches the source's native points
  /// (= original pixels at this display's backing scale). Skips when already
  /// near 1:1 or when the native size wouldn't fit on screen.
  private func resizeForNativeCapture(panel: NSWindow, contentView: NSView) -> Bool {
    guard
      capturedPixelSize.width > 0,
      imageContentFrame.width > 1,
      let screen = panel.screen ?? NSScreen.main
    else { return false }
    let scale = screen.backingScaleFactor
    let nativeImageWidth = capturedPixelSize.width / scale
    let ratio = nativeImageWidth / imageContentFrame.width
    guard abs(ratio - 1.0) > 0.02 else { return false }

    let current = contentView.frame.size
    let target = CGSize(width: current.width * ratio, height: current.height * ratio)
    let visible = screen.visibleFrame.size
    guard target.width <= visible.width, target.height <= visible.height else { return false }

    panel.setContentSize(target)
    panel.center()
    return true
  }

  private func saveImage() {
    Task { @MainActor in
      guard let data = await captureContentPNG() else { return }
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd-HHmmss"
      let name = "SwiftyCrow-\(formatter.string(from: now)).png"
      if await savePanel.savePNG(data, name) {
        panel?.close()
      }
    }
  }

  private func copyImage() {
    Task { @MainActor in
      guard let data = await captureContentPNG() else { return }
      await pasteboard.copyImage(data)
      panel?.close()
    }
  }

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
