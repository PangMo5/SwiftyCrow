// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Foundation
import ScreenCaptureKit
import Sharing
import Testing
@testable import SwiftyCrow

@MainActor
struct PermissionFlowTests {

  // MARK: Internal

  @Test
  func permissionFlowSavesDraftBeforePromptAndSettings() async {
    let events = LockIsolated<[String]>([])
    let store = TestStore(initialState: state()) { OnboardingFeature() } withDependencies: {
      $0.appRelaunch.prepare = { events.withValue { $0.append("saved") } }
      $0.screenRecordingAccess.request = { events.withValue { $0.append("prompt") }
        return false
      }
      $0.screenRecordingAccess.openSettings = { events.withValue { $0.append("settings") } }
      $0.screenRecordingAccess.isGranted = { false }
    }
    await store.send(.grantAccessTapped) {
      $0.isRequestingAccess = true
      $0.requestedAccess = true
      $0.$savedTarget.withLock { $0 = "fr" }
      $0.$savedStep.withLock { $0 = 1 }
      $0.$resumeRequested.withLock { $0 = true }
    }
    await store.receive(\.accessRequestFinished) { $0.isRequestingAccess = false }
    #expect(events.value == ["saved", "prompt", "settings"])
  }

  @Test
  func systemRelaunchRestoresManuallyReopenedSetupAndItsDraft() async {
    let storage = UserDefaults.inMemory
    let initial = withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.defaultAppStorage = storage
    } operation: {
      let value = OnboardingFeature.State()
      value.$completed.withLock { $0 = true }
      value.$hasStarted.withLock { $0 = true }
      value.$savedStep.withLock { $0 = 1 }
      value.$savedTarget.withLock { $0 = "fr" }
      value.$resumeRequested.withLock { $0 = true }
      return OnboardingFeature.State()
    }
    let store = TestStore(initialState: initial) { OnboardingFeature() }
    await store.send(.launchChecked(hasExistingConfiguration: true)) {
      $0.hasCheckedLaunch = true
      $0.isPresented = true
      $0.step = .prepare
      $0.target = Language(code: "fr")
      $0.$resumeRequested.withLock { $0 = false }
    }
    #expect(store.state.settings.languages.target != Language(code: "fr"))
    await store.send(.closed) { $0.isPresented = false }
  }

  @Test
  func failedRelaunchLeavesSetupOpenWithTheDraftIntact() async {
    struct Failure: LocalizedError { var errorDescription: String? {
      "Relaunch failed"
    } }
    let store = TestStore(initialState: state()) { OnboardingFeature() } withDependencies: {
      $0.appRelaunch.relaunch = { throw Failure() }
    }
    await store.send(.relaunchTapped) {
      $0.isRelaunching = true
      $0.$savedTarget.withLock { $0 = "fr" }
      $0.$savedStep.withLock { $0 = 1 }
      $0.$resumeRequested.withLock { $0 = true }
    }
    await store.receive(\.relaunchFailed) {
      $0.isRelaunching = false
      $0.relaunchError = "Relaunch failed"
    }
    #expect(store.state.isPresented)
  }

  @Test
  func captureDenialClosesCachedPermissionUntilTheNextProcess() async {
    let center = NotificationCenter()
    let notifications = LockIsolated(0)
    let token = center
      .addObserver(forName: ScreenRecordingAccessState.didClose, object: nil, queue: nil) { _ in
        notifications.withValue { $0 += 1 }
      }
    defer { center.removeObserver(token) }
    let access = ScreenRecordingAccessState(preflight: { true }, center: center)
    #expect(await access.isGranted())
    await access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userStopped.rawValue))
    #expect(await access.isGranted())
    await access.captureFailed(NSError(domain: SCStreamErrorDomain, code: SCStreamError.Code.userDeclined.rawValue))
    #expect(await access.isGranted() == false)
    #expect(await access.isGranted() == false)
    #expect(notifications.value == 1)
    let nextProcess = ScreenRecordingAccessState(preflight: { true }, center: center)
    #expect(await nextProcess.isGranted())
  }

  // MARK: Private

  private func state() -> OnboardingFeature.State {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.defaultAppStorage = .inMemory
    } operation: {
      var value = OnboardingFeature.State()
      value.isPresented = true
      value.step = .prepare
      value.target = Language(code: "fr")
      return value
    }
  }

}
