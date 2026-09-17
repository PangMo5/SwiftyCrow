// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import DependenciesMacros
import ScreenCaptureKit

// MARK: - ScreenRecordingAccessClient

@DependencyClient
struct ScreenRecordingAccessClient: Sendable {
  var isGranted: @Sendable () async -> Bool = { false }
  var request: @Sendable () async -> Bool = { false }
  var openSettings: @MainActor @Sendable () -> Void = { }
  var changes: @Sendable () -> AsyncStream<Void> = { .finished }
}

// MARK: DependencyKey

extension ScreenRecordingAccessClient: DependencyKey {
  static let liveValue = ScreenRecordingAccessClient(
    isGranted: { await ScreenRecordingAccessState.shared.isGranted() },
    request: { await MainActor.run { CGRequestScreenCaptureAccess() } },
    openSettings: {
      NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
    },
    changes: {
      AsyncStream { continuation in
        let observers = ScreenRecordingObservers(continuation: continuation)
        continuation.onTermination = { _ in observers.cancel() }
        continuation.yield()
      }
    }
  )
  static let testValue = ScreenRecordingAccessClient()
}

extension DependencyValues {
  var screenRecordingAccess: ScreenRecordingAccessClient {
    get { self[ScreenRecordingAccessClient.self] }
    set { self[ScreenRecordingAccessClient.self] = newValue }
  }
}

// MARK: - ScreenRecordingAccessState

/// As in Tatami, capture failures and permission UI share one session state.
/// A known denial stays closed until relaunch, even if preflight is cached.
actor ScreenRecordingAccessState {

  // MARK: Lifecycle

  init(preflight: @escaping @Sendable () -> Bool, center: NotificationCenter = .default) {
    self.preflight = preflight
    self.center = center
  }

  // MARK: Internal

  static let shared = ScreenRecordingAccessState(preflight: { CGPreflightScreenCaptureAccess() })
  static let didClose = Notification.Name("dev.PangMo5.SwiftyCrow.screenRecordingAccessDidClose")

  func isGranted() -> Bool {
    guard !closed else { return false }
    if !preflight() { close() }
    return !closed
  }

  func captureFailed(_ error: any Error) {
    let error = error as NSError
    if error.domain == SCStreamErrorDomain, error.code == SCStreamError.Code.userDeclined.rawValue { close() }
    else { _ = isGranted() }
  }

  // MARK: Private

  private let preflight: @Sendable () -> Bool
  private let center: NotificationCenter
  private var closed = false

  private func close() {
    guard !closed else { return }
    closed = true
    center.post(name: Self.didClose, object: nil)
  }
}

// MARK: - ScreenRecordingObservers

/// Immutable observer tokens; NotificationCenter supports removal on any thread.
private final class ScreenRecordingObservers: @unchecked Sendable {

  // MARK: Lifecycle

  init(continuation: AsyncStream<Void>.Continuation) {
    tokens = [ScreenRecordingAccessState.didClose, NSApplication.didBecomeActiveNotification].map { name in
      NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in continuation.yield() }
    }
  }

  // MARK: Internal

  func cancel() {
    for token in tokens { NotificationCenter.default.removeObserver(token) }
  }

  // MARK: Private

  private let tokens: [any NSObjectProtocol]
}
