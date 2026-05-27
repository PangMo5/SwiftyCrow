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

  func update(
    lines: [CaptureFeature.OverlayLine],
    isVisible: Bool,
    hideOnHover: Bool,
    isTranslating: Bool,
    isLive: Bool
  ) {
    model.lines = lines
    model.hideOnHover = hideOnHover
    model.isTranslating = isTranslating
    model.isLive = isLive

    if isVisible {
      let needsInitialFrame = window == nil || !(window?.isVisible ?? false)
      showWindowIfNeeded()
      if let window {
        // Only sync the panel back to the stored settings frame when we're
        // first showing it. After that the user's drag/resize is the source
        // of truth and forcing setFrame here would snap the window back
        // mid-translation.
        if needsInitialFrame {
          window.setFrame(settings.overlayFrame.rect, display: true)
          window.makeKeyAndOrderFront(nil)
        }
      }
    } else {
      window?.orderOut(nil)
    }
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

  @Shared(.settings) private var settings

  private let model = OverlayWindowModel()
  private var hoverMonitor: Any?
  private var isHiddenForHover = false
  private var pendingFrameSaveTask: Task<Void, Never>?
  private var pendingInteractionReset: Task<Void, Never>?
  private var window: OverlayPanel?

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
      $settings.withLock { $0.overlayFrame = OverlayFrame(rect: frame) }
    }
  }

  private func flushFrameSave() {
    pendingFrameSaveTask?.cancel()
    pendingFrameSaveTask = nil
    guard let window else { return }
    $settings.withLock { $0.overlayFrame = OverlayFrame(rect: window.frame) }
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
    window.ignoresMouseEvents = false
    stopHoverMonitor()
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
}

// MARK: - OverlayWindowModel

private final class OverlayWindowModel: ObservableObject {
  @Published var lines = [CaptureFeature.OverlayLine]()
  @Published var hideOnHover = false
  @Published var isInteracting = false
  @Published var isLive = false
  @Published var isTranslating = false
}

// MARK: - OverlayRootView

private struct OverlayRootView: View {

  // MARK: Internal

  @ObservedObject var model: OverlayWindowModel

  let onHover: (Bool) -> Void

  var body: some View {
    OverlayView(
      lines: model.isInteracting ? [] : model.lines,
      isTranslating: model.isTranslating,
      isLive: model.isLive
    )
    .onHover { hovering in
      onHover(hovering)
    }
    .background {
      // Hidden affordances: ⌘, opens Settings, ⌘C copies the translated text.
      Group {
        Button("Open Settings") { openSettings() }
          .keyboardShortcut(",", modifiers: .command)
        Button("Copy translation") {
          appStore.send(.capture(.copyTranslationRequested))
        }
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
