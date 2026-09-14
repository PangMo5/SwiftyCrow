// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import Dependencies
import DependenciesMacros
import SwiftUI

// MARK: - WhatsNewClient

/// Mirrors Tatami: fresh installs only record the version; existing users see
/// highlights once per major/minor release. Patch releases do not repeat them.
@DependencyClient
struct WhatsNewClient: Sendable {
  var showIfNeeded: @Sendable (_ hasExistingConfiguration: Bool) async -> Void
  var show: @Sendable () async -> Void

  static func shouldShow(current: String, lastShown: String?, hasExistingConfiguration: Bool) -> Bool {
    guard !current.isEmpty, hasExistingConfiguration else { return false }
    return lastShown.map { $0.split(separator: ".").prefix(2) != current.split(separator: ".").prefix(2) } ?? true
  }
}

// MARK: DependencyKey

extension WhatsNewClient: DependencyKey {
  static let liveValue = WhatsNewClient(
    showIfNeeded: { await WhatsNewController.shared.showIfNeeded(hasExistingConfiguration: $0) },
    show: { await WhatsNewController.shared.show() }
  )
  static let testValue = WhatsNewClient(showIfNeeded: { _ in }, show: { })
}

extension DependencyValues {
  var whatsNew: WhatsNewClient {
    get { self[WhatsNewClient.self] }
    set { self[WhatsNewClient.self] = newValue }
  }
}

// MARK: - WhatsNewController

@MainActor
private final class WhatsNewController: NSObject, NSWindowDelegate {

  // MARK: Internal

  static let shared = WhatsNewController()

  func showIfNeeded(hasExistingConfiguration: Bool) {
    guard !version.isEmpty else { return }
    let previous = UserDefaults.standard.string(forKey: lastShownKey)
    UserDefaults.standard.set(version, forKey: lastShownKey)
    if
      WhatsNewClient
        .shouldShow(current: version, lastShown: previous, hasExistingConfiguration: hasExistingConfiguration) { show() }
  }

  func show() {
    if let window {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
      return
    }
    let panel = NSWindow(
      contentRect: .zero,
      styleMask: [.titled, .closable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.title = String(localized: "What’s New")
    panel.titlebarAppearsTransparent = true
    panel.titleVisibility = .hidden
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: WhatsNewView(version: version, onDone: { [weak panel] in panel?.close() }))
    panel.setContentSize(NSSize(width: 540, height: 600))
    panel.center()
    window = panel
    NSApp.activate(ignoringOtherApps: true)
    panel.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_: Notification) {
    window = nil
  }

  // MARK: Private

  private var window: NSWindow?
  private let lastShownKey = "whatsNew.lastShownVersion"

  private var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }

}
