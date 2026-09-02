// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation

// MARK: - OverlayBackdrop

/// An immutable capture shared with the detached live-result window.
///
/// `CGImage` owns immutable pixel storage and can safely be retained across the
/// capture and main actors. Identity equality is intentional: every successful
/// capture produces a new image, while unrelated state updates keep the same one.
struct OverlayBackdrop: @unchecked Sendable, Equatable {
  let image: CGImage

  static func ==(lhs: Self, rhs: Self) -> Bool {
    lhs.image === rhs.image
  }
}

// MARK: - OverlayRenderState

struct OverlayRenderState: Equatable, Sendable {
  var lines: [OverlayLine]
  var isVisible: Bool
  var hideOnHover: Bool
  var isTranslating: Bool
  var isLive: Bool
  /// In-place draws source-restored text on the overlay; window draws a thin region frame and
  /// shows the translation in a detached result window.
  var liveMode: OverlayLiveMode
  /// Captured pixels shown in the detached window (window mode only).
  var backdrop: OverlayBackdrop?
  var imageSize: CGSize
  /// Bumped whenever the overlay is (re)placed onto a new selection, so the
  /// controller snaps the window to the stored frame even if it's already shown.
  var placementID: Int
  /// Translation failed (usually a missing on-device model) — shows the
  /// "open Settings" hint on the overlay.
  var translationUnavailable: Bool
  /// Vision is still loading its document model, which takes tens of seconds
  /// when cold — shows a "preparing" note so the empty overlay isn't a mystery.
  var isPreparingRecognition: Bool
}

// MARK: - OverlayUserAction

/// Actions the user triggers from controls drawn on the overlay itself, routed
/// back to the store (the overlay is otherwise driven one-way by render state).
enum OverlayUserAction: Sendable {
  case toggleLive
  case close
}

// MARK: - OverlayClient

@DependencyClient
struct OverlayClient {
  var render: @Sendable (_ state: OverlayRenderState) async -> Void
  var events: @Sendable () -> AsyncStream<OverlayUserAction> = { .finished }
}

// MARK: DependencyKey

extension OverlayClient: DependencyKey {
  static let liveValue: OverlayClient = {
    // The controller touches AppKit, so it can only be built on the main
    // actor. Create it lazily the first time the client is used there.
    nonisolated(unsafe) var controller: OverlayWindowController?
    let resolve: @MainActor @Sendable () -> OverlayWindowController = {
      if let controller { return controller }
      let new = OverlayWindowController()
      controller = new
      return new
    }
    return OverlayClient(
      render: { state in
        await resolve().update(state)
      },
      events: {
        AsyncStream { continuation in
          let task = Task { @MainActor in
            resolve().setEventHandler { action in continuation.yield(action) }
          }
          continuation.onTermination = { _ in task.cancel() }
        }
      }
    )
  }()
}

extension DependencyValues {
  var overlay: OverlayClient {
    get { self[OverlayClient.self] }
    set { self[OverlayClient.self] = newValue }
  }
}
