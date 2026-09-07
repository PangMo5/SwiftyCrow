// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import CoreGraphics
import Testing
@testable import SwiftyCrow

@Suite("Capture zoom geometry")
struct CaptureZoomGeometryTests {
  @Test
  func fitUsesNativePixelsOnStandardAndRetinaDisplays() {
    let image = CGSize(width: 1600, height: 800)
    let viewport = CGSize(width: 600, height: 400)
    #expect(CaptureZoomGeometry.fitScale(image: image, viewport: viewport, backingScale: 1) == 0.375)
    #expect(CaptureZoomGeometry.fitScale(image: image, viewport: viewport, backingScale: 2) == 0.75)
  }

  @Test
  func fitDoesNotEnlargeSmallCaptures() {
    #expect(CaptureZoomGeometry.fitScale(
      image: CGSize(width: 40, height: 30),
      viewport: CGSize(width: 600, height: 400),
      backingScale: 2
    ) == 1)
  }

  @Test
  func rejectsUnavailableAndInvalidGeometry() {
    let size = CGSize(width: 200, height: 100)
    #expect(CaptureZoomGeometry.fitScale(image: .zero, viewport: size, backingScale: 1) == nil)
    #expect(CaptureZoomGeometry.fitScale(image: size, viewport: .zero, backingScale: 1) == nil)
    #expect(CaptureZoomGeometry.fitScale(image: size, viewport: size, backingScale: .infinity) == nil)
    #expect(CaptureZoomGeometry.fitScale(image: size, viewport: size, backingScale: 0) == nil)
  }

  @Test
  func preservedCenterIsClampedToVisibleDocumentEdges() {
    let origin = CaptureZoomGeometry.scrollOrigin(
      center: CGPoint(x: 0.9, y: 0.1),
      visibleSize: CGSize(width: 400, height: 200),
      documentSize: CGSize(width: 800, height: 400)
    )
    #expect(origin == CGPoint(x: 400, y: 0))
  }
}
