import XCTest

@testable import SwiftyCrow

final class CaptureZoomGeometryTests: XCTestCase {

  func testDetailScaleOnlyOversamplesOneXDisplays() {
    XCTAssertEqual(CaptureZoomGeometry.detailScale(forBackingScale: 1), 2)
    XCTAssertEqual(CaptureZoomGeometry.detailScale(forBackingScale: 2), 1)
    XCTAssertEqual(CaptureZoomGeometry.detailScale(forBackingScale: 3), 1)
    XCTAssertEqual(CaptureZoomGeometry.detailScale(forBackingScale: 0), 1)
    XCTAssertEqual(
      CaptureZoomGeometry.detailedDocumentSize(
        CGSize(width: 640, height: 480),
        backingScale: 1
      ),
      CGSize(width: 1280, height: 960)
    )
  }

  func testDetailedDocumentSizeCapsLargeCaptureOversampling() {
    let source = CGSize(width: 3840, height: 2160)
    let detailed = CaptureZoomGeometry.detailedDocumentSize(source, backingScale: 1)

    XCTAssertGreaterThan(detailed.width, source.width)
    XCTAssertLessThan(detailed.width, source.width * 2)
    XCTAssertLessThanOrEqual(
      detailed.width * detailed.height,
      CaptureZoomGeometry.maximumOversampledArea + 1
    )
    let alreadyLarge = CGSize(width: 6000, height: 4000)
    XCTAssertEqual(
      CaptureZoomGeometry.detailedDocumentSize(alreadyLarge, backingScale: 1),
      alreadyLarge
    )
    XCTAssertEqual(
      CaptureZoomGeometry.detailedDocumentSize(.zero, backingScale: 1),
      .zero
    )
  }

  func testAspectFitHandlesWideTallAndMatchingImages() {
    XCTAssertEqual(
      CaptureZoomGeometry.aspectFit(CGSize(width: 400, height: 200), in: CGSize(width: 300, height: 300)),
      CGSize(width: 300, height: 150)
    )
    XCTAssertEqual(
      CaptureZoomGeometry.aspectFit(CGSize(width: 200, height: 400), in: CGSize(width: 300, height: 300)),
      CGSize(width: 150, height: 300)
    )
    XCTAssertEqual(
      CaptureZoomGeometry.aspectFit(CGSize(width: 400, height: 200), in: CGSize(width: 200, height: 100)),
      CGSize(width: 200, height: 100)
    )
  }

  func testAspectFitRejectsInvalidGeometry() {
    XCTAssertEqual(
      CaptureZoomGeometry.aspectFit(.zero, in: CGSize(width: 300, height: 300)),
      .zero
    )
    XCTAssertEqual(
      CaptureZoomGeometry.aspectFit(
        CGSize(width: 100, height: 100),
        in: CGSize(width: CGFloat.infinity, height: 300)
      ),
      .zero
    )
  }

  func testFitMagnificationSupportsDownscalingAndUpscaling() {
    XCTAssertEqual(
      CaptureZoomGeometry.fitMagnification(
        CGSize(width: 800, height: 400),
        in: CGSize(width: 600, height: 400)
      ),
      0.75
    )
    XCTAssertEqual(
      CaptureZoomGeometry.fitMagnification(
        CGSize(width: 200, height: 100),
        in: CGSize(width: 600, height: 400)
      ),
      3
    )
    XCTAssertEqual(CaptureZoomGeometry.fitMagnification(.zero, in: CGSize(width: 600, height: 400)), 0)
  }

  func testMagnificationClampsToSupportedRange() {
    XCTAssertEqual(CaptureZoomGeometry.clampedMagnification(0.5), 1)
    XCTAssertEqual(CaptureZoomGeometry.clampedMagnification(2.5), 2.5)
    XCTAssertEqual(CaptureZoomGeometry.clampedMagnification(9), 6)
    XCTAssertEqual(CaptureZoomGeometry.clampedMagnification(.infinity), 1)
  }

  func testNormalizedCenterSurvivesDocumentResize() {
    let center = CaptureZoomGeometry.normalizedCenter(
      of: CGRect(x: 300, y: 100, width: 200, height: 100),
      in: CGSize(width: 800, height: 400)
    )
    let origin = CaptureZoomGeometry.scrollOrigin(
      preserving: center,
      visibleSize: CGSize(width: 300, height: 150),
      documentSize: CGSize(width: 1_200, height: 600)
    )

    XCTAssertEqual(center.x, 0.5)
    XCTAssertEqual(center.y, 0.375)
    XCTAssertEqual(origin.x, 450)
    XCTAssertEqual(origin.y, 150)
  }

  func testScrollOriginStaysWithinDocumentBounds() {
    XCTAssertEqual(
      CaptureZoomGeometry.scrollOrigin(
        preserving: CGPoint(x: -1, y: 2),
        visibleSize: CGSize(width: 200, height: 100),
        documentSize: CGSize(width: 500, height: 300)
      ),
      CGPoint(x: 0, y: 200)
    )
    XCTAssertEqual(
      CaptureZoomGeometry.scrollOrigin(
        preserving: CGPoint(x: 0.5, y: 0.5),
        visibleSize: CGSize(width: 500, height: 500),
        documentSize: CGSize(width: 200, height: 100)
      ),
      .zero
    )
  }
}
