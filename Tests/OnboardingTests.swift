// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Foundation
import Sharing
import Testing
import TOML
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
      $0.step = .shortcuts
      $0.$savedStep.withLock { $0 = 3 }
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

  @Test
  func shortcutStepKeepsSavedStepValuesAndNavigationOrder() async {
    #expect(OnboardingFeature.Step(rawValue: 2) == .ready)
    var initial = state()
    initial.step = .shortcuts
    initial.$savedStep.withLock { $0 = 3 }
    let store = TestStore(initialState: initial) { OnboardingFeature() }
    await store.send(.nextTapped) {
      $0.step = .ready
      $0.$savedStep.withLock { $0 = 2 }
    }
    await store.send(.backTapped) {
      $0.step = .shortcuts
      $0.$savedStep.withLock { $0 = 3 }
    }
    await store.send(.backTapped) {
      $0.step = .prepare
      $0.$savedStep.withLock { $0 = 1 }
    }
  }

  @Test
  func primaryShortcutsDefaultForNewAndPartialConfigurations() throws {
    let fresh = AppSettings()
    #expect(fresh.shortcuts.selectRegion == HotKey(parsing: "cmd + shift - 1"))
    #expect(fresh.shortcuts.liveOverlay == HotKey(parsing: "cmd + shift - 2"))
    #expect(fresh.shortcuts.toggleLiveOverlay == nil)
    for text in ["", "[shortcuts]", "[shortcuts]\nregionSave = \"cmd - s\"".replacingOccurrences(of: "\\", with: "")] {
      let loaded = try TOMLDecoder().decode(AppSettings.self, from: text)
      #expect(loaded.shortcuts.selectRegion == fresh.shortcuts.selectRegion)
      #expect(loaded.shortcuts.liveOverlay == fresh.shortcuts.liveOverlay)
      #expect(loaded.shortcuts.toggleLiveOverlay == nil)
    }
  }

  @Test
  func clearedAndCustomShortcutsSurviveTOMLRoundTrip() throws {
    var value = AppSettings()
    value.shortcuts.selectRegion = nil
    value.shortcuts.regionCopyImage = nil
    value.shortcuts.liveOverlay = HotKey(parsing: "cmd + shift - 2")
    let encoded = try TOMLEncoder().encode(value)
    let decoded = try TOMLDecoder().decode(AppSettings.self, from: String(decoding: encoded, as: UTF8.self))
    #expect(decoded == value)
    #expect(decoded.shortcuts.selectRegion == nil)
    #expect(decoded.shortcuts.regionCopyImage == nil)
  }

  @Test
  func defaultBindingsDoNotOverwriteExplicitCustomOrClearedValues() throws {
    let loaded = try TOMLDecoder().decode(AppSettings.self, from: """
      [shortcuts]
      selectRegion = "cmd + shift - 9"
      liveOverlay = ""
      toggleLiveOverlay = "alt + cmd - t"
      """)
    #expect(loaded.shortcuts.selectRegion == HotKey(parsing: "cmd + shift - 9"))
    #expect(loaded.shortcuts.liveOverlay == nil)
    #expect(loaded.shortcuts.toggleLiveOverlay == HotKey(parsing: "alt + cmd - t"))
  }

  @Test
  func leavingShortcutRecorderRestoresGlobalShortcuts() {
    let field = RecorderField()
    var enabled = true
    field.onRecordingChange = { enabled = !$0 }
    // Begin recording with a real mouse event through the field's event path.
    if
      let event = NSEvent.mouseEvent(
        with: .leftMouseDown,
        location: .zero,
        modifierFlags: [],
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        eventNumber: 0,
        clickCount: 1,
        pressure: 1
      )
    {
      field.mouseDown(with: event)
    }
    #expect(!enabled)
    field.cancelRecording()
    #expect(enabled)
  }

  @Test
  func shortcutCancelRetainsBindingAndCanRecordAgain() throws {
    let field = RecorderField()
    defer { field.cancelRecording() }
    let old = try #require(HotKey(parsing: "cmd + shift - 1"))
    field.hotKey = old
    var changes = [HotKey?]()
    var recording = [Bool]()
    field.onChange = { changes.append($0) }
    field.onRecordingChange = { recording.append($0) }
    #expect(field.accessibilityPerformPress())
    #expect(field.performKeyEquivalent(with: try shortcutEvent(53)))
    #expect(!field.isRecording)
    #expect(field.hotKey == old)
    #expect(changes.isEmpty)
    #expect(field.accessibilityPerformPress())
    #expect(field.performKeyEquivalent(with: try shortcutEvent(19, modifiers: [.command, .shift])))
    #expect(field.hotKey == HotKey(parsing: "cmd + shift - 2"))
    #expect(changes.count == 1)
    #expect(recording == [true, false, true, false])
  }

  @Test
  func duplicateShortcutShowsOwnerAndDoesNotPoisonNextRecording() throws {
    let field = RecorderField()
    defer { field.cancelRecording() }
    let original = try #require(HotKey(parsing: "cmd + shift - 1"))
    let taken = try #require(HotKey(parsing: "cmd + shift - 2"))
    field.hotKey = original
    field.conflict = { $0 == taken ? "Live translation" : nil }
    var changes = [HotKey?]()
    field.onChange = { changes.append($0) }
    #expect(field.accessibilityPerformPress())
    #expect(field.performKeyEquivalent(with: try shortcutEvent(19, modifiers: [.command, .shift])))
    #expect(field.hotKey == original)
    #expect(changes.isEmpty)
    #expect(!field.isRecording)
    #expect(field.toolTip?.contains("Live translation") == true)
    #expect(field.accessibilityPerformPress())
    #expect(field.toolTip == nil)
    #expect(field.isRecording)
    #expect(field.performKeyEquivalent(with: try shortcutEvent(20, modifiers: [.command, .shift])))
    #expect(field.hotKey == HotKey(parsing: "cmd + shift - 3"))
    #expect(changes.count == 1)
  }

  @Test
  func clearingWhileRecordingStopsCaptureAndAllowsRebinding() throws {
    let field = RecorderField()
    defer { field.cancelRecording() }
    field.hotKey = HotKey(parsing: "cmd + shift - 1")
    var suspended = false
    field.onRecordingChange = { suspended = $0 }
    #expect(field.accessibilityPerformPress())
    #expect(suspended)
    field.synchronizeBinding(nil)
    #expect(!field.isRecording)
    #expect(!suspended)
    #expect(field.hotKey == nil)
    #expect(field.accessibilityPerformPress())
    #expect(field.performKeyEquivalent(with: try shortcutEvent(18, modifiers: [.command, .shift])))
    #expect(field.hotKey == HotKey(parsing: "cmd + shift - 1"))
    #expect(!suspended)
  }

  @Test
  func movingBetweenFieldsAndLeavingWindowResumesHotkeys() {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
      styleMask: [.titled],
      backing: .buffered,
      defer: false
    )
    window.isReleasedWhenClosed = false
    let first = RecorderField()
    let second = RecorderField()
    window.contentView?.addSubview(first)
    window.contentView?.addSubview(second)
    defer { first.cancelRecording()
      second.cancelRecording()
      window.close()
    }
    var recording = [Bool]()
    first.onRecordingChange = { recording.append($0) }
    second.onRecordingChange = { recording.append($0) }
    #expect(first.accessibilityPerformPress())
    #expect(second.accessibilityPerformPress())
    #expect(!first.isRecording && second.isRecording)
    NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
    #expect(!second.isRecording)
    #expect(recording == [true, false, true, false])
    #expect(second.accessibilityPerformPress())
    second.removeFromSuperview()
    #expect(!second.isRecording)
    #expect(recording.suffix(2) == [true, false])
  }

  @Test
  func unchangedBindingDoesNotCancelInputAndPlainKeysDoNotCommit() throws {
    let field = RecorderField()
    defer { field.cancelRecording() }
    let value = HotKey(parsing: "cmd + shift - 1")
    field.hotKey = value
    #expect(field.accessibilityPerformPress())
    field.synchronizeBinding(value)
    #expect(field.isRecording)
    field.keyDown(with: try shortcutEvent(0))
    #expect(field.isRecording)
    #expect(field.hotKey == value)
  }

  // MARK: Private

  private func shortcutEvent(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "",
      charactersIgnoringModifiers: "",
      isARepeat: false,
      keyCode: keyCode
    ))
  }

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
