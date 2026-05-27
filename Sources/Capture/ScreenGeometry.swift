import AppKit
import CoreGraphics

/// The display whose frame overlaps `frame` the most — used to pick the right
/// `CGDirectDisplayID` for a capture that may span or sit on a non-main screen.
func displayID(coveringMostOf frame: CGRect) -> CGDirectDisplayID? {
  let screen = NSScreen.screens
    .map { ($0, frame.intersection($0.frame)) }
    .map { ($0.0, $0.1.width * $0.1.height) }
    .max { $0.1 < $1.1 }?
    .0
  guard
    let screen,
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
  else { return nil }
  return CGDirectDisplayID(truncating: number)
}
