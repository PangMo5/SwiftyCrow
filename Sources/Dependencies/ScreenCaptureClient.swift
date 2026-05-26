import AppKit
import ComposableArchitecture
import CoreGraphics
import Foundation
import ScreenCaptureKit

// MARK: - ScreenCaptureClient

struct ScreenCaptureClient {
  /// Captures a region of a display.
  ///
  /// `overlayFrame` is in global AppKit screen coordinates (points, bottom-left origin).
  /// Pass `nil` to capture the whole display.
  var captureImage: @Sendable (
    _ overlayFrame: CGRect?,
    _ excludingWindowIDs: [CGWindowID],
    _ displayID: CGDirectDisplayID?,
    _ excludingBundleIdentifier: String?
  ) async throws -> CGImage
}

// MARK: - ScreenCaptureError

enum ScreenCaptureError: Error, LocalizedError, Equatable {
  case emptyRegion
  case noDisplay
  case permissionRequired

  var errorDescription: String? {
    switch self {
    case .emptyRegion:
      "The capture region is empty."
    case .noDisplay:
      "No display available for capture."
    case .permissionRequired:
      "Screen Recording permission is required. Allow it in System Settings and restart the app."
    }
  }
}

// MARK: - ScreenCaptureClient + DependencyKey

extension ScreenCaptureClient: DependencyKey {
  static let liveValue = ScreenCaptureClient(
    captureImage: { overlayFrame, excludingWindowIDs, displayID, excludingBundleIdentifier in
      try await ScreenRecordingPermissionTracker.shared.requestIfNeeded()
      let content = try await SCShareableContent.excludingDesktopWindows(
        false,
        onScreenWindowsOnly: true
      )

      let display = content.displays.first { display in
        if let displayID { return display.displayID == displayID }
        return display.displayID == CGMainDisplayID()
      } ?? content.displays.first

      guard let display else {
        throw ScreenCaptureError.noDisplay
      }

      let nsScreen = NSScreen.screens.first { screen in
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return number?.uint32Value == display.displayID
      }
      let scale = nsScreen?.backingScaleFactor ?? 1

      let filter =
        if
          let excludingBundleIdentifier,
          let excludedApp = content.applications.first(where: { $0.bundleIdentifier == excludingBundleIdentifier })
        {
          SCContentFilter(display: display, excludingApplications: [excludedApp], exceptingWindows: [])
        } else {
          SCContentFilter(
            display: display,
            excludingWindows: content.windows.filter { excludingWindowIDs.contains($0.windowID) }
          )
        }

      let configuration = SCStreamConfiguration()
      configuration.pixelFormat = kCVPixelFormatType_32BGRA
      configuration.showsCursor = false

      if
        let overlayFrame,
        let nsScreen,
        let sourceRect = displayLocalRect(overlayFrame: overlayFrame, screen: nsScreen)
      {
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width * scale))
        configuration.height = max(1, Int(sourceRect.height * scale))
      } else {
        configuration.width = Int(Double(display.width) * scale)
        configuration.height = Int(Double(display.height) * scale)
      }

      return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
  )
}

extension DependencyValues {
  var screenCapture: ScreenCaptureClient {
    get { self[ScreenCaptureClient.self] }
    set { self[ScreenCaptureClient.self] = newValue }
  }
}

/// Converts an AppKit-global rectangle (points, bottom-left origin) into
/// a display-local rectangle in ScreenCaptureKit's top-left coordinate space.
private func displayLocalRect(overlayFrame: CGRect, screen: NSScreen) -> CGRect? {
  let screenFrame = screen.frame
  let intersection = overlayFrame.intersection(screenFrame)
  guard !intersection.isNull, !intersection.isEmpty else { return nil }
  return CGRect(
    x: intersection.minX - screenFrame.minX,
    y: screenFrame.maxY - intersection.maxY,
    width: intersection.width,
    height: intersection.height
  )
}

// MARK: - ScreenRecordingPermissionTracker

private actor ScreenRecordingPermissionTracker {

  // MARK: Internal

  static let shared = ScreenRecordingPermissionTracker()

  func requestIfNeeded() async throws {
    if CGPreflightScreenCaptureAccess() {
      return
    }

    if hasRequested {
      throw ScreenCaptureError.permissionRequired
    }
    hasRequested = true

    let granted = CGRequestScreenCaptureAccess()
    if !granted || !CGPreflightScreenCaptureAccess() {
      throw ScreenCaptureError.permissionRequired
    }
  }

  // MARK: Private

  private var hasRequested = false

}
