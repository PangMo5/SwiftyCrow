// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import Sharing
import Testing
@testable import SwiftyCrow

@Suite("Detached translation window placement", .serialized)
@MainActor
struct OverlayWindowPlacementTests {

  // MARK: Internal

  @Test
  func offscreenNativeWindowRetainsItsServerIdentity() {
    let window = NSWindow(
      contentRect: CGRect(x: 10, y: 10, width: 160, height: 100),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.orderFront(nil)
    let id = CGWindowID(window.windowNumber)
    #expect(windowIsKnownToServer(id) == true)
    window.orderOut(nil)
    #expect(windowIsKnownToServer(id) == true, "A hidden window is not a closed window")
  }

  @Test
  func teardownCannotRestoreAnInvalidatedSourceSelection() {
    withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      @Shared(.overlayFrame) var frame
      $frame.withLock { $0 = OverlayFrame(rect: CGRect(x: 50, y: 80, width: 300, height: 200), selectionKind: .window) }
      let controller = OverlayWindowController()
      var state = OverlayRenderState(
        lines: [],
        isVisible: true,
        hideOnHover: false,
        isTranslating: false,
        isLive: true,
        liveMode: .inPlace,
        backdrop: nil,
        imageSize: CGSize(width: 300, height: 200),
        placementID: 1,
        translationUnavailable: false,
        isPreparingRecognition: false
      )
      controller.update(state)
      // The reducer has invalidated a closed source before AppKit tears down.
      $frame.withLock { $0.hasSelection = false }
      state.isVisible = false
      controller.update(state)
      #expect(!frame.hasSelection, "Closing the native panel must not recall a closed source as an unrelated screen region")
      #expect(frame.selectionKind == .window)
    }
  }

  @Test
  func queuedWindowRendersCannotReappearAfterGeometryChanges() {
    let original = CGRect(x: 10, y: 20, width: 300, height: 200)
    let moved = original.offsetBy(dx: 50, dy: 70)
    let line = OverlayLine(id: UUID(), source: .init(
      recognized: .init(boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), text: "Source"),
      language: Locale.Language(identifier: "en")
    ))
    var state = OverlayRenderState(
      lines: [line],
      isVisible: true,
      hideOnHover: false,
      isTranslating: false,
      isLive: true,
      liveMode: .inPlace,
      backdrop: nil,
      imageSize: original.size,
      placementID: 1,
      translationUnavailable: false,
      isPreparingRecognition: false,
      sourceWindowID: 42,
      sourceWindowFrame: original,
      captureGeneration: 5
    )
    #expect(state.validatingSourceWindow(id: 42, frame: original, minimumGeneration: 5).lines == [line])
    #expect(state.validatingSourceWindow(id: 42, frame: moved, minimumGeneration: 6).lines.isEmpty)
    #expect(state.validatingSourceWindow(id: 42, frame: nil, minimumGeneration: 6).lines.isEmpty)
    // Returning to the same coordinates must not revive an older generation.
    #expect(state.validatingSourceWindow(id: 42, frame: original, minimumGeneration: 6).lines.isEmpty)
    #expect(state.validatingSourceWindow(id: 99, frame: original, minimumGeneration: 5).lines.isEmpty)
    state.sourceWindowFrame = moved
    state.captureGeneration = 6
    #expect(state.validatingSourceWindow(id: 42, frame: moved, minimumGeneration: 6).lines == [line])
    state.sourceWindowID = nil
    #expect(state.validatingSourceWindow(id: nil, frame: nil, minimumGeneration: 100).lines == [line])
  }

  @Test
  func hidingReleasesTheWindowAndRecallRestoresUserGeometry() throws {
    try withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: {
      let controller = OverlayWindowController()
      let line = OverlayLine(id: UUID(), source: .init(
        recognized: .init(boundingBoxNormalized: CGRect(x: 0, y: 0, width: 1, height: 1), text: "A translated dialogue"),
        language: Locale.Language(identifier: "en")
      ))
      var state = OverlayRenderState(
        lines: [line],
        isVisible: true,
        hideOnHover: false,
        isTranslating: false,
        isLive: true,
        liveMode: .window,
        backdrop: nil,
        imageSize: CGSize(width: 1000, height: 200),
        placementID: 1,
        translationUnavailable: false,
        isPreparingRecognition: false
      )
      defer { state.isVisible = false
        controller.update(state)
      }
      controller.update(state)
      let first = try #require(resultWindow())
      let screen = try #require(first.screen ?? NSScreen.main).visibleFrame
      first.setFrame(CGRect(x: screen.minX + 40, y: screen.maxY - 260, width: 420, height: 180), display: false)
      let chosen = first.frame

      state.isVisible = false
      state.lines = []
      controller.update(state)
      #expect(!first.isVisible)
      #expect(resultWindow() == nil)

      // Recall increments the capture placement identifier even for the same
      // source region. That must not discard the detached reading window layout.
      state.isVisible = true
      state.lines = [line]
      state.placementID += 1
      controller.update(state)
      let recalled = try #require(resultWindow())
      #expect(recalled !== first)
      #expect(recalled.frame == chosen)
    }
  }

  @Test
  func aRemovedDisplayMovesTheWholeWindowIntoTheRemainingVisibleArea() {
    let visible = CGRect(x: 0, y: 60, width: 1200, height: 800)
    let former = CGRect(x: 1800, y: 250, width: 730, height: 163)
    let actual = OverlayWindowController.restoredResultFrame(former, screens: [visible], defaultScreen: visible)
    #expect(actual.size == former.size)
    #expect(visible.contains(actual))
    #expect(actual.maxX == visible.maxX)
    #expect(actual.minY == former.minY)
  }

  @Test
  func anotherConnectedDisplayRetainsItsOwnLayoutAndShrunkenDisplaysContainOversizedWindows() {
    let left = CGRect(x: -1600, y: 0, width: 1600, height: 1000)
    let main = CGRect(x: 0, y: 40, width: 1200, height: 800)
    let chosen = CGRect(x: -1200, y: 300, width: 730, height: 163)
    #expect(OverlayWindowController.restoredResultFrame(chosen, screens: [left, main], defaultScreen: main) == chosen)
    let oversized = CGRect(x: 10, y: -20, width: 1500, height: 1000)
    #expect(OverlayWindowController.restoredResultFrame(oversized, screens: [main], defaultScreen: main) == main)
  }

  // MARK: Private

  private func resultWindow() -> NSWindow? {
    NSApp.windows.first { $0.isVisible && $0.accessibilityIdentifier() == "live-translation-result" }
  }
}
