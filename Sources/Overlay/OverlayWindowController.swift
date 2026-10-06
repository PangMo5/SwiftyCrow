// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Sharing
import SwiftUI

// MARK: - OverlayWindowController

@MainActor
final class OverlayWindowController: NSObject, NSWindowDelegate {

  // MARK: Internal

  /// Keep a remembered window reachable if its display was removed or resized.
  static func restoredResultFrame(_ frame: CGRect, screens: [CGRect], defaultScreen: CGRect) -> CGRect {
    let screen = screens.max { left, right in
      let a = left.intersection(frame)
      let b = right.intersection(frame)
      return (a.isNull ? 0 : a.width * a.height) < (b.isNull ? 0 : b.width * b.height)
    }.flatMap { $0.intersects(frame) ? $0 : nil } ?? defaultScreen
    let size = CGSize(width: min(frame.width, screen.width), height: min(frame.height, screen.height))
    return CGRect(
      x: max(screen.minX, min(frame.minX, screen.maxX - size.width)),
      y: max(screen.minY, min(frame.minY, screen.maxY - size.height)),
      width: size.width,
      height: size.height
    )
  }

  /// Registers the sink for controls drawn on the overlay (live toggle, close).
  func setEventHandler(_ handler: @escaping @Sendable (OverlayUserAction) -> Void) {
    eventHandler = handler
  }

  func update(_ state: OverlayRenderState) {
    // Renders arrive whenever any observed state changes, and plenty of those
    // changes don't affect the overlay. Skip the identical ones outright.
    guard state != lastState else { return }
    lastState = state
    assign(state.validatingSourceWindow(
      id: trackedWindowID,
      frame: trackedFrame,
      minimumGeneration: minimumSourceGeneration
    ))
    configureSourceTracking(state.isVisible ? state.sourceWindowID : nil)

    if state.isVisible {
      let isNewWindow = window == nil
      showWindowIfNeeded()
      if let window {
        // Snap to the stored frame on first show or whenever a fresh placement
        // arrives (the user picked a new region/window). Otherwise the user's
        // own drag/resize is the source of truth and we leave the frame alone.
        if isNewWindow || state.placementID != lastPlacementID {
          isPlacingWindow = true
          window.setFrame(overlayFrame.rect, display: true)
          isPlacingWindow = false
          if state.sourceWindowID == nil { window.makeKeyAndOrderFront(nil) }
        }
      }
      if let id = state.sourceWindowID { refreshSourceWindow(id) }
      applyPassThrough()
    } else {
      stopResizeEdgeTracking()
      teardownWindows()
    }
    lastPlacementID = state.placementID

    // In Window mode the translation lives in a detached panel; the overlay
    // above is just a thin region frame.
    let showResult = state.isVisible && model.isWindowFrame && !model.lines.isEmpty
    updateResultWindow(visible: showResult)
  }

  /// Copies the currently shown translation (falling back to source text) to
  /// the pasteboard — driven by the overlay's hidden ⌘C affordance.
  func copyTranslation() {
    let text = model.lines
      .map(\.displayedText)
      .filter { !$0.isEmpty }
      .joined(separator: "\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  func windowDidMove(_: Notification) {
    guard !isPlacingWindow, !model.tracksSourceWindow else { return }
    scheduleFrameSave()
    markInteracting()
  }

  func windowDidResize(_: Notification) {
    guard !isPlacingWindow, !model.tracksSourceWindow else { return }
    scheduleFrameSave()
  }

  func windowWillStartLiveResize(_: Notification) {
    pendingInteractionReset?.cancel()
    beginInteraction()
  }

  func windowDidEndLiveResize(_: Notification) {
    pendingInteractionReset?.cancel()
    endInteraction()
  }

  // MARK: Private

  @Shared(.overlayFrame) private var overlayFrame

  private let model = OverlayWindowModel()
  private let resizeMargin: CGFloat = 14
  /// Top-left grab handle — the only region that moves the window. Its hit zone
  /// stays live even while the handle is faded out (so you can always grab it).
  private let moveHandleSize = OverlayChromeMetrics.moveHandleSize
  /// Top-right cluster (LIVE toggle + close) — clickable, but never moves the
  /// window.
  private let controlsZoneSize = CGSize(width: 170, height: 52)
  private var resizeEdgeMonitors = [Any]()
  private var pendingFrameSaveTask: Task<Void, Never>?
  private var pendingInteractionReset: Task<Void, Never>?
  private var isPlacingWindow = false
  private var window: OverlayPanel?
  private var resultWindow: NSPanel?
  /// Keep geometry independently of the hosting window so hiding still releases
  /// SwiftUI animations without discarding the user's detached reading layout.
  private var savedResultWindowFrame: CGRect?
  private var lastPlacementID = 0
  private var lastState: OverlayRenderState?
  private var sourceTrackingTask: Task<Void, Never>?
  private var trackedWindowID: CGWindowID?
  private var trackedFrame: CGRect?
  private var didResolveTrackedWindow = false
  private var minimumSourceGeneration = 0
  private var eventHandler: (@Sendable (OverlayUserAction) -> Void)?

  /// Writes only what changed. `@Observable` notifies on every assignment, equal
  /// value or not, so blindly re-assigning `lines` or the backdrop on each
  /// render invalidated the whole overlay view tree at the live capture rate.
  private func assign(_ state: OverlayRenderState) {
    if model.tracksSourceWindow != (state.sourceWindowID != nil) { model.tracksSourceWindow = state.sourceWindowID != nil }
    if model.lastError != state.lastError { model.lastError = state.lastError }
    if model.lines != state.lines { model.lines = state.lines }
    if model.hideOnHover != state.hideOnHover { model.hideOnHover = state.hideOnHover }
    if model.isTranslating != state.isTranslating { model.isTranslating = state.isTranslating }
    if model.isLive != state.isLive { model.isLive = state.isLive }
    if model.liveMode != state.liveMode { model.liveMode = state.liveMode }
    if model.backdrop != state.backdrop {
      model.backdrop = state.backdrop
    }
    if model.imageSize != state.imageSize { model.imageSize = state.imageSize }
    if model.translationUnavailable != state.translationUnavailable {
      model.translationUnavailable = state.translationUnavailable
    }
    if model.isPreparingRecognition != state.isPreparingRecognition {
      model.isPreparingRecognition = state.isPreparingRecognition
    }
  }

  /// Releases both overlay windows rather than just hiding them.
  ///
  /// `orderOut` leaves the hosting views mounted, and SwiftUI keeps animating
  /// them: a `ProgressView` or the pulsing LIVE dot goes on running at display
  /// rate inside an invisible window for the rest of the process's life, and the
  /// model carries stale state into the next use. Both windows are cheap to
  /// rebuild on the next show, which also re-snaps them to the stored frame.
  private func teardownWindows() {
    configureSourceTracking(nil)
    pendingInteractionReset?.cancel()
    pendingInteractionReset = nil
    model.isInteracting = false
    if window != nil { flushFrameSave() }
    window?.delegate = nil
    window?.orderOut(nil)
    window = nil
    if let resultWindow { savedResultWindowFrame = resultWindow.frame }
    resultWindow?.orderOut(nil)
    resultWindow = nil
  }

  /// `windowDidMove` has no will-start / did-end pair, so debounce a reset
  /// instead. 150 ms is short enough to feel responsive once the drag ends
  /// but long enough that the lines don't pop in/out mid-drag.
  private func markInteracting() {
    pendingInteractionReset?.cancel()
    beginInteraction()
    pendingInteractionReset = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      endInteraction()
    }
  }

  private func beginInteraction() {
    guard model.isLive, !model.isInteracting else { return }
    // Hide synchronously with the event, before the reducer round trip.
    model.isInteracting = true
    eventHandler?(.sourceInteractionBegan)
  }

  private func endInteraction() {
    guard model.isInteracting else { return }
    flushFrameSave()
    // Never reveal the pre-gesture snapshot while waiting for a fresh capture.
    model.lines = []
    model.backdrop = nil
    model.isInteracting = false
    eventHandler?(.sourceInteractionEnded)
  }

  private func scheduleFrameSave() {
    guard let window else { return }
    let frame = window.frame
    pendingFrameSaveTask?.cancel()
    pendingFrameSaveTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .milliseconds(200))
      guard !Task.isCancelled, let self else { return }
      $overlayFrame.withLock { $0.updateGeometry(frame) }
    }
  }

  private func flushFrameSave() {
    pendingFrameSaveTask?.cancel()
    pendingFrameSaveTask = nil
    guard let window else { return }
    $overlayFrame.withLock { $0.updateGeometry(window.frame) }
  }

  /// Window-server ordering keeps the overlay immediately above its source,
  /// below occluding windows. No Accessibility access or focus activation is
  /// needed. Geometry polling is independent of OCR and adaptive image cadence.
  private func configureSourceTracking(_ id: CGWindowID?) {
    guard trackedWindowID != id else { return }
    sourceTrackingTask?.cancel()
    sourceTrackingTask = nil
    trackedWindowID = id
    trackedFrame = nil
    didResolveTrackedWindow = false
    minimumSourceGeneration = 0
    guard let id else {
      window?.level = .floating
      window?.isFloatingPanel = true
      return
    }
    sourceTrackingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        guard self != nil else { return }
        self?.refreshSourceWindow(id)
        do { try await Task.sleep(for: .milliseconds(100)) }
        catch { return }
      }
    }
  }

  private func refreshSourceWindow(_ id: CGWindowID) {
    guard trackedWindowID == id, let window else { return }
    let source = onScreenWindows(excludingPID: ProcessInfo.processInfo.processIdentifier).first { $0.id == id }
    let frame = source?.frame
    if
      source == nil,
      windowIsKnownToServer(id) == false
    {
      model.lines = []
      model.backdrop = nil
      window.orderOut(nil)
      configureSourceTracking(nil)
      eventHandler?(.sourceWindowClosed(id: id))
      return
    }
    if !didResolveTrackedWindow || trackedFrame != frame {
      if didResolveTrackedWindow {
        minimumSourceGeneration = max(minimumSourceGeneration, (lastState?.captureGeneration ?? 0) + 1)
        model.lines = []
        model.backdrop = nil
      }
      didResolveTrackedWindow = true
      trackedFrame = frame
      eventHandler?(.sourceWindowGeometryChanged(id: id, frame: frame))
    }
    guard let frame else {
      window.orderOut(nil)
      return
    }
    if window.frame != frame {
      isPlacingWindow = true
      window.setFrame(frame, display: true)
      isPlacingWindow = false
    }
    window.level = .normal
    window.isFloatingPanel = false
    window.order(.above, relativeTo: Int(id))
  }

  private func showWindowIfNeeded() {
    if window != nil { return }

    let panel = OverlayPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
      styleMask: [.borderless, .resizable, .fullSizeContentView, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    // Movement belongs to the SwiftUI WindowDragGesture on the move handle;
    // never move on a plain background drag.
    panel.isMovableByWindowBackground = false
    panel.isMovable = true
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = model.tracksSourceWindow ? .normal : .floating
    panel.isFloatingPanel = !model.tracksSourceWindow
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
    // Keep the hosting surface genuinely transparent. Clipping this layer to a
    // rounded rectangle exposed a compositing edge in in-place mode.
    hosting.wantsLayer = true
    hosting.layer?.backgroundColor = NSColor.clear.cgColor
    hosting.layer?.masksToBounds = false
    panel.contentView = hosting
    window = panel
  }

  /// The overlay always lets mouse interaction reach the apps below — except in
  /// a thin margin around the edges, the top-left move handle, and the top-right
  /// control cluster. We can't express that with a static
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
    let global = NSEvent.addGlobalMonitorForEvents(matching: [
      .mouseMoved,
      .leftMouseDragged,
      .scrollWheel,
    ]) { [weak self] event in
      MainActor.assumeIsolated {
        self?.updatePassThroughForCursor()
        self?.sourceContentInteracted(event)
      }
    }
    let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .scrollWheel]) { [weak self] event in
      MainActor.assumeIsolated {
        self?.updatePassThroughForCursor()
        if event.type == .scrollWheel { self?.sourceContentInteracted(event) }
      }
      return event
    }
    resizeEdgeMonitors = [global, local].compactMap { $0 }
  }

  private func sourceContentInteracted(_ event: NSEvent) {
    guard
      model.isLive,
      event.type == .scrollWheel || event.type == .leftMouseDragged,
      window?.frame.contains(NSEvent.mouseLocation) == true
    else { return }
    if let trackedWindowID {
      // A selected source belongs to another process. Local scroll events
      // belong to our controls/settings/result window, never that source.
      guard event.window == nil else { return }
      let windows = onScreenWindows(excludingPID: ProcessInfo.processInfo.processIdentifier)
      guard windowUnderCursor(windows, at: NSEvent.mouseLocation)?.id == trackedWindowID else { return }
    }
    // Includes trackpad momentum and scrollbar dragging. Coalesce the gesture
    // into one cancellation and one immediate capture after it settles.
    markInteracting()
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
    if !model.tracksSourceWindow, moveZone.contains(mouse) {
      window.alphaValue = 1
      window.ignoresMouseEvents = false
      return
    }

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

    // Edges stay interactive for resizing.
    let withinX = mouse.x >= frame.minX - resizeMargin && mouse.x <= frame.maxX + resizeMargin
    let withinY = mouse.y >= frame.minY - resizeMargin && mouse.y <= frame.maxY + resizeMargin
    let nearHorizontalEdge = min(abs(mouse.x - frame.minX), abs(mouse.x - frame.maxX)) < resizeMargin
    let nearVerticalEdge = min(abs(mouse.y - frame.minY), abs(mouse.y - frame.maxY)) < resizeMargin
    if !model.tracksSourceWindow, withinX, withinY, nearHorizontalEdge || nearVerticalEdge {
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
    panel.setAccessibilityIdentifier("live-translation-result")
    let hosting = NSHostingView(rootView: LiveResultView(model: model))
    panel.contentView = hosting
    resultWindow = panel
    sizeResultWindow(panel)
    panel.orderFront(nil)
  }

  /// Restore the user's layout across hide/show. Only the first detached window
  /// is sized from the captured region and placed at the screen's bottom-right.
  private func sizeResultWindow(_ panel: NSPanel) {
    let screen = window?.screen ?? NSScreen.main
    let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    if let savedResultWindowFrame {
      let screens = NSScreen.screens.map(\.visibleFrame)
      panel.setFrame(Self.restoredResultFrame(savedResultWindowFrame, screens: screens, defaultScreen: visible), display: true)
      return
    }
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
  var tracksSourceWindow = false
  var isInteracting = false
  /// Whether the cursor is over the overlay — drives the move handle's
  /// hover-visibility (set from the controller's global cursor tracking).
  var cursorInside = false
  var isLive = false
  var isTranslating = false
  var liveMode = OverlayLiveMode.inPlace
  var backdrop: OverlayBackdrop?
  var imageSize = CGSize.zero
  var translationUnavailable = false
  var isPreparingRecognition = false
  var lastError: String?

  /// In Window mode while live, the overlay is just a thin region frame and the
  /// translation lives in a detached window.
  var isWindowFrame: Bool {
    liveMode == .window && isLive
  }
}

// MARK: - OverlayRootView

private struct OverlayRootView: View {

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
      lastError: model.lastError,
      isPreparingRecognition: model.isPreparingRecognition,
      frameOnly: model.isWindowFrame,
      showMoveHandle: model.cursorInside,
      allowsRepositioning: !model.tracksSourceWindow,
      onToggleLive: onToggleLive,
      onClose: onClose
    )
    .background {
      // Hidden affordances: ⌘, opens Settings, ⌘C copies the translated text.
      // This view is a detached AppKit hosting view with no scene environment,
      // so it can't call `openWindow`; posting the notification lets the always-
      // mounted menu-bar label open the settings window on its behalf.
      Group {
        Button("Open Settings") {
          NotificationCenter.default.post(name: .openSettingsWindow, object: nil)
        }
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

}

// MARK: - LiveResultView

/// The detached translation window shown in Window live mode: the captured
/// backdrop with in-place source restoration and replacement text,
/// updating live.
private struct LiveResultView: View {

  // MARK: Internal

  let model: OverlayWindowModel

  var body: some View {
    content
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .safeAreaInset(edge: .bottom, spacing: 0) {
        if model.translationUnavailable {
          TranslationModelHint(message: model.lastError)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
            .transition(.opacity)
        } else {
          CaptureStatusNote(lines: model.lines).padding(8)
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
    if !model.isInteracting, let backdrop = model.backdrop {
      ZStack {
        LiveBackdropImage(backdrop: backdrop)
          .equatable()
        TranslationOverlayLayer(lines: model.lines)
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

// MARK: - LiveBackdropImage

/// Keeps line-by-line translation responses from rebuilding the unchanged
/// capture layer. Only a genuinely new capture invalidates this subtree.
private struct LiveBackdropImage: Equatable, View {
  let backdrop: OverlayBackdrop

  var body: some View {
    Image(decorative: backdrop.image, scale: 1)
      .resizable()
  }
}
