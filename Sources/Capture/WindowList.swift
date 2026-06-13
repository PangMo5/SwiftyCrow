import AppKit
import CoreGraphics

// MARK: - PickableWindow

/// An on-screen window the user can target, with its frame already converted to
/// AppKit's global coordinate space (points, bottom-left origin) so it can be
/// hit-tested against `NSEvent.mouseLocation` and drawn in a selector panel.
struct PickableWindow: Equatable, Sendable {
  var id: CGWindowID
  var frame: CGRect
}

// MARK: - Enumeration

/// On-screen, normal-layer windows in front-to-back z-order, excluding our own
/// app's windows (the selector panels). Uses `CGWindowListCopyWindowInfo`, which
/// needs no Accessibility permission — only the geometry and window numbers,
/// which are available with the Screen Recording access the app already holds.
func onScreenWindows(excludingPID pid: pid_t) -> [PickableWindow] {
  let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
  guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[CFString: Any]] else {
    return []
  }

  let flipHeight = coordinateFlipHeight()

  return info.compactMap { entry -> PickableWindow? in
    guard
      (entry[kCGWindowLayer] as? Int) == 0,
      (entry[kCGWindowOwnerPID] as? pid_t) != pid,
      (entry[kCGWindowAlpha] as? Double ?? 1) > 0.01,
      let number = entry[kCGWindowNumber] as? CGWindowID,
      let boundsDict = entry[kCGWindowBounds] as? NSDictionary,
      let cgBounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
    else { return nil }

    // Skip tiny helper/status windows that aren't meaningful capture targets.
    guard cgBounds.width >= 40, cgBounds.height >= 40 else { return nil }

    let frame = CGRect(
      x: cgBounds.minX,
      y: flipHeight - cgBounds.maxY,
      width: cgBounds.width,
      height: cgBounds.height
    )
    return PickableWindow(id: number, frame: frame)
  }
}

/// The front-most window under `point` (AppKit-global coordinates). `windows`
/// must be in front-to-back order, as `onScreenWindows` returns them.
func windowUnderCursor(_ windows: [PickableWindow], at point: CGPoint) -> PickableWindow? {
  windows.first { $0.frame.contains(point) }
}

// MARK: - Coordinate flip

/// The flip axis between `CGWindowList`'s top-left global space and AppKit's
/// bottom-left global space: the height of the origin screen (the primary
/// display, whose lower-left is AppKit's (0,0) and whose top-left is CG's
/// (0,0)). Shared across all displays, so it converts every window correctly.
private func coordinateFlipHeight() -> CGFloat {
  if let origin = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
    return origin.frame.height
  }
  return NSScreen.main?.frame.height ?? 0
}
