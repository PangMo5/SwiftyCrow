// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import CoreGraphics
import Foundation

// MARK: - PointerError

public enum PointerError: Error, Equatable, CustomStringConvertible {
  case noDisplays
  case displayOutOfRange(index: Int, count: Int)
  case warpFailed(CGError)
  case positionUnreadable
  case warpDidNotTake(expected: CGPoint, actual: CGPoint)

  // MARK: Public

  public var description: String {
    switch self {
    case .noDisplays:
      "no displays are attached"
    case .displayOutOfRange(let index, let count):
      "display index \(index) is out of range — \(count) display(s) attached, indices 0...\(count - 1)"
    case .warpFailed(let error):
      "CGWarpMouseCursorPosition failed with CGError \(error.rawValue)"
    case .positionUnreadable:
      "the cursor position could not be read back, so the warp could not be confirmed"
    case .warpDidNotTake(let expected, let actual):
      "the cursor did not move: asked for (\(Int(expected.x)), \(Int(expected.y))), "
        + "it sits at (\(Int(actual.x)), \(Int(actual.y)))"
    }
  }

}

// MARK: - Pointer

/// Cursor placement.
///
/// This matters for more than looks: Tatami puts a dynamic workspace on the
/// display under the cursor, so a scene that means "create this on the right
/// display" has to move the cursor there first, exactly as a person would.
public enum Pointer {

  // MARK: Public

  /// Warps the cursor to a point in global display coordinates (top-left
  /// origin, the space `CGWarpMouseCursorPosition` uses), then confirms it
  /// landed. A blocked warp throws instead of quietly leaving the cursor put.
  public static func warp(to point: CGPoint) throws {
    let status = CGWarpMouseCursorPosition(point)
    guard status == .success else { throw PointerError.warpFailed(status) }
    // A warp detaches the physical mouse from the cursor for a moment;
    // re-associating hands control straight back.
    CGAssociateMouseAndMouseCursorPosition(1)
    guard let actual = CGEvent(source: nil)?.location else { throw PointerError.positionUnreadable }
    guard abs(actual.x - point.x) <= tolerance, abs(actual.y - point.y) <= tolerance else {
      throw PointerError.warpDidNotTake(expected: point, actual: actual)
    }
  }

  /// Warps the cursor to a unit position on one display, where (0, 0) is the
  /// display's top-left corner and (1, 1) its bottom-right.
  ///
  /// `displayIndex` is zero-based into `NSScreen.screens` sorted by
  /// (frame.minX, frame.minY) — the same order Tatami's `DisplayClient` uses,
  /// so display 0 here and display 0 there are the same screen.
  @MainActor
  public static func warp(toDisplayIndex displayIndex: Int, unitX: Double, unitY: Double) throws {
    let screens = NSScreen.screens.sorted {
      ($0.frame.minX, $0.frame.minY) < ($1.frame.minX, $1.frame.minY)
    }
    guard let primary = NSScreen.screens.first, !screens.isEmpty else { throw PointerError.noDisplays }
    guard screens.indices.contains(displayIndex) else {
      throw PointerError.displayOutOfRange(index: displayIndex, count: screens.count)
    }

    // Cocoa's bottom-left origin -> the top-left origin the warp expects.
    let frame = screens[displayIndex].frame
    let top = primary.frame.maxY - frame.maxY
    let x = frame.minX + clamped(unitX) * frame.width
    let y = top + clamped(unitY) * frame.height

    // Stay a point inside the frame: Tatami resolves the display under the
    // cursor with `frame.contains`, which excludes the far edges, so a cursor
    // parked exactly on an edge reads as the neighbouring display or none.
    let point = CGPoint(
      x: min(max(x, frame.minX + edgeInset), frame.maxX - edgeInset),
      y: min(max(y, top + edgeInset), top + frame.height - edgeInset)
    )
    try warp(to: point)
  }

  // MARK: Private

  /// How far the cursor may sit from the requested point before the warp counts
  /// as having failed.
  private static let tolerance = 2.0

  private static let edgeInset = 1.0

  private static func clamped(_ unit: Double) -> Double {
    min(max(unit, 0), 1)
  }

}
