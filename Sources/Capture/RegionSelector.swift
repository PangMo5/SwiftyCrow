import AppKit
import ComposableArchitecture
import DependenciesMacros

// MARK: - CaptureTarget

/// What the selector resolved to. A drag yields a free-form region; the
/// window-highlight mode yields a specific window (with its id, so capture can
/// grab just that window, plus its frame for snapping an overlay onto it).
enum CaptureTarget: Equatable, Sendable {
  case region(CGRect)
  case window(id: CGWindowID, frame: CGRect)

  /// The on-screen rect either target occupies, in global AppKit coordinates.
  var frame: CGRect {
    switch self {
    case .region(let rect): rect
    case .window(_, let frame): frame
    }
  }
}

// MARK: - SelectionMode

/// Which way the selector starts. Space toggles between the two at any time,
/// mirroring the macOS screenshot UI.
enum SelectionMode: Equatable, Sendable {
  case region
  case window
}

// MARK: - RegionSelectorClient

@DependencyClient
struct RegionSelectorClient {
  /// Presents a full-screen selector across every display. In `.region` mode the
  /// user drags a rectangle; in `.window` mode the window under the cursor
  /// highlights and a click picks it. Space toggles modes, Escape cancels.
  /// Returns the chosen target in global AppKit coordinates, or nil if cancelled.
  var selectRegion: @Sendable (_ initialMode: SelectionMode) async -> CaptureTarget?
}

// MARK: DependencyKey

extension RegionSelectorClient: DependencyKey {
  static let liveValue: RegionSelectorClient = {
    // The controller touches AppKit, so build it lazily on the main actor.
    nonisolated(unsafe) var controller: RegionSelectorController?
    @MainActor
    func resolve() -> RegionSelectorController {
      if let controller { return controller }
      let new = RegionSelectorController()
      controller = new
      return new
    }
    return RegionSelectorClient(
      selectRegion: { mode in await resolve().selectRegion(initialMode: mode) }
    )
  }()
}

extension DependencyValues {
  var regionSelector: RegionSelectorClient {
    get { self[RegionSelectorClient.self] }
    set { self[RegionSelectorClient.self] = newValue }
  }
}

// MARK: - RegionSelectorController

@MainActor
private final class RegionSelectorController {

  // MARK: Internal

  /// The mode the selector views read while drawing and handling clicks.
  private(set) var mode = SelectionMode.region
  /// The window currently under the cursor in `.window` mode (global AppKit).
  private(set) var hovered: PickableWindow?

  func selectRegion(initialMode: SelectionMode) async -> CaptureTarget? {
    // Tear down any selector still on screen from a previous, abandoned call.
    finish(nil)
    return await withCheckedContinuation { continuation in
      present(initialMode: initialMode, continuation)
    }
  }

  /// A selector view reports a completed drag (already in global coordinates).
  func reportRegion(_ rect: CGRect?) {
    guard mode == .region else { return }
    finish(rect.map(CaptureTarget.region))
  }

  /// A selector view reports a click in `.window` mode.
  func reportWindowClick() {
    guard mode == .window, let hovered else { return }
    finish(.window(id: hovered.id, frame: hovered.frame))
  }

  // MARK: Private

  private var panels = [SelectorPanel]()
  private var views = [SelectionView]()
  private var continuation: CheckedContinuation<CaptureTarget?, Never>?
  private var windows = [PickableWindow]()
  private var mouseMonitors = [Any]()
  private var keyMonitor: Any?

  private func present(initialMode: SelectionMode, _ continuation: CheckedContinuation<CaptureTarget?, Never>) {
    mode = initialMode
    refreshWindows()

    let cursor = NSEvent.mouseLocation
    var keyPanel: SelectorPanel?
    for screen in NSScreen.screens {
      let panel = SelectorPanel(
        contentRect: screen.frame,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
      )
      panel.level = .screenSaver
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.hasShadow = false
      panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
      panel.ignoresMouseEvents = false
      // The panels cover every screen, so mouse-moved events land on us (not the
      // apps below); the local monitor needs them to track the hovered window.
      panel.acceptsMouseMovedEvents = true

      let view = SelectionView(screen: screen, controller: self)
      view.frame = CGRect(origin: .zero, size: screen.frame.size)
      panel.contentView = view

      panels.append(panel)
      views.append(view)
      panel.orderFrontRegardless()
      if screen.frame.contains(cursor) { keyPanel = panel }
    }

    self.continuation = continuation
    NSApp.activate(ignoringOtherApps: true)
    (keyPanel ?? panels.first)?.makeKey()

    startMonitors()
    refreshHover()
  }

  private func toggleMode() {
    mode = mode == .region ? .window : .region
    if mode == .window {
      refreshWindows()
      refreshHover()
    }
    for view in views { view.resetSelection()
      view.needsDisplay = true
    }
    for panel in panels { panel.invalidateCursorRects(for: panel.contentView!) }
  }

  private func refreshWindows() {
    windows = onScreenWindows(excludingPID: ProcessInfo.processInfo.processIdentifier)
  }

  private func refreshHover() {
    guard mode == .window else { return }
    let next = windowUnderCursor(windows, at: NSEvent.mouseLocation)
    guard next != hovered else { return }
    hovered = next
    for view in views { view.needsDisplay = true }
  }

  private func startMonitors() {
    // Mouse moves/drags update the window highlight without consuming the event,
    // so region-mode drags still reach the view under the cursor.
    let mouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      MainActor.assumeIsolated { self?.refreshHover() }
      return event
    }
    let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshHover() }
    }
    // Space toggles mode; Escape cancels. Consume both so they don't beep.
    let key = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      MainActor.assumeIsolated {
        guard let self else { return event }
        switch event.keyCode {
        case 49: // Space
          self.toggleMode()
          return nil

        case 53: // Escape
          self.finish(nil)
          return nil

        default:
          return event
        }
      }
    }
    mouseMonitors = [mouse, global].compactMap { $0 }
    keyMonitor = key
  }

  private func finish(_ target: CaptureTarget?) {
    mouseMonitors.forEach(NSEvent.removeMonitor)
    mouseMonitors.removeAll()
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
    for panel in panels { panel.orderOut(nil) }
    panels.removeAll()
    views.removeAll()
    hovered = nil
    windows = []
    continuation?.resume(returning: target)
    continuation = nil
  }
}

// MARK: - SelectorPanel

private final class SelectorPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

// MARK: - SelectionView

private final class SelectionView: NSView {

  // MARK: Lifecycle

  init(screen: NSScreen, controller: RegionSelectorController) {
    self.screen = screen
    self.controller = controller
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Internal

  override var acceptsFirstResponder: Bool {
    true
  }

  func resetSelection() {
    startPoint = nil
    selection = .zero
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: controller.mode == .window ? .pointingHand : .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    guard controller.mode == .region else { return }
    startPoint = convert(event.locationInWindow, from: nil)
    selection = .zero
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard controller.mode == .region, let start = startPoint else { return }
    let point = convert(event.locationInWindow, from: nil)
    selection = CGRect(
      x: min(start.x, point.x),
      y: min(start.y, point.y),
      width: abs(point.x - start.x),
      height: abs(point.y - start.y)
    )
    needsDisplay = true
  }

  override func mouseUp(with _: NSEvent) {
    if controller.mode == .window {
      controller.reportWindowClick()
      return
    }
    defer { startPoint = nil }
    // A click or a tiny drag means "never mind".
    guard selection.width >= 8, selection.height >= 8 else {
      controller.reportRegion(nil)
      return
    }
    // Convert from view-local (origin at the screen's bottom-left) to global.
    let global = CGRect(
      x: screen.frame.minX + selection.minX,
      y: screen.frame.minY + selection.minY,
      width: selection.width,
      height: selection.height
    )
    controller.reportRegion(global)
  }

  override func draw(_: NSRect) {
    NSColor.black.withAlphaComponent(0.28).setFill()
    bounds.fill()

    switch controller.mode {
    case .region:
      drawRegionSelection()
    case .window:
      drawWindowHighlight()
    }
  }

  // MARK: Private

  private let screen: NSScreen
  private unowned let controller: RegionSelectorController
  private var startPoint: CGPoint?
  private var selection = CGRect.zero

  private func drawRegionSelection() {
    guard selection.width > 0, selection.height > 0 else { return }
    // Punch the selection clear so the live screen shows through.
    selection.fill(using: .clear)

    let border = NSBezierPath(rect: selection)
    border.lineWidth = 1.5
    NSColor.controlAccentColor.setStroke()
    border.stroke()
  }

  private func drawWindowHighlight() {
    guard let hovered = controller.hovered else { return }
    // The hovered window's rect is global; bring it into this view's local space
    // and bail if it doesn't fall on this screen.
    let local = hovered.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
    guard local.intersects(bounds) else { return }

    local.fill(using: .clear)
    NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
    local.fill()

    let border = NSBezierPath(rect: local)
    border.lineWidth = 2.5
    NSColor.controlAccentColor.setStroke()
    border.stroke()
  }
}
