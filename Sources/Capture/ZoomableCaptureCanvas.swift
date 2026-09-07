// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI

// MARK: - CaptureZoomGeometry

/// Capture geometry is always measured in source pixels. A 100% zoom maps one
/// source pixel to one display pixel, including on Retina displays.
enum CaptureZoomGeometry {
  static let maximumScale: CGFloat = 8

  static func fitScale(image: CGSize, viewport: CGSize, backingScale: CGFloat) -> CGFloat? {
    guard
      image.width.isFinite, image.height.isFinite,
      viewport.width.isFinite, viewport.height.isFinite,
      image.width > 0, image.height > 0, viewport.width > 0, viewport.height > 0,
      backingScale.isFinite, backingScale > 0
    else { return nil }
    return min(1, min(viewport.width / image.width, viewport.height / image.height) * backingScale)
  }

  static func normalizedCenter(of rect: CGRect, in size: CGSize) -> CGPoint {
    guard size.width > 0, size.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
    return CGPoint(x: rect.midX / size.width, y: rect.midY / size.height)
  }

  static func scrollOrigin(center: CGPoint, visibleSize: CGSize, documentSize: CGSize) -> CGPoint {
    func coordinate(_ center: CGFloat, visible: CGFloat, document: CGFloat) -> CGFloat {
      if document <= visible { return (document - visible) / 2 }
      return max(0, min(document - visible, center * document - visible / 2))
    }
    return CGPoint(
      x: coordinate(center.x, visible: visibleSize.width, document: documentSize.width),
      y: coordinate(center.y, visible: visibleSize.height, document: documentSize.height)
    )
  }

}

// MARK: - CaptureZoomModel

/// Presentation state belongs to this result window, independently of capture,
/// translation, and persisted settings.
@MainActor
@Observable
final class CaptureZoomModel {

  // MARK: Internal

  private(set) var scale: CGFloat = 1
  private(set) var minimumScale: CGFloat = 0.1
  private(set) var isFitting = true

  var percentage: Int {
    Int((scale * 100).rounded())
  }

  var canZoomIn: Bool {
    scale < CaptureZoomGeometry.maximumScale - 0.001
  }

  var canZoomOut: Bool {
    scale > minimumScale + 0.001
  }

  func zoomIn() {
    command?(.scale(scale * 1.25))
  }

  func zoomOut() {
    command?(.scale(scale / 1.25))
  }

  func resetToFit() {
    command?(.fit)
  }

  // MARK: Fileprivate

  fileprivate enum Command {
    case scale(CGFloat)
    case fit
  }

  fileprivate var command: ((Command) -> Void)?

  fileprivate func update(scale: CGFloat, minimumScale: CGFloat, isFitting: Bool) {
    self.scale = scale
    self.minimumScale = minimumScale
    self.isFitting = isFitting
  }
}

// MARK: - ZoomableCaptureCanvas

/// AppKit owns pinch, two-axis scrolling, momentum, natural-scroll direction,
/// and scrollbars. SwiftUI owns the unchanged, source-sized image document.
struct ZoomableCaptureCanvas<Content: View>: NSViewRepresentable {
  @MainActor
  final class Coordinator {

    // MARK: Lifecycle

    init(model: CaptureZoomModel) {
      self.model = model
    }

    // MARK: Internal

    var imageSize = CGSize.zero
    var backingScale: CGFloat = 1
    var hostingView: NSHostingView<Content>?

    func connect(to scrollView: CaptureScrollView) {
      model.command = { [weak self, weak scrollView] command in
        guard let self, let scrollView else { return }
        switch command {
        case .fit:
          isFitting = true
          layoutDocument(in: scrollView, force: true)

        case .scale(let scale):
          isFitting = false
          setScale(scale, center: center(in: scrollView), in: scrollView)
        }
      }
    }

    func layoutDocument(in scrollView: CaptureScrollView, force: Bool = false) {
      guard let hostingView else { return }
      let viewport = scrollView.contentSize
      let displayScale = scrollView.window?.backingScaleFactor ?? backingScale
      guard let fit = CaptureZoomGeometry.fitScale(image: imageSize, viewport: viewport, backingScale: displayScale)
      else { return }
      let imageChanged = hostingView.frame.size != imageSize
      guard force || imageChanged || viewport != lastViewport || displayScale != lastBackingScale else { return }

      let preservedCenter = scrollView.takePendingCenter() ?? center(in: scrollView)
      let nativeScale = scrollView.magnification * lastBackingScale
      if imageChanged { isFitting = true }
      lastViewport = viewport
      lastBackingScale = displayScale
      minimumScale = min(0.1, fit)
      hostingView.frame = CGRect(origin: .zero, size: imageSize)
      hostingView.layoutSubtreeIfNeeded()
      updateMagnificationRange(in: scrollView)
      setScale(
        isFitting ? fit : nativeScale,
        center: isFitting ? CGPoint(x: 0.5, y: 0.5) : preservedCenter,
        in: scrollView
      )
    }

    func magnificationChanged(in scrollView: CaptureScrollView) {
      isFitting = false
      model.update(
        scale: scrollView.magnification * lastBackingScale,
        minimumScale: minimumScale,
        isFitting: false
      )
    }

    // MARK: Private

    private let model: CaptureZoomModel
    private var lastViewport = CGSize.zero
    private var lastBackingScale: CGFloat = 1
    private var minimumScale: CGFloat = 0.1
    private var isFitting = true

    private func center(in scrollView: NSScrollView) -> CGPoint {
      CaptureZoomGeometry.normalizedCenter(of: scrollView.documentVisibleRect, in: hostingView?.frame.size ?? .zero)
    }

    private func setScale(_ scale: CGFloat, center: CGPoint, in scrollView: CaptureScrollView) {
      let clamped = min(CaptureZoomGeometry.maximumScale, max(minimumScale, scale))
      scrollView.setMagnification(clamped / lastBackingScale, centeredAt: CGPoint(
        x: center.x * imageSize.width,
        y: center.y * imageSize.height
      ))
      let origin = CaptureZoomGeometry.scrollOrigin(
        center: center,
        visibleSize: scrollView.documentVisibleRect.size,
        documentSize: imageSize
      )
      scrollView.scrollContent(to: origin)
      model.update(scale: clamped, minimumScale: minimumScale, isFitting: isFitting)
    }

    /// AppKit raises if the bounds cross even momentarily during display changes.
    private func updateMagnificationRange(in scrollView: NSScrollView) {
      let lower = minimumScale / lastBackingScale
      let upper = CaptureZoomGeometry.maximumScale / lastBackingScale
      if lower > scrollView.maxMagnification {
        scrollView.maxMagnification = upper
        scrollView.minMagnification = lower
      } else {
        scrollView.minMagnification = lower
        scrollView.maxMagnification = upper
      }
    }
  }

  let imageSize: CGSize
  let backingScale: CGFloat
  let model: CaptureZoomModel
  @ViewBuilder let content: Content

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> CaptureScrollView {
    let scrollView = CaptureScrollView()
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.001
    scrollView.maxMagnification = CaptureZoomGeometry.maximumScale
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true
    scrollView.scrollerStyle = .overlay
    scrollView.usesPredominantAxisScrolling = false
    let clip = CenteringCaptureClipView()
    clip.drawsBackground = false
    scrollView.contentView = clip
    scrollView.installPanGesture()
    let hosting = NSHostingView(rootView: content)
    hosting.sizingOptions = []
    hosting.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    scrollView.documentView = hosting
    context.coordinator.hostingView = hosting
    context.coordinator.connect(to: scrollView)
    scrollView.onLayout = { [weak coordinator = context.coordinator, weak scrollView] in
      guard let scrollView else { return }
      coordinator?.layoutDocument(in: scrollView)
    }
    scrollView.onMagnificationChanged = { [weak coordinator = context.coordinator, weak scrollView] in
      guard let scrollView else { return }
      coordinator?.magnificationChanged(in: scrollView)
    }
    return scrollView
  }

  func updateNSView(_ scrollView: CaptureScrollView, context: Context) {
    context.coordinator.imageSize = imageSize
    context.coordinator.backingScale = backingScale
    context.coordinator.hostingView?.rootView = content
    scrollView.needsLayout = true
  }
}

// MARK: - CaptureScrollView

final class CaptureScrollView: NSScrollView {

  // MARK: Internal

  var onLayout: (() -> Void)?
  var onMagnificationChanged: (() -> Void)?

  func installPanGesture() {
    let pan = NSPanGestureRecognizer(target: self, action: #selector(panImage(_:)))
    pan.buttonMask = 1
    contentView.addGestureRecognizer(pan)
  }

  override func setFrameSize(_ newSize: NSSize) {
    if frame.size != newSize { preserveCenter() }
    super.setFrameSize(newSize)
  }

  override func viewDidChangeBackingProperties() {
    preserveCenter()
    super.viewDidChangeBackingProperties()
    needsLayout = true
  }

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    onMagnificationChanged?()
  }

  /// NSClipView.scroll(to:) itself does not constrain programmatic panning.
  func scrollContent(to origin: CGPoint) {
    var proposed = contentView.bounds
    proposed.origin = origin
    contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
    reflectScrolledClipView(contentView)
  }

  func takePendingCenter() -> CGPoint? {
    defer { pendingCenter = nil }
    return pendingCenter
  }

  // MARK: Private

  private var pendingCenter: CGPoint?
  private var panOrigin: CGPoint?

  private func preserveCenter() {
    guard pendingCenter == nil, let documentView else { return }
    pendingCenter = CaptureZoomGeometry.normalizedCenter(of: documentVisibleRect, in: documentView.frame.size)
  }

  @objc
  private func panImage(_ gesture: NSPanGestureRecognizer) {
    switch gesture.state {
    case .began:
      panOrigin = contentView.bounds.origin
      NSCursor.closedHand.push()

    case .changed:
      guard let panOrigin else { return }
      let translation = gesture.translation(in: contentView)
      scrollContent(to: CGPoint(x: panOrigin.x - translation.x, y: panOrigin.y - translation.y))

    case .ended,
         .cancelled,
         .failed:
      if panOrigin != nil { NSCursor.pop() }
      panOrigin = nil

    default:
      break
    }
  }
}

// MARK: - CenteringCaptureClipView

/// Center documents smaller than the viewport while allowing native scrolling
/// and edge constraints once the image is larger.
final class CenteringCaptureClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var result = super.constrainBoundsRect(proposedBounds)
    guard let documentView else { return result }
    if documentView.frame.width < result.width {
      result.origin.x = (documentView.frame.width - result.width) / 2
    }
    if documentView.frame.height < result.height {
      result.origin.y = (documentView.frame.height - result.height) / 2
    }
    return result
  }
}
