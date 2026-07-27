import AppKit
import SwiftUI
import XCTest

@testable import SwiftyCrow

final class ZoomableCaptureCanvasTests: XCTestCase {

  @MainActor
  func testCoordinatorFitsDocumentAndRespondsToZoomCommands() {
    let model = CaptureZoomModel()
    let coordinator = ZoomableCaptureCanvas<Color>.Coordinator(model: model)
    let scrollView = CaptureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.01
    scrollView.maxMagnification = CaptureZoomGeometry.magnificationRange.upperBound

    let hostingView = NSHostingView(rootView: Color.clear)
    hostingView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    scrollView.documentView = hostingView
    coordinator.hostingView = hostingView
    coordinator.imageSize = CGSize(width: 800, height: 400)
    coordinator.connect(to: scrollView)

    coordinator.layoutDocument(in: scrollView)

    XCTAssertEqual(hostingView.frame.width, 800, accuracy: 0.01)
    XCTAssertEqual(hostingView.frame.height, 400, accuracy: 0.01)
    XCTAssertEqual(scrollView.magnification, 0.75, accuracy: 0.001)

    model.zoomIn()
    XCTAssertEqual(scrollView.magnification, 0.9375, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 125)

    model.zoomOut()
    XCTAssertEqual(scrollView.magnification, 0.75, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 100)
  }

  @MainActor
  func testCoordinatorClampsToolbarZoomAndRefitsAfterResize() {
    let model = CaptureZoomModel()
    let coordinator = ZoomableCaptureCanvas<Color>.Coordinator(model: model)
    let scrollView = CaptureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.01
    scrollView.maxMagnification = CaptureZoomGeometry.magnificationRange.upperBound

    let hostingView = NSHostingView(rootView: Color.clear)
    hostingView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    scrollView.documentView = hostingView
    coordinator.hostingView = hostingView
    coordinator.imageSize = CGSize(width: 800, height: 400)
    coordinator.connect(to: scrollView)
    coordinator.layoutDocument(in: scrollView)

    for _ in 0..<20 {
      model.zoomIn()
    }
    XCTAssertEqual(scrollView.magnification, 4.5, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 600)

    model.resetToFit()
    scrollView.frame = CGRect(x: 0, y: 0, width: 300, height: 500)
    coordinator.layoutDocument(in: scrollView)

    XCTAssertEqual(scrollView.magnification, 0.375, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 100)
    XCTAssertEqual(hostingView.frame.width, 800, accuracy: 0.01)
    XCTAssertEqual(hostingView.frame.height, 400, accuracy: 0.01)
  }

  @MainActor
  func testCoordinatorPreservesZoomedViewportCenterAfterResize() {
    let model = CaptureZoomModel()
    let coordinator = ZoomableCaptureCanvas<Color>.Coordinator(model: model)
    let scrollView = CaptureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.01
    scrollView.maxMagnification = CaptureZoomGeometry.magnificationRange.upperBound

    let hostingView = NSHostingView(rootView: Color.clear)
    hostingView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    scrollView.documentView = hostingView
    coordinator.hostingView = hostingView
    coordinator.imageSize = CGSize(width: 800, height: 400)
    coordinator.connect(to: scrollView)
    coordinator.layoutDocument(in: scrollView)

    scrollView.setMagnification(1.5, centeredAt: CGPoint(x: 400, y: 200))
    scrollView.contentView.scroll(to: CGPoint(x: 240, y: 50))
    scrollView.reflectScrolledClipView(scrollView.contentView)
    let before = CaptureZoomGeometry.normalizedCenter(
      of: scrollView.documentVisibleRect,
      in: hostingView.frame.size
    )

    scrollView.setFrameSize(CGSize(width: 800, height: 500))
    coordinator.layoutDocument(in: scrollView)
    let after = CaptureZoomGeometry.normalizedCenter(
      of: scrollView.documentVisibleRect,
      in: hostingView.frame.size
    )

    XCTAssertEqual(after.x, before.x, accuracy: 0.01)
    XCTAssertEqual(after.y, before.y, accuracy: 0.01)
    XCTAssertEqual(scrollView.magnification, 2, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 200)
  }

  @MainActor
  func testCoordinatorSafelyFitsCaptureAbovePreviousMaximum() {
    let model = CaptureZoomModel()
    let coordinator = ZoomableCaptureCanvas<Color>.Coordinator(model: model)
    let scrollView = CaptureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
    scrollView.allowsMagnification = true
    scrollView.minMagnification = 0.01
    scrollView.maxMagnification = CaptureZoomGeometry.magnificationRange.upperBound

    let hostingView = NSHostingView(rootView: Color.clear)
    hostingView.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
    scrollView.documentView = hostingView
    coordinator.hostingView = hostingView
    coordinator.imageSize = CGSize(width: 40, height: 30)
    coordinator.connect(to: scrollView)

    coordinator.layoutDocument(in: scrollView)

    let expectedFit = CaptureZoomGeometry.fitMagnification(
      hostingView.frame.size,
      in: scrollView.contentSize
    )
    XCTAssertGreaterThan(expectedFit, CaptureZoomGeometry.magnificationRange.upperBound)
    XCTAssertEqual(scrollView.minMagnification, expectedFit, accuracy: 0.001)
    XCTAssertEqual(
      scrollView.maxMagnification,
      expectedFit * CaptureZoomGeometry.magnificationRange.upperBound,
      accuracy: 0.001
    )
    XCTAssertEqual(scrollView.magnification, expectedFit, accuracy: 0.001)
    XCTAssertEqual(model.percentage, 100)

    coordinator.imageSize = CGSize(width: 2400, height: 1600)
    coordinator.layoutDocument(in: scrollView)

    let expectedRefit = CaptureZoomGeometry.fitMagnification(
      hostingView.frame.size,
      in: scrollView.contentSize
    )
    XCTAssertLessThan(
      expectedRefit * CaptureZoomGeometry.magnificationRange.upperBound,
      expectedFit
    )
    XCTAssertEqual(scrollView.minMagnification, expectedRefit, accuracy: 0.001)
    XCTAssertEqual(
      scrollView.maxMagnification,
      expectedRefit * CaptureZoomGeometry.magnificationRange.upperBound,
      accuracy: 0.001
    )
    XCTAssertEqual(scrollView.magnification, expectedRefit, accuracy: 0.001)
  }
}
