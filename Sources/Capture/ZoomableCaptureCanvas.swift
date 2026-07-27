import AppKit
import SwiftUI

// MARK: - CaptureZoomGeometry

/// Pure geometry shared by the AppKit canvas and its unit tests.
enum CaptureZoomGeometry {
  static let magnificationRange: ClosedRange<CGFloat> = 1...6
  static let maximumOversampledArea: CGFloat = 16_000_000

  /// Keep enough backing detail for a useful first zoom step on 1x displays.
  /// Retina displays already provide this density without a larger document.
  static func detailScale(forBackingScale backingScale: CGFloat) -> CGFloat {
    guard backingScale.isFinite, backingScale > 0 else { return 1 }
    return max(1, 2 / backingScale)
  }

  static func detailedDocumentSize(_ source: CGSize, backingScale: CGFloat) -> CGSize {
    guard
      source.width.isFinite,
      source.height.isFinite,
      source.width > 0,
      source.height > 0
    else { return .zero }

    let requestedScale = detailScale(forBackingScale: backingScale)
    let areaLimitedScale = (maximumOversampledArea / (source.width * source.height)).squareRoot()
    let scale = max(1, min(requestedScale, areaLimitedScale))
    return CGSize(width: source.width * scale, height: source.height * scale)
  }

  static func fitMagnification(_ source: CGSize, in destination: CGSize) -> CGFloat {
    guard
      source.width.isFinite,
      source.height.isFinite,
      destination.width.isFinite,
      destination.height.isFinite,
      source.width > 0,
      source.height > 0,
      destination.width > 0,
      destination.height > 0
    else { return 0 }

    return min(destination.width / source.width, destination.height / source.height)
  }

  static func aspectFit(_ source: CGSize, in destination: CGSize) -> CGSize {
    let ratio = fitMagnification(source, in: destination)
    guard ratio > 0 else { return .zero }
    return CGSize(width: source.width * ratio, height: source.height * ratio)
  }

  static func clampedMagnification(_ value: CGFloat) -> CGFloat {
    guard value.isFinite else { return magnificationRange.lowerBound }
    return min(magnificationRange.upperBound, max(magnificationRange.lowerBound, value))
  }

  static func normalizedCenter(of visibleRect: CGRect, in documentSize: CGSize) -> CGPoint {
    guard documentSize.width > 0, documentSize.height > 0 else {
      return CGPoint(x: 0.5, y: 0.5)
    }
    return CGPoint(
      x: min(1, max(0, visibleRect.midX / documentSize.width)),
      y: min(1, max(0, visibleRect.midY / documentSize.height))
    )
  }

  static func scrollOrigin(
    preserving normalizedCenter: CGPoint,
    visibleSize: CGSize,
    documentSize: CGSize
  ) -> CGPoint {
    let maximum = CGPoint(
      x: max(0, documentSize.width - visibleSize.width),
      y: max(0, documentSize.height - visibleSize.height)
    )
    return CGPoint(
      x: min(maximum.x, max(0, normalizedCenter.x * documentSize.width - visibleSize.width / 2)),
      y: min(maximum.y, max(0, normalizedCenter.y * documentSize.height - visibleSize.height / 2))
    )
  }
}

// MARK: - CaptureZoomModel

/// View-local controls for a capture result's native AppKit scroll view. Zoom
/// and pan are presentation state, so they intentionally do not live in TCA or
/// the persisted app settings.
@MainActor
@Observable
final class CaptureZoomModel {

  // MARK: Internal

  private(set) var relativeScale: CGFloat = 1

  var percentage: Int {
    Int((relativeScale * 100).rounded())
  }

  func resetToFit() {
    command?(.fit)
  }

  func zoomIn() {
    command?(.zoomIn)
  }

  func zoomOut() {
    command?(.zoomOut)
  }

  // MARK: Fileprivate

  fileprivate enum Command {
    case fit
    case zoomIn
    case zoomOut
  }

  fileprivate var command: ((Command) -> Void)?

  fileprivate func update(relativeScale: CGFloat) {
    self.relativeScale = relativeScale
  }
}

// MARK: - ZoomableCaptureCanvas

/// Hosts the complete capture result in `NSScrollView` so two-finger panning,
/// pinch magnification, momentum, and the user's natural-scrolling preference
/// are all handled by AppKit.
struct ZoomableCaptureCanvas<Content: View>: NSViewRepresentable {

  @MainActor
  final class Coordinator: NSObject {

    // MARK: Lifecycle

    init(model: CaptureZoomModel) {
      self.model = model
    }

    // MARK: Internal

    var imageSize = CGSize.zero
    var hostingView: NSHostingView<Content>?

    func connect(to scrollView: CaptureScrollView) {
      model.command = { [weak self, weak scrollView] command in
        guard let self, let scrollView else { return }
        apply(command, to: scrollView)
      }
    }

    func layoutDocument(in scrollView: CaptureScrollView) {
      guard
        imageSize.width > 0,
        imageSize.height > 0,
        let hostingView
      else { return }

      let viewport = scrollView.contentSize
      guard viewport.width > 1, viewport.height > 1 else { return }
      let nextFitMagnification = CaptureZoomGeometry.fitMagnification(imageSize, in: viewport)
      guard nextFitMagnification > 0 else { return }

      let previousDocumentSize = hostingView.frame.size
      let previousFitMagnification = fitMagnification
      let currentRelativeScale = previousFitMagnification > 0
        ? scrollView.magnification / previousFitMagnification
        : model.relativeScale
      let preservedCenter = scrollView.takePendingNormalizedCenter()
      let documentChanged = previousDocumentSize != imageSize
      let fitChanged = abs(previousFitMagnification - nextFitMagnification) > 0.0001
      guard documentChanged || fitChanged else {
        return
      }

      let visible = scrollView.documentVisibleRect
      let normalizedCenter = preservedCenter
        ?? CaptureZoomGeometry.normalizedCenter(of: visible, in: previousDocumentSize)
      let relativeScale = CaptureZoomGeometry.clampedMagnification(currentRelativeScale)
      let wasFit = abs(relativeScale - CaptureZoomGeometry.magnificationRange.lowerBound) < 0.001

      fitMagnification = nextFitMagnification
      scrollView.fitMagnification = nextFitMagnification
      updateMagnificationRange(for: nextFitMagnification, in: scrollView)
      hostingView.frame = CGRect(origin: .zero, size: imageSize)
      hostingView.layoutSubtreeIfNeeded()

      let targetRelativeScale = wasFit ? CaptureZoomGeometry.magnificationRange.lowerBound : relativeScale
      let targetCenter = wasFit ? CGPoint(x: 0.5, y: 0.5) : normalizedCenter
      setMagnification(
        nextFitMagnification * targetRelativeScale,
        preserving: targetCenter,
        in: scrollView
      )
      model.update(relativeScale: targetRelativeScale)
    }

    func magnificationChanged(_ magnification: CGFloat) {
      guard fitMagnification > 0 else { return }
      model.update(relativeScale: CaptureZoomGeometry.clampedMagnification(magnification / fitMagnification))
    }

    // MARK: Private

    private let model: CaptureZoomModel
    private var fitMagnification: CGFloat = 1

    /// AppKit raises an Objective-C exception if either bound crosses the
    /// other, even momentarily. Small captures can have a Fit scale above the
    /// previous 6x maximum, while a later large capture can move both bounds
    /// below the previous minimum, so update the outward bound first.
    private func updateMagnificationRange(for fitMagnification: CGFloat, in scrollView: NSScrollView) {
      let minimum = fitMagnification * CaptureZoomGeometry.magnificationRange.lowerBound
      let maximum = fitMagnification * CaptureZoomGeometry.magnificationRange.upperBound

      if minimum > scrollView.maxMagnification {
        scrollView.maxMagnification = maximum
        scrollView.minMagnification = minimum
      } else if maximum < scrollView.minMagnification {
        scrollView.minMagnification = minimum
        scrollView.maxMagnification = maximum
      } else {
        scrollView.minMagnification = minimum
        scrollView.maxMagnification = maximum
      }
    }

    private func apply(_ command: CaptureZoomModel.Command, to scrollView: CaptureScrollView) {
      guard fitMagnification > 0 else { return }
      let currentRelativeScale = scrollView.magnification / fitMagnification
      let nextRelativeScale: CGFloat =
        switch command {
        case .fit:
          CaptureZoomGeometry.magnificationRange.lowerBound
        case .zoomIn:
          CaptureZoomGeometry.clampedMagnification(currentRelativeScale * 1.25)
        case .zoomOut:
          CaptureZoomGeometry.clampedMagnification(currentRelativeScale / 1.25)
        }
      let normalizedCenter = CaptureZoomGeometry.normalizedCenter(
        of: scrollView.documentVisibleRect,
        in: scrollView.documentView?.frame.size ?? .zero
      )
      setMagnification(fitMagnification * nextRelativeScale, preserving: normalizedCenter, in: scrollView)
      model.update(relativeScale: nextRelativeScale)
    }

    private func setMagnification(
      _ magnification: CGFloat,
      preserving normalizedCenter: CGPoint,
      in scrollView: CaptureScrollView
    ) {
      let currentCenter = CGPoint(
        x: scrollView.documentVisibleRect.midX,
        y: scrollView.documentVisibleRect.midY
      )
      scrollView.setMagnification(magnification, centeredAt: currentCenter)
      guard let documentView = scrollView.documentView else { return }
      let origin = CaptureZoomGeometry.scrollOrigin(
        preserving: normalizedCenter,
        visibleSize: scrollView.documentVisibleRect.size,
        documentSize: documentView.frame.size
      )
      scrollView.contentView.scroll(to: origin)
      scrollView.reflectScrolledClipView(scrollView.contentView)
    }

  }

  let imageSize: CGSize
  let model: CaptureZoomModel
  @ViewBuilder let content: Content

  func makeCoordinator() -> Coordinator {
    Coordinator(model: model)
  }

  func makeNSView(context: Context) -> CaptureScrollView {
    let scrollView = CaptureScrollView()
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.01
    scrollView.maxMagnification = CaptureZoomGeometry.magnificationRange.upperBound
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    scrollView.hasHorizontalScroller = true
    scrollView.hasVerticalScroller = true
    scrollView.horizontalScrollElasticity = .automatic
    scrollView.verticalScrollElasticity = .automatic
    scrollView.scrollerStyle = .overlay
    scrollView.usesPredominantAxisScrolling = false

    let clipView = CenteringClipView()
    clipView.drawsBackground = false
    scrollView.contentView = clipView

    let hostingView = NSHostingView(rootView: content)
    hostingView.frame = CGRect(origin: .zero, size: CGSize(width: 1, height: 1))
    scrollView.documentView = hostingView
    scrollView.onMagnificationChanged = { [weak coordinator = context.coordinator] magnification in
      coordinator?.magnificationChanged(magnification)
    }
    scrollView.onLayout = { [weak coordinator = context.coordinator, weak scrollView] in
      guard let scrollView else { return }
      coordinator?.layoutDocument(in: scrollView)
    }
    context.coordinator.hostingView = hostingView
    context.coordinator.connect(to: scrollView)
    return scrollView
  }

  func updateNSView(_ scrollView: CaptureScrollView, context: Context) {
    context.coordinator.imageSize = imageSize
    context.coordinator.hostingView?.rootView = content
    context.coordinator.layoutDocument(in: scrollView)
  }

}

// MARK: - CaptureScrollView

final class CaptureScrollView: NSScrollView {

  // MARK: Internal

  var onLayout: (() -> Void)?
  var onMagnificationChanged: ((CGFloat) -> Void)?
  var fitMagnification: CGFloat = 1

  override func setFrameSize(_ newSize: NSSize) {
    if
      pendingNormalizedCenter == nil,
      magnification > fitMagnification * (CaptureZoomGeometry.magnificationRange.lowerBound + 0.001),
      frame.size != newSize,
      let documentView,
      documentView.frame.width > 0,
      documentView.frame.height > 0
    {
      pendingNormalizedCenter = CaptureZoomGeometry.normalizedCenter(
        of: documentVisibleRect,
        in: documentView.frame.size
      )
    }
    super.setFrameSize(newSize)
  }

  override func layout() {
    super.layout()
    onLayout?()
  }

  override func magnify(with event: NSEvent) {
    super.magnify(with: event)
    onMagnificationChanged?(magnification)
  }

  // MARK: Fileprivate

  fileprivate func takePendingNormalizedCenter() -> CGPoint? {
    defer { pendingNormalizedCenter = nil }
    return pendingNormalizedCenter
  }

  // MARK: Private

  private var pendingNormalizedCenter: CGPoint?
}

// MARK: - CenteringClipView

/// Centers a fitted document while retaining NSClipView's native scrolling and
/// gesture behavior as soon as magnification makes the document larger.
private final class CenteringClipView: NSClipView {
  override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
    var constrained = super.constrainBoundsRect(proposedBounds)
    guard let documentView else { return constrained }

    if documentView.frame.width < bounds.width {
      constrained.origin.x = (documentView.frame.width - bounds.width) / 2
    }
    if documentView.frame.height < bounds.height {
      constrained.origin.y = (documentView.frame.height - bounds.height) / 2
    }
    return constrained
  }
}
