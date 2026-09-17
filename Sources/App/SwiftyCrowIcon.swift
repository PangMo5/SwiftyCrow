// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit

@MainActor
enum SwiftyCrowIcon {
  static let brandImage = NSImage(named: "AppIdentity")!

  /// A small vector mark derived from the app icon. The exact same template is
  /// used in the status item and the onboarding menu-bar illustration.
  static let menuBarImage: NSImage = {
    let image = NSImage(named: "MenuBarMark")!
    image.size = NSSize(width: 20, height: 20)
    image.isTemplate = true
    image.accessibilityDescription = "SwiftyCrow"
    return image
  }()
}
