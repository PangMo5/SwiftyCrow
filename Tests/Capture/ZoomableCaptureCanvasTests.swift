// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import SwiftUI
import Testing
@testable import SwiftyCrow

@Suite("Native capture viewport")
@MainActor
struct ZoomableCaptureCanvasTests {

  // MARK: Internal

  @Test
  func fitTracksWindowSizeUntilUserZooms() {
    let fixture = Fixture()
    #expect(abs(fixture.model.scale - 0.375) < 0.001)
    fixture.scroll.setFrameSize(CGSize(width: 300, height: 300))
    fixture.layout()
    #expect(abs(fixture.model.scale - 0.1875) < 0.001)
    #expect(fixture.model.isFitting)
    fixture.model.zoomIn()
    #expect(abs(fixture.model.scale - 0.234375) < 0.001)
    #expect(!fixture.model.isFitting)
  }

  @Test
  func resizingPreservesManualScaleAndViewportCenter() {
    let fixture = Fixture()
    fixture.pinch(to: 1.5)
    fixture.scroll.contentView.scroll(to: CGPoint(x: 400, y: 220))
    fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
    let before = fixture.center
    fixture.scroll.setFrameSize(CGSize(width: 800, height: 500))
    fixture.layout()
    #expect(abs(fixture.model.scale - 1.5) < 0.001)
    #expect(abs(fixture.center.x - before.x) < 0.001)
    #expect(abs(fixture.center.y - before.y) < 0.001)
  }

  @Test
  func movingAcrossDisplayScalesPreservesNativeZoom() {
    let fixture = Fixture(backingScale: 2)
    #expect(abs(fixture.model.scale - 0.75) < 0.001)
    fixture.pinch(to: 0.75)
    #expect(abs(fixture.model.scale - 1.5) < 0.001)
    let before = fixture.center
    fixture.coordinator.backingScale = 1
    fixture.layout()
    #expect(abs(fixture.scroll.magnification - 1.5) < 0.001)
    #expect(abs(fixture.model.scale - 1.5) < 0.001)
    #expect(abs(fixture.center.x - before.x) < 0.001)
    #expect(abs(fixture.center.y - before.y) < 0.001)
  }

  @Test
  func fitRecentersPannedImageAndTranslationUpdatesPreserveZoom() {
    let fixture = Fixture()
    fixture.pinch(to: 2)
    fixture.scroll.contentView.scroll(to: CGPoint(x: 500, y: 250))
    let before = fixture.center
    fixture.coordinator.hostingView?.rootView = .red
    fixture.layout()
    #expect(fixture.model.scale == 2)
    #expect(fixture.center == before)
    fixture.model.resetToFit()
    #expect(abs(fixture.model.scale - 0.375) < 0.001)
    #expect(abs(fixture.center.x - 0.5) < 0.001)
    #expect(abs(fixture.center.y - 0.5) < 0.001)
  }

  @Test
  func mousePanCannotMoveTheImagePastItsEdges() {
    let fixture = Fixture()
    fixture.pinch(to: 2)
    fixture.scroll.scrollContent(to: CGPoint(x: -1000, y: -1000))
    #expect(abs(fixture.scroll.contentView.bounds.minX) < 0.001)
    #expect(abs(fixture.scroll.contentView.bounds.minY) < 0.001)
    fixture.scroll.scrollContent(to: CGPoint(x: 10000, y: 10000))
    #expect(abs(fixture.scroll.contentView.bounds.maxX - 1600) < 0.001)
    #expect(abs(fixture.scroll.contentView.bounds.maxY - 800) < 0.001)
    fixture.model.resetToFit()
    fixture.scroll.scrollContent(to: CGPoint(x: 10000, y: 10000))
    #expect(abs(fixture.center.x - 0.5) < 0.001)
    #expect(abs(fixture.center.y - 0.5) < 0.001)
  }

  @Test
  func toolbarZoomStopsAtBoundsAndNewImagesRefit() {
    let fixture = Fixture()
    for _ in 0..<50 { fixture.model.zoomIn() }
    #expect(fixture.model.scale == 8)
    #expect(!fixture.model.canZoomIn)
    for _ in 0..<50 { fixture.model.zoomOut() }
    #expect(fixture.model.scale == 0.1)
    #expect(!fixture.model.canZoomOut)
    fixture.coordinator.imageSize = CGSize(width: 40, height: 30)
    fixture.layout()
    #expect(fixture.model.scale == 1)
    fixture.coordinator.imageSize = CGSize(width: 2400, height: 1600)
    fixture.layout()
    #expect(abs(fixture.model.scale - 0.25) < 0.001)
    #expect(fixture.model.isFitting)
  }

  // MARK: Private

  @MainActor
  private struct Fixture {

    // MARK: Lifecycle

    init(backingScale: CGFloat = 1) {
      model = CaptureZoomModel()
      coordinator = ZoomableCaptureCanvas<Color>.Coordinator(model: model)
      scroll = CaptureScrollView(frame: CGRect(x: 0, y: 0, width: 600, height: 400))
      scroll.allowsMagnification = true
      scroll.minMagnification = 0.001
      scroll.maxMagnification = 8
      scroll.contentView = CenteringCaptureClipView()
      let hosting = NSHostingView(rootView: Color.clear)
      hosting.sizingOptions = []
      hosting.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
      scroll.documentView = hosting
      coordinator.hostingView = hosting
      coordinator.imageSize = CGSize(width: 1600, height: 800)
      coordinator.backingScale = backingScale
      coordinator.connect(to: scroll)
      layout()
    }

    // MARK: Internal

    let model: CaptureZoomModel
    let coordinator: ZoomableCaptureCanvas<Color>.Coordinator
    let scroll: CaptureScrollView

    var center: CGPoint {
      CaptureZoomGeometry.normalizedCenter(of: scroll.documentVisibleRect, in: coordinator.imageSize)
    }

    func layout() {
      coordinator.layoutDocument(in: scroll)
    }

    func pinch(to magnification: CGFloat) {
      scroll.setMagnification(magnification, centeredAt: CGPoint(x: 800, y: 400))
      coordinator.magnificationChanged(in: scroll)
    }
  }
}
