// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import Sharing
import Testing
@testable import SwiftyCrow

@MainActor
struct OverlayVisibilityTests {
  @Test
  func visibilityRequiresASelectedAreaAndSelectionCancellationKeepsItHidden() async {
    let initial = withDependencies {
      $0.defaultFileStorage = .inMemory
    } operation: { CaptureFeature.State() }
    #expect(!initial.overlayFrame.hasSelection)
    let requests = LockIsolated(0)
    let store = TestStore(initialState: initial) { CaptureFeature() } withDependencies: {
      $0.ocr.warmUp = { }
      $0.regionSelector.selectRegion = { _ in requests.withValue { $0 += 1 }
        return nil
      }
    }
    await store.send(.setOverlayVisible(true))
    await store.receive(\.toggleLiveOverlayRequested)
    await store.send(.liveSelectRequested)
    await store.finish()
    #expect(requests.value == 1)
    #expect(!store.state.overlayActive)
    #expect(!store.state.overlayFrame.hasSelection)
    await store.send(.setOverlayVisible(false))
  }

  @Test
  func existingSavedRegionsRemainUsableAfterUpdating() throws {
    let legacy = Data(#"{"x":20,"y":30,"width":500,"height":240}"#.utf8)
    let frame = try JSONDecoder().decode(OverlayFrame.self, from: legacy)
    #expect(frame.hasSelection)
    #expect(frame.rect == CGRect(x: 20, y: 30, width: 500, height: 240))
    #expect(try JSONDecoder().decode(OverlayFrame.self, from: JSONEncoder().encode(OverlayFrame.default)).hasSelection == false)
    #expect(OverlayFrame(rect: frame.rect).hasSelection)
  }
}
