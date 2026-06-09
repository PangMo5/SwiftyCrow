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

  func update(_ state: OverlayRenderState) {
    model.lines = state.lines
    model.hideOnHover = state.hideOnHover
    model.isTranslating = state.isTranslating
    model.isLive = state.isLive
    model.showGuide = state.showGuide
    model.liveMode = state.liveMode
    model.backgroundImageData = state.backgroundImageData
    model.imageSize = state.imageSize

    if state.isVisible {
      let needsInitialFrame = window == nil || !(window?.isVisible ?? false)
      showWindowIfNeeded()
      if let window {
        // Only sync the panel back to the stored settings frame when we're
        // first showing it. After that the user's drag/resize is the source
        // of truth and forcing setFrame here would snap the window back
        // mid-translation.
        if needsInitialFrame {
          window.setFrame(overlayFrame.rect, display: true)
          window.makeKeyAndOrderFront(nil)
        }
      }
      applyPassThrough()
    } else {
      stopResizeEdgeTracking()
      window?.orderOut(nil)
    }

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
  /// Top-right zone (matching the badge chips) that drags the window while
  /// passing through.
  private let badgeHandleSize = CGSize(width: 190, height: 44)
  private var hoverMonitor: Any?
  private var resizeEdgeMonitors = [Any]()
  private var isHiddenForHover = false
  private var pendingFrameSaveTask: Task<Void, Never>?
  private var pendingInteractionReset: Task<Void, Never>?
  private var window: OverlayPanel?
  private var resultWindow: NSPanel?

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
    panel.isMovableByWindowBackground = true
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
      onHover: { [weak self] hovering in
        self?.handleHover(hovering)
      },
      onCopy: { [weak self] in
        self?.copyTranslation()
      }
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

  private func handleHover(_ hovering: Bool) {
    // Pass-through owns mouse handling while it's on; don't hover-hide.
    guard !model.passThrough else { return }
    guard model.hideOnHover, let window else {
      restoreFromHover()
      return
    }

    if hovering, !isHiddenForHover {
      isHiddenForHover = true
      window.alphaValue = 0.0
      window.ignoresMouseEvents = true
      startHoverMonitor()
    } else if !hovering, isHiddenForHover {
      restoreFromHover()
    }
  }

  private func restoreFromHover() {
    guard let window else { return }
    isHiddenForHover = false
    window.alphaValue = 1.0
    window.ignoresMouseEvents = model.passThrough
    stopHoverMonitor()
  }

  /// While passing through, the overlay lets all mouse interaction reach the
  /// apps below — except within a thin margin around the edges, where it stays
  /// interactive so the window can still be resized. We can't do this with a
  /// static `ignoresMouseEvents` (it's all-or-nothing per window), so we track
  /// the cursor and flip it based on whether it's near an edge. Moving the
  /// window is disabled while passing through; only resizing remains.
  private func applyPassThrough() {
    guard let window else { return }
    window.isMovableByWindowBackground = !model.passThrough
    if model.passThrough {
      startResizeEdgeTracking()
      updatePassThroughForCursor()
    } else {
      stopResizeEdgeTracking()
      window.ignoresMouseEvents = isHiddenForHover
    }
  }

  private func startResizeEdgeTracking() {
    guard resizeEdgeMonitors.isEmpty else { return }
    // Global fires while events pass through to apps below (interior); local
    // fires while the window is interactive near an edge. Together they keep
    // the near-edge state current as the cursor moves in and out.
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
  }

  /// While passing through, the overlay stays interactive in two places: the
  /// top-right badge zone (a move handle) and a thin margin around the edges
  /// (resize). Everywhere else, events pass through to the apps below.
  private func updatePassThroughForCursor() {
    guard model.passThrough, let window else { return }
    let mouse = NSEvent.mouseLocation
    let frame = window.frame

    // Top-right badge zone (where the LIVE / PASS-THROUGH chips sit) drags the
    // window — the only way to move it while passing through.
    let badgeZone = CGRect(
      x: frame.maxX - badgeHandleSize.width,
      y: frame.maxY - badgeHandleSize.height,
      width: badgeHandleSize.width,
      height: badgeHandleSize.height
    )
    if badgeZone.contains(mouse) {
      window.isMovableByWindowBackground = true
      window.ignoresMouseEvents = false
      return
    }

    // Edges stay interactive for resizing (but not moving).
    window.isMovableByWindowBackground = false
    let withinX = mouse.x >= frame.minX - resizeMargin && mouse.x <= frame.maxX + resizeMargin
    let withinY = mouse.y >= frame.minY - resizeMargin && mouse.y <= frame.maxY + resizeMargin
    let nearHorizontalEdge = min(abs(mouse.x - frame.minX), abs(mouse.x - frame.maxX)) < resizeMargin
    let nearVerticalEdge = min(abs(mouse.y - frame.minY), abs(mouse.y - frame.maxY)) < resizeMargin
    let nearEdge = withinX && withinY && (nearHorizontalEdge || nearVerticalEdge)
    window.ignoresMouseEvents = !nearEdge
  }

  private func startHoverMonitor() {
    guard hoverMonitor == nil else { return }
    hoverMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
    ) { [weak self] _ in
      Task { @MainActor in self?.handleGlobalMouseMove() }
    }
  }

  private func stopHoverMonitor() {
    if let hoverMonitor {
      NSEvent.removeMonitor(hoverMonitor)
      self.hoverMonitor = nil
    }
  }

  private func handleGlobalMouseMove() {
    guard let window, isHiddenForHover else { return }
    let location = NSEvent.mouseLocation
    if !window.frame.contains(location) {
      restoreFromHover()
    }
  }

  // MARK: Detached result window (Window live mode)

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
  var isLive = false
  var isTranslating = false
  var showGuide = true
  var liveMode = OverlayLiveMode.inPlace
  var backgroundImageData: Data?
  var imageSize: CGSize = .zero

  /// In Window mode while live, the overlay is just a thin region frame and the
  /// translation lives in a detached window.
  var isWindowFrame: Bool {
    liveMode == .window && isLive
  }

  /// The idle hint that's shown when there's nothing translated yet. It stays
  /// interactive (you can read it and drag the overlay).
  var showingGuide: Bool {
    showGuide && lines.isEmpty
  }

  /// Click-through is the default: once a translation is on screen (or the
  /// overlay is a region frame) the overlay forwards clicks/scroll to the apps
  /// below. Only the idle guide stays interactive.
  var passThrough: Bool {
    isWindowFrame || !lines.isEmpty
  }
}

// MARK: - OverlayRootView

private struct OverlayRootView: View {

  // MARK: Internal

  let model: OverlayWindowModel

  let onHover: (Bool) -> Void
  let onCopy: () -> Void

  var body: some View {
    OverlayView(
      lines: model.isInteracting ? [] : model.lines,
      isTranslating: model.isTranslating,
      isLive: model.isLive,
      frameOnly: model.isWindowFrame,
      showGuide: model.showGuide
    )
    .onHover { hovering in
      onHover(hovering)
    }
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
      .padding(10)
      .background(.ultraThinMaterial)
      .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 1)
      )
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
