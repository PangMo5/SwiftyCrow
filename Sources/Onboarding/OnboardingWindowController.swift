// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import SwiftUI

/// The app delegate owns presentation so a menu-bar-only launch does not rely
/// on an unmounted SwiftUI label's task or onChange callbacks.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {

  // MARK: Internal

  func render(_ store: StoreOf<OnboardingFeature>, isPresented: Bool) {
    guard isPresented else {
      window?.close()
      return
    }
    guard window == nil else { return }
    let panel = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    panel.title = String(localized: "Quick Setup")
    panel.setAccessibilityIdentifier("onboarding-window")
    panel.isReleasedWhenClosed = false
    panel.delegate = self
    panel.contentView = NSHostingView(rootView: OnboardingView(store: store))
    panel.setContentSize(NSSize(width: 800, height: 570))
    panel.center()
    window = panel
    self.store = store
    WindowActivation.opened()
    panel.makeKeyAndOrderFront(nil)
  }

  func windowWillClose(_: Notification) {
    let closedStore = store
    window?.contentView = nil
    window = nil
    store = nil
    WindowActivation.closed()
    // Dispatch after AppKit finishes closing the window, before a selector is
    // presented. The parent consumes the one-shot first-capture intent here.
    Task { @MainActor in closedStore?.send(.closed) }
  }

  // MARK: Private

  private var window: NSWindow?
  private var store: StoreOf<OnboardingFeature>?

}
