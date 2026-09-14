// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import Sharing
import Testing
@testable import SwiftyCrow

@MainActor
struct OnboardingTests {

  // MARK: Internal

  @Test
  func firstLaunchPresentsOnlyOnce() async {
    let store = TestStore(initialState: state()) { OnboardingFeature() }
    await store.send(.launchChecked(hasExistingConfiguration: false)) {
      $0.hasCheckedLaunch = true
      $0.$hasStarted.withLock { $0 = true }
      $0.isPresented = true
      $0.target = $0.settings.languages.target
    }
    await store.send(.launchChecked(hasExistingConfiguration: false))
    await store.send(.closed) { $0.isPresented = false }
    await store.send(.launchChecked(hasExistingConfiguration: false))
  }

  @Test
  func existingUsersAreNotForcedThroughSetup() async {
    let store = TestStore(initialState: state()) { OnboardingFeature() }
    await store.send(.launchChecked(hasExistingConfiguration: true)) {
      $0.hasCheckedLaunch = true
      $0.$completed.withLock { $0 = true }
    }
    await store.send(.openRequested) {
      $0.$hasStarted.withLock { $0 = true }
      $0.isPresented = true
      $0.target = $0.settings.languages.target
    }
  }

  @Test
  func unfinishedSetupResumesAfterPermissionRelaunch() async {
    let initial = state()
    initial.$hasStarted.withLock { $0 = true }
    initial.$savedStep.withLock { $0 = 1 }
    let store = TestStore(initialState: initial) { OnboardingFeature() }
    await store.send(.launchChecked(hasExistingConfiguration: true)) {
      $0.hasCheckedLaunch = true
      $0.isPresented = true
      $0.step = .prepare
      $0.target = $0.settings.languages.target
    }
  }

  @Test
  func skippingDoesNotApplyDraftLanguage() async {
    var initial = state()
    initial.isPresented = true
    initial.target = Language(code: "fr")
    let original = initial.settings.languages.target
    let store = TestStore(initialState: initial) { OnboardingFeature() }
    await store.send(.skipTapped) {
      $0.$completed.withLock { $0 = true }
      $0.isPresented = false
    }
    #expect(store.state.settings.languages.target == original)
  }

  @Test
  func finishRequiresPermissionOnlyForImmediateCapture() async {
    var initial = state()
    initial.isPresented = true
    initial.target = Language(code: "fr")
    let store = TestStore(initialState: initial) { OnboardingFeature() }
    await store.send(.finishTapped(startCapture: true))
    await store.send(.finishTapped(startCapture: false)) {
      $0.$settings.withLock { $0.languages.target = Language(code: "fr") }
      $0.$completed.withLock { $0 = true }
      $0.isPresented = false
    }
  }

  @Test
  func returningFromSettingsRefreshesPermissionWithoutPrompting() async {
    var initial = state()
    initial.isPresented = true
    let store = TestStore(initialState: initial) { OnboardingFeature() } withDependencies: {
      $0.screenRecordingAccess.isGranted = { true }
    }
    await store.send(.becameActive)
    await store.receive(\.accessLoaded) { $0.hasScreenRecording = true }
    await store.send(.closed) { $0.isPresented = false }
    await store.send(.accessLoaded(false))
    #expect(store.state.hasScreenRecording)
  }

  @Test
  func deniedPermissionDoesNotBlockTheRestOfSetup() async {
    var initial = state()
    initial.isPresented = true
    initial.step = .prepare
    let store = TestStore(initialState: initial) { OnboardingFeature() } withDependencies: {
      $0.screenRecordingAccess.request = { false }
      $0.screenRecordingAccess.isGranted = { false }
      $0.screenRecordingAccess.openSettings = { }
    }
    await store.send(.grantAccessTapped) {
      $0.isRequestingAccess = true
      $0.requestedAccess = true
      $0.$savedTarget.withLock { $0 = initial.target.code }
      $0.$savedStep.withLock { $0 = 1 }
      $0.$resumeRequested.withLock { $0 = true }
    }
    await store.receive(\.accessRequestFinished) { $0.isRequestingAccess = false }
    await store.send(.nextTapped) {
      $0.step = .ready
      $0.$savedStep.withLock { $0 = 2 }
    }
  }

  @Test
  func firstCaptureStartsOnlyAfterTheWelcomeWindowCloses() async {
    let initial = withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.defaultAppStorage = .inMemory
    } operation: {
      var value = AppFeature.State()
      value.onboarding.isPresented = true
      value.onboarding.hasScreenRecording = true
      value.onboarding.target = value.settings.languages.target
      return value
    }
    let selections = LockIsolated(0)
    let store = TestStore(initialState: initial) { AppFeature() } withDependencies: {
      $0.ocr.warmUp = { }
      $0.regionSelector.selectRegion = { _ in selections.withValue { $0 += 1 }
        return nil
      }
    }
    await store.send(.onboarding(.finishTapped(startCapture: true))) {
      $0.onboarding.$completed.withLock { $0 = true }
      $0.onboarding.startCaptureAfterDismissal = true
      $0.onboarding.isPresented = false
    }
    #expect(selections.value == 0)
    await store.send(.onboarding(.closed)) { $0.onboarding.startCaptureAfterDismissal = false }
    await store.receive(\.capture.selectRegionRequested)
    await store.finish()
    #expect(selections.value == 1)
    await store.send(.onboarding(.closed))
    #expect(selections.value == 1)
  }

  @Test
  func fullChangelogKeepsHeadingsListsAndInlineLinks() throws {
    let blocks =
      try parseChangelog("## 2.10.0\n\n- **Setup:** Read the [guide](https://example.com/guide).\n\n1. Open Settings\n")
    #expect(blocks.first.map { if case .heading(2) = $0.kind { true } else { false } } == true)
    #expect(String(blocks[0].text.characters) == "2.10.0")
    #expect(blocks[1].marker == "•")
    #expect(blocks[1].text.runs.contains { $0.link?.absoluteString == "https://example.com/guide" })
    #expect(blocks[2].marker == "1.")
  }

  @Test
  func changelogOmitsTheDocumentPreambleButKeepsDraftAndReleasedEntries() throws {
    let blocks =
      try parseChangelog(
        "# 변경 기록\n\nRepository-only publishing instructions.\n\n## 출시 예정\n\n- 새 기능\n\n## 2.9.1 (2026-08-22)\n\n- 이전 변경\n"
      )
    #expect(blocks.filter { if case .heading(2) = $0.kind { true } else { false } }.map { String($0.text.characters) } == [
      "출시 예정",
      "2.9.1 (2026-08-22)",
    ])
    #expect(!blocks.contains { String($0.text.characters).contains("Repository-only") })
    #expect(blocks.contains { String($0.text.characters) == "새 기능" })
    #expect(blocks.contains { String($0.text.characters) == "이전 변경" })
  }

  @Test
  func whatsNewIsOncePerMinorReleaseAndNeverForFreshInstalls() {
    #expect(!WhatsNewClient.shouldShow(current: "2.10.0", lastShown: nil, hasExistingConfiguration: false))
    #expect(WhatsNewClient.shouldShow(current: "2.10.0", lastShown: nil, hasExistingConfiguration: true))
    #expect(WhatsNewClient.shouldShow(current: "2.10.0", lastShown: "2.9.1", hasExistingConfiguration: true))
    #expect(!WhatsNewClient.shouldShow(current: "2.10.0", lastShown: "2.10.0", hasExistingConfiguration: true))
    #expect(!WhatsNewClient.shouldShow(current: "2.10.1", lastShown: "2.10.0", hasExistingConfiguration: true))
    #expect(!WhatsNewClient.shouldShow(current: "", lastShown: nil, hasExistingConfiguration: true))
  }

  // MARK: Private

  private func parseChangelog(_ source: String) throws -> [BundledDocumentBlock] {
    try ParsedBundledDocument(markdown: source, document: .changelog).blocks
  }

  private func state() -> OnboardingFeature.State {
    withDependencies {
      $0.defaultFileStorage = .inMemory
      $0.defaultAppStorage = .inMemory
    } operation: { OnboardingFeature.State() }
  }

}
