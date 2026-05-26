import AppKit

/// Borderless NSPanel that can still become key. Required for `⌘,` and other
/// SwiftUI keyboard shortcuts inside the floating overlay to fire — without
/// this the panel only receives mouse events.
final class OverlayPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}
