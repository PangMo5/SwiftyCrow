import AppKit
import Sharing
import SwiftUI

// MARK: - OverlayWindowController

@MainActor
final class OverlayWindowController: NSObject, NSWindowDelegate {

  // MARK: Internal

  var windowID: CGWindowID? {
    guard let window else { return nil }
    return CGWindowID(window.windowNumber)
  }

  /// Registers the sink for controls drawn on the overlay (live toggle, close).
  func setEventHandler(_ handler: @escaping @Sendable (OverlayUserAction) -> Void) {
    eventHandler = handler
  }

  func update(_ state: OverlayRenderState) {
    model.lines = state.lines
    model.hideOnHover = state.hideOnHover
    model.isTranslating = state.isTranslating
    model.isLive = state.isLive
    model.liveMode = state.liveMode
    model.backgroundImageData = state.backgroundImageData
    model.imageSize = state.imageSize
    model.translationUnavailable = state.translationUnavailable

    if state.isVisible {
      let isNewWindow = window == nil
      showWindowIfNeeded()
      if let window {
        // Snap to the stored frame on first show or whenever a fresh placement
        // arrives (the user picked a new region/window). Otherwise the user's
        // own drag/resize is the source of truth and we leave the frame alone.
        if isNewWindow || state.placementID != lastPlacementID {
          window.setFrame(overlayFrame.rect, display: true)
          window.makeKeyAndOrderFront(nil)
        }
      }
      applyPassThrough()
    } else {
      stopResizeEdgeTracking()
      window?.orderOut(nil)
    }
    lastPlacementID = state.placementID

    // In Window mode the translation lives in a detached panel; the overlay
    // above is just a thin region frame.
    let showResult = state.isVisible && model.isWindowFrame && !state.lines.isEmpty
    updateResultWindow(visible: showResult)
  }

  /// Copies the currently shown translation (falling back to source text) to
  /// the pasteboard — driven by the overlay's hidden ⌘C affordance.
  func copyTranslation() {
    let text = model.lines
      .compactMap { $0.translated ?? ($0.sourceText.isEmpty ? nil : $0.sourceText) }
      .joined(separator: "\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func windowDidMove(_: Notification) {
    scheduleFrameSave()
    markInteracting()
  }

  func windowDidResize(_: Notification) {
    scheduleFrameSave()
  }

  func windowWillStartLiveResize(_: Notification) {
    pendingInteractionReset?.cancel()
    model.isInteracting = true
  }

  func windowDidEndLiveResize(_: Notification) {
    pendingInteractionReset?.cancel()
    model.isInteracting = false
    flushFrameSave()
  }

  // MARK: Private

  @Shared(.overlayFrame) private var overlayFrame

  private let model = OverlayWindowModel()
  private let resizeMargin: CGFloat = 14
  /// Top-left grab handle — the only region that moves the window. Its hit zone
  /// stays live even while the handle is faded out (so you can always grab it).
  private let moveHandleSize = CGSize(width: 56, height: 40)
  /// Top-right cluster (LIVE toggle + close) — clickable, but never moves the
  /// window.
  private let controlsZoneSize = CGSize(width: 170, height: 52)
  private var resizeEdgeMonitors = [Any]()
  private var pendingFrameSaveTask: Task<Void, Never>?
  private var pendingInteractionReset: Task<Void, Never>?
  private var window: OverlayPanel?
  private var resultWindow: NSPanel?
  private var lastPlacementID = 0
  private var eventHandler: (@Sendable (OverlayUserAction) -> Void)?

  /// `windowDidMove` has no will-start / did-end pair, so debounce a reset
  /// instead. 150 ms is short enough to feel responsive once the drag ends
  /// but long enough that the lines don't pop in/out mid-drag.
  private func markInteracting() {
    pendingInteractionReset?.cancel()
    model.isInteracting = true
    pendingInteractionReset = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      model.isInteracting = false
    }
  }

  private func scheduleFrameSave() {
    guard let window else { return }
    let frame = window.frame
    pendingFrameSaveTask?.cancel()
    pendingFrameSaveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled, let self else { return }
      $overlayFrame.withLock { $0 = OverlayFrame(rect: frame) }
    }
  }

  private func flushFrameSave() {
    pendingFrameSaveTask?.cancel()
    pendingFrameSaveTask = nil
    guard let window else { return }
    $overlayFrame.withLock { $0 = OverlayFrame(rect: window.frame) }
  }

  private func showWindowIfNeeded() {
    if window != nil { return }

    let panel = OverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
      styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Movement is gated to the move-handle zone in updatePassThroughForCursor;
    // never move on a plain background drag.
    panel.isMovableByWindowBackground = false
    panel.isMovable = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.worksWhenModal = true
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.delegate = self

    let rootView = OverlayRootView(
      model: model,
      onToggleLive: { [weak self] in self?.eventHandler?(.toggleLive) },
      onClose: { [weak self] in self?.eventHandler?(.close) },
      onCopy: { [weak self] in self?.copyTranslation() }
    )
    let hosting = NSHostingView(rootView: rootView)
    hosting.frame = panel.contentLayoutRect
    hosting.autoresizingMask = [.width, .height]
    // Match the SwiftUI glass shape so the borderless panel chrome stops
    // showing a thin grey edge around the overlay.
    hosting.wantsLayer = true
    hosting.layer?.cornerRadius = 22
    hosting.layer?.cornerCurve = .continuous
    hosting.layer?.masksToBounds = true
    panel.contentView = hosting
    window = panel
  }

  /// The overlay always lets mouse interaction reach the apps below — except in
  /// a thin margin around the edges (resize) and the top-right handle cluster
  /// (live toggle / close / drag-to-move). We can't express that with a static
  /// `ignoresMouseEvents` (it's all-or-nothing per window), so we track the
  /// cursor and flip the window's mouse handling based on where it sits.
  private func applyPassThrough() {
    guard window != nil else { return }
    startResizeEdgeTracking()
    updatePassThroughForCursor()
  }

  private func startResizeEdgeTracking() {
    guard resizeEdgeMonitors.isEmpty else { return }
    // Global fires while events pass through to apps below (interior); local
    // fires while the window is interactive near an edge / on the handle.
    // Together they keep the cursor state current as it moves in and out.
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
      MainActor.assumeIsolated { self?.updatePassThroughForCursor() }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      MainActor.assumeIsolated { self?.updatePassThroughForCursor() }
      return event
    }
    resizeEdgeMonitors = [global, local].compactMap { $0 }
  }

  private func stopResizeEdgeTracking() {
    resizeEdgeMonitors.forEach(NSEvent.removeMonitor)
    resizeEdgeMonitors.removeAll()
    window?.alphaValue = 1
  }

  private func updatePassThroughForCursor() {
    guard let window else { return }
    let mouse = NSEvent.mouseLocation
    let frame = window.frame

    // Drive the move handle's hover visibility from the global cursor position
    // (interior pass-through means SwiftUI's .onHover never fires here).
    let inside = frame.contains(mouse)
    if model.cursorInside != inside { model.cursorInside = inside }

    // Top-left move handle: the ONLY region that drags the window. Its hit zone
    // is always live, even while the handle itself is faded out.
    let moveZone = CGRect(
      x: frame.minX,
      y: frame.maxY - moveHandleSize.height,
      width: moveHandleSize.width,
      height: moveHandleSize.height
    )
    if moveZone.contains(mouse) {
      window.alphaValue = 1
      window.isMovableByWindowBackground = true
      window.ignoresMouseEvents = false
      return
    }

    // Everywhere else, a background drag must not move the window.
    window.isMovableByWindowBackground = false

    // Top-right controls (LIVE toggle, close): clickable, but don't move.
    let controlsZone = CGRect(
      x: frame.maxX - controlsZoneSize.width,
      y: frame.maxY - controlsZoneSize.height,
      width: controlsZoneSize.width,
      height: controlsZoneSize.height
    )
    if controlsZone.contains(mouse) {
      window.alphaValue = 1
      window.ignoresMouseEvents = false
      return
    }

    // Bottom hint banner (shown when the translation model is missing): keep it
    // clickable so its "Open Settings" button works.
    if model.translationUnavailable {
      let hintZone = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: 56)
      if hintZone.contains(mouse) {
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        return
      }
    }

    // Edges stay interactive for resizing.
    let withinX = mouse.x >= frame.minX - resizeMargin && mouse.x <= frame.maxX + resizeMargin
    let withinY = mouse.y >= frame.minY - resizeMargin && mouse.y <= frame.maxY + resizeMargin
    let nearHorizontalEdge = min(abs(mouse.x - frame.minX), abs(mouse.x - frame.maxX)) < resizeMargin
    let nearVerticalEdge = min(abs(mouse.y - frame.minY), abs(mouse.y - frame.maxY)) < resizeMargin
    if withinX, withinY, nearHorizontalEdge || nearVerticalEdge {
      window.alphaValue = 1
      window.ignoresMouseEvents = false
      return
    }

    // Interior: clicks pass through. With "hide on hover" on, fade the overlay
    // out while the cursor is over it so the original text is readable; the
    // monitors restore it once the cursor moves back to an edge or off it.
    window.ignoresMouseEvents = true
    window.alphaValue = (model.hideOnHover && inside) ? 0 : 1
  }

  private func updateResultWindow(visible: Bool) {
    guard visible else {
      resultWindow?.orderOut(nil)
      return
    }
    if let resultWindow {
      resultWindow.orderFront(nil)
      return
    }
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
      styleMask: [.borderless, .resizable, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.isFloatingPanel = true
    panel.isMovableByWindowBackground = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    let hosting = NSHostingView(rootView: LiveResultView(model: model))
    panel.contentView = hosting
    resultWindow = panel
    sizeResultWindow(panel)
    panel.orderFront(nil)
  }

  /// Size the detached window to the captured region's aspect and park it in the
  /// bottom-right of the screen. Only done once, on creation — after that the
  /// user owns its position/size.
  private func sizeResultWindow(_ panel: NSPanel) {
    let screen = window?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    let scale = screen?.backingScaleFactor ?? 2
    guard model.imageSize.width > 0, model.imageSize.height > 0 else { return }

    var w = model.imageSize.width / scale + 20
    var h = model.imageSize.height / scale + 20
    let ratio = min(min(visible.width * 0.4 / w, visible.height * 0.6 / h), 1)
    w *= ratio
    h *= ratio
    panel.setContentSize(CGSize(width: max(220, w), height: max(140, h)))
    panel.setFrameOrigin(CGPoint(x: visible.maxX - panel.frame.width - 24, y: visible.minY + 24))
  }
}

// MARK: - OverlayWindowModel

@Observable
final class OverlayWindowModel {
  var lines = [OverlayLine]()
  var hideOnHover = false
  var isInteracting = false
  /// Whether the cursor is over the overlay — drives the move handle's
  /// hover-visibility (set from the controller's global cursor tracking).
  var cursorInside = false
  var isLive = false
  var isTranslating = false
  var liveMode = OverlayLiveMode.inPlace
  var backgroundImageData: Data?
  var imageSize = CGSize.zero
  var translationUnavailable = false

  /// In Window mode while live, the overlay is just a thin region frame and the
  /// translation lives in a detached window.
  var isWindowFrame: Bool {
    liveMode == .window && isLive
  }
}

// MARK: - OverlayRootView

private struct OverlayRootView: View {

  // MARK: Internal

  let model: OverlayWindowModel

  let onToggleLive: () -> Void
  let onClose: () -> Void
  let onCopy: () -> Void

  var body: some View {
    OverlayView(
      lines: model.isInteracting ? [] : model.lines,
      isTranslating: model.isTranslating,
      isLive: model.isLive,
      translationUnavailable: model.translationUnavailable,
      frameOnly: model.isWindowFrame,
      showMoveHandle: model.cursorInside,
      onToggleLive: onToggleLive,
      onClose: onClose
    )
    .background {
      // Hidden affordances: ⌘, opens Settings, ⌘C copies the translated text.
      Group {
        Button("Open Settings") { openSettings() }
          .keyboardShortcut(",", modifiers: .command)
        Button("Copy translation") { onCopy() }
          .keyboardShortcut("c", modifiers: .command)
          .disabled(model.lines.isEmpty)
      }
      .frame(width: 0, height: 0)
      .opacity(0)
      .accessibilityHidden(true)
    }
  }

  // MARK: Private

  @Environment(\.openSettings) private var openSettings

}

// MARK: - LiveResultView

/// The detached translation window shown in Window live mode: the blurred
/// screenshot with glass translation chips, updating live.
private struct LiveResultView: View {

  // MARK: Internal

  let model: OverlayWindowModel

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .overlay(alignment: .bottom) {
        if model.translationUnavailable {
          TranslationModelHint()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.15), value: model.translationUnavailable)
      .padding(10)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }

  // MARK: Private

  @ViewBuilder
  private var content: some View {
    if let data = model.backgroundImageData, let image = NSImage(data: data) {
      ZStack {
        Image(nsImage: image)
          .resizable()
        TranslationOverlayLayer(lines: model.lines, glass: true)
      }
      .aspectRatio(aspectRatio, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      ProgressView()
    }
  }

  private var aspectRatio: CGFloat {
    guard model.imageSize.height > 0 else { return 1 }
    return model.imageSize.width / model.imageSize.height
  }
}
