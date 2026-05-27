import AppKit
import ComposableArchitecture
import DependenciesMacros

// MARK: - RegionSelectorClient

@DependencyClient
struct RegionSelectorClient {
  /// Presents a full-screen drag-to-select overlay. Returns the chosen rect in
  /// global AppKit screen coordinates (points, bottom-left origin), or nil if
  /// the user cancels (Escape or a zero-size drag).
  var selectRegion: @Sendable () async -> CGRect?
}

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
      selectRegion: { await resolve().selectRegion() }
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

  func selectRegion() async -> CGRect? {
    // Tear down any selector still on screen from a previous, abandoned call.
    finish(nil)
    return await withCheckedContinuation { continuation in
      present(continuation)
    }
  }

  // MARK: Private

  private var panel: SelectorPanel?
  private var continuation: CheckedContinuation<CGRect?, Never>?

  private func present(_ continuation: CheckedContinuation<CGRect?, Never>) {
    let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    guard !unionFrame.isNull else {
      continuation.resume(returning: nil)
      return
    }

    let panel = SelectorPanel(
      contentRect: unionFrame,
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

    let view = SelectionView(unionOrigin: unionFrame.origin) { [weak self] rect in
      self?.finish(rect)
    }
    view.frame = CGRect(origin: .zero, size: unionFrame.size)
    panel.contentView = view

    self.continuation = continuation
    self.panel = panel
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    panel.makeFirstResponder(view)
  }

  private func finish(_ rect: CGRect?) {
    panel?.orderOut(nil)
    panel = nil
    continuation?.resume(returning: rect)
    continuation = nil
  }
}

// MARK: - SelectorPanel

private final class SelectorPanel: NSPanel {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
}

// MARK: - SelectionView

private final class SelectionView: NSView {

  // MARK: Lifecycle

  init(unionOrigin: CGPoint, onFinish: @escaping (CGRect?) -> Void) {
    self.unionOrigin = unionOrigin
    self.onFinish = onFinish
    super.init(frame: .zero)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Internal

  override var acceptsFirstResponder: Bool { true }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseDown(with event: NSEvent) {
    startPoint = convert(event.locationInWindow, from: nil)
    selection = .zero
    needsDisplay = true
  }

  override func mouseDragged(with event: NSEvent) {
    guard let start = startPoint else { return }
    let point = convert(event.locationInWindow, from: nil)
    selection = CGRect(
      x: min(start.x, point.x),
      y: min(start.y, point.y),
      width: abs(point.x - start.x),
      height: abs(point.y - start.y)
    )
    needsDisplay = true
  }

  override func mouseUp(with event: NSEvent) {
    defer { startPoint = nil }
    // A click or a tiny drag means "never mind".
    guard selection.width >= 8, selection.height >= 8 else {
      onFinish(nil)
      return
    }
    // Convert from view-local (origin at union's bottom-left) to global.
    let global = CGRect(
      x: unionOrigin.x + selection.minX,
      y: unionOrigin.y + selection.minY,
      width: selection.width,
      height: selection.height
    )
    onFinish(global)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { // Escape
      onFinish(nil)
    } else {
      super.keyDown(with: event)
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.black.withAlphaComponent(0.28).setFill()
    bounds.fill()

    guard selection.width > 0, selection.height > 0 else { return }
    // Punch the selection clear so the live screen shows through.
    selection.fill(using: .clear)

    let border = NSBezierPath(rect: selection)
    border.lineWidth = 1.5
    NSColor.controlAccentColor.setStroke()
    border.stroke()
  }

  // MARK: Private

  private let unionOrigin: CGPoint
  private let onFinish: (CGRect?) -> Void
  private var startPoint: CGPoint?
  private var selection: CGRect = .zero
}
