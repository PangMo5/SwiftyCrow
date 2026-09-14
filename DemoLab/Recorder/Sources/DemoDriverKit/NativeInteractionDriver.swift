// SPDX-FileCopyrightText: 2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - NativeInteractionDriver

/// Drives the fixture apps through their native controls. No model-state injection.
@MainActor
public enum NativeInteractionDriver {

  // MARK: Public

  public static func hostInputSessionMetadata() throws -> [String: Any]? {
    try mouseRelay()?.sessionMetadata()
  }

  /// Point-based entry points are used by the owned host input service after
  /// it validates the VM window and converts guest coordinates into its view.
  public static func movePointer(to point: CGPoint) throws {
    try move(to: point)
  }

  public static func click(at point: CGPoint) throws {
    try clickPoint(point)
  }

  /// Host input supplies a validator that rejects focus or geometry changes
  /// before each native event, including intermediate drag samples.
  public static func setInputValidation(_ validate: @escaping () throws -> Void) {
    inputValidation = validate
  }

  public static func closeMainWindow(bundleIdentifier: String) throws {
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
      app.activate()
    else { throw InteractionError("could not activate app before closing its window") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard
      let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first,
      let raw = attribute(window, kAXCloseButtonAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else { throw InteractionError("app has no closable window") }
    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    else { throw InteractionError("could not raise window before closing") }
    Thread.sleep(forTimeInterval: 0.2)
    try clickPoint(center(of: unsafeDowncast(raw, to: AXUIElement.self)))
  }

  /// Arrange a source window through macOS Accessibility, then read its actual frame.
  public static func arrangeMainWindow(bundleIdentifier: String, frame: CGRect) throws -> CGRect {
    guard
      KeyDriver.isTrusted,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
      app.activate()
    else { throw InteractionError("could not activate source app") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard
      let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
      let window = windows.first
    else { throw InteractionError("source app has no window") }
    var position = frame.origin
    var size = frame.size
    guard
      let positionValue = AXValueCreate(.cgPoint, &position),
      let sizeValue = AXValueCreate(.cgSize, &size),
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
      // Resize before positioning. AppKit otherwise clamps the origin to
      // keep the old, larger window on screen, then retains that origin.
      AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue) == .success,
      // The first resize can itself be constrained by the old origin.
      // Apply the target size once the target origin is in place.
      AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue) == .success,
      AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
    else {
      throw InteractionError("could not arrange source window")
    }
    Thread.sleep(forTimeInterval: 0.3)
    let actual = try bounds(of: window)
    guard
      abs(actual.minX - frame.minX) < 2, abs(actual.minY - frame.minY) < 2,
      abs(actual.width - frame.width) < 2, abs(actual.height - frame.height) < 2
    else {
      throw InteractionError("source window did not adopt requested frame: \(actual)")
    }
    return actual
  }

  /// Close the identified settings window through its real close control.
  /// Hiding an app is insufficient: activation would restore its windows.
  public static func closeWindow(bundleIdentifier: String, identifier: String) throws {
    let window = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard
      attribute(window, kAXRoleAttribute) as? String == kAXWindowRole,
      let raw = attribute(window, kAXCloseButtonAttribute),
      CFGetTypeID(raw) == AXUIElementGetTypeID()
    else {
      throw InteractionError("identified window has no close button: \(identifier)")
    }
    guard
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first,
      app.activate()
    else { throw InteractionError("could not activate app before closing \(identifier)") }
    Thread.sleep(forTimeInterval: 0.12)
    try clickPoint(center(of: unsafeDowncast(raw, to: AXUIElement.self)))
  }

  public static func frontmostBundleIdentifier() -> String? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute as CFString, &value) ==
      .success,
      let value, CFGetTypeID(value) == AXUIElementGetTypeID()
    else { return nil }
    var pid: pid_t = 0
    guard AXUIElementGetPid(unsafeDowncast(value, to: AXUIElement.self), &pid) == .success else { return nil }
    return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
  }

  /// Use the application's standard Accessibility hidden state. This does not
  /// depend on the source app providing a Hide menu item or keyboard shortcut.
  public static func hideApplication(bundleIdentifier: String) throws {
    guard
      KeyDriver.isTrusted,
      let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else {
      throw InteractionError("could not find app to hide")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard AXUIElementSetAttributeValue(root, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success else {
      throw InteractionError("could not set application hidden state")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + 3
    while attribute(root, kAXHiddenAttribute) as? Bool != true {
      guard ProcessInfo.processInfo.systemUptime < deadline else { throw InteractionError("application did not become hidden") }
      Thread.sleep(forTimeInterval: 0.1)
    }
  }

  public static func click(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    let point = try center(of: target)
    // Enter the open submenu horizontally before moving down its rows.
    // A diagonal path through a sibling parent item can close this submenu.
    if
      attribute(target, kAXRoleAttribute) as? String == kAXMenuItemRole,
      let rawParent = attribute(target, kAXParentAttribute),
      CFGetTypeID(rawParent) == AXUIElementGetTypeID(),
      let cursor = CGEvent(source: nil)?.location
    {
      let menu = unsafeDowncast(rawParent, to: AXUIElement.self)
      let frame = try bounds(of: menu)
      if !frame.contains(cursor) {
        try move(to: CGPoint(x: point.x, y: min(max(cursor.y, frame.minY + 5), frame.maxY - 5)))
      }
    }
    try clickPoint(point)
  }

  public static func isMenuItem(bundleIdentifier: String, identifier: String) throws -> Bool {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    return attribute(target, kAXRoleAttribute) as? String == kAXMenuItemRole
  }

  public static func rightClick(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    let point = try center(of: target)
    try move(to: point)
    guard
      let down = CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: point, mouseButton: .right),
      let up = CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: point, mouseButton: .right)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    up.flags = []
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.25)
  }

  public static func prepareSettingsWindow(bundleIdentifier: String) throws {
    let window = try element(bundleIdentifier: bundleIdentifier, identifier: "main")
    var frame = try bounds(of: window)
    try drag(from: CGPoint(x: frame.minX + 110, y: frame.minY + 15), to: CGPoint(x: 260, y: 125))
    frame = try bounds(of: window)
    try drag(from: CGPoint(x: frame.maxX - 2, y: frame.maxY - 2), to: CGPoint(x: 1770, y: 1050))
  }

  public static func clickSettingsWindowTitle(bundleIdentifier: String) throws {
    let window = try element(bundleIdentifier: bundleIdentifier, identifier: "main")
    // Auto-opened fixture apps can cover Tatami during launch. Raise the
    // actual window first so the title click cannot hit an app behind it.
    guard AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success else {
      throw InteractionError("could not raise the Tatami window")
    }
    Thread.sleep(forTimeInterval: 0.12)
    let sheet = (attribute(window, kAXChildrenAttribute) as? [AXUIElement])?
      .first { attribute($0, kAXRoleAttribute) as? String == kAXSheetRole }
    let frame = try bounds(of: sheet ?? window)
    try clickPoint(CGPoint(x: sheet == nil ? frame.minX + 110 : frame.midX, y: frame.minY + 15))
  }

  public static func clickWindowTitle(bundleIdentifier: String) throws {
    let frame = try windowFrame(bundleIdentifier: bundleIdentifier)
    try clickPoint(CGPoint(x: frame.midX, y: frame.minY + 14))
  }

  public static func controlFrame(bundleIdentifier: String, identifier: String) throws -> CGRect {
    try bounds(of: element(
      bundleIdentifier: bundleIdentifier,
      identifier: identifier
    ))
  }

  public static func mainWindowFrame(bundleIdentifier: String) throws -> CGRect {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else { throw InteractionError("app is not running") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard let window = (attribute(root, kAXWindowsAttribute) as? [AXUIElement])?.first
    else { throw InteractionError("app has no window") }
    return try bounds(of: window)
  }

  public static func hover(bundleIdentifier: String, identifier: String) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    try reveal(target)
    try move(to: center(of: target))
  }

  public static func windowFrame(bundleIdentifier: String) throws -> CGRect {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else { throw InteractionError("app is not running") }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    guard
      let windows = attribute(root, kAXWindowsAttribute) as? [AXUIElement],
      // Hidden or occluded SwiftUI content may have no AX descendants. The
      // fixture assigns identity to NSWindow itself at creation time.
      let window = windows
        .first(where: { (attribute($0, kAXIdentifierAttribute) as? String)?.hasPrefix(bundleIdentifier + ".window.") == true })
    else { throw InteractionError("app has no identified demo window") }
    return try bounds(of: window)
  }

  public static func drag(from: CGPoint, to: CGPoint) throws {
    if let relay = try mouseRelay() { try relay.drag(from: from, to: to)
      return
    }
    try move(to: from)
    guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: from, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    try inputValidation?()
    down.post(tap: .cghidEventTap)
    var released = false
    defer {
      if
        !released, let location = CGEvent(source: nil)?.location,
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: location, mouseButton: .left)
      { up.flags = []
        up.post(tap: .cghidEventTap)
      }
    }
    Thread.sleep(forTimeInterval: 0.12)
    for step in 1...40 {
      let t = Double(step) / 40
      let eased = t * t * (3 - 2 * t)
      let point = CGPoint(x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased)
      guard
        let drag = CGEvent(
          mouseEventSource: nil,
          mouseType: .leftMouseDragged,
          mouseCursorPosition: point,
          mouseButton: .left
        )
      else { throw DriverError.eventSourceUnavailable }
      drag.flags = []
      try inputValidation?()
      drag.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.018)
    }
    Thread.sleep(forTimeInterval: 0.35)
    guard let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: to, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    up.flags = []
    try inputValidation?()
    up.post(tap: .cghidEventTap)
    released = true
    Thread.sleep(forTimeInterval: 0.5)
  }

  public static func snapshot(bundleIdentifier: String) throws -> String {
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    else { throw InteractionError("app is not running") }
    var lines = [String]()
    func visit(_ node: AXUIElement, _ depth: Int) {
      guard depth < 24, lines.count < 650 else { return }
      let role = attribute(node, kAXRoleAttribute) as? String ?? "?"
      let attrs = [kAXIdentifierAttribute, kAXTitleAttribute, kAXValueAttribute, kAXHelpAttribute, kAXDescriptionAttribute]
        .compactMap { key -> String? in guard let value = attribute(node, key) as? String,!value.isEmpty else { return nil }
          return "\(key)=\(value.prefix(180))"
        }
      lines.append(String(repeating: " ", count: depth) + role + " " + attrs.joined(separator: " | "))
      for child in attribute(node, kAXChildrenAttribute) as? [AXUIElement] ?? [] { visit(child, depth + 1) }
    }
    visit(AXUIElementCreateApplication(app.processIdentifier), 0)
    return lines.joined(separator: "\n")
  }

  public static func type(_ text: String, intervalMilliseconds: Int) throws {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    for character in text {
      let units = Array(String(character).utf16)
      guard
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false)
      else { throw DriverError.eventSourceUnavailable }
      units.withUnsafeBufferPointer { buffer in
        down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
        up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress!)
      }
      down.flags = []
      up.flags = []
      down.post(tap: .cghidEventTap)
      up.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: Double(intervalMilliseconds) / 1000)
    }
  }

  public static func scroll(bundleIdentifier: String, identifier: String, pixels: Int) throws {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    var visible = try bounds(of: target)
    var ancestor = target
    for _ in 0..<30 {
      if attribute(ancestor, kAXRoleAttribute) as? String == kAXWindowRole {
        visible = visible.intersection(try bounds(of: ancestor).insetBy(dx: 30, dy: 80))
        break
      }
      guard let raw = attribute(ancestor, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
      ancestor = unsafeDowncast(raw, to: AXUIElement.self)
    }
    guard !visible.isNull, !visible.isEmpty else { throw InteractionError("scroll target has no visible viewport") }
    try scroll(at: CGPoint(x: visible.midX, y: visible.midY), pixels: pixels)
  }

  public static func scroll(at point: CGPoint, pixels: Int) throws {
    if let relay = try mouseRelay() { try relay.scroll(at: point, pixels: pixels)
      return
    }
    try move(to: point)
    for _ in 0..<12 {
      guard
        let event = CGEvent(
          scrollWheelEvent2Source: nil,
          units: .pixel,
          wheelCount: 1,
          wheel1: Int32(pixels / 12),
          wheel2: 0,
          wheel3: 0
        )
      else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      try inputValidation?()
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.025)
    }
  }

  public static func isEnabled(bundleIdentifier: String, identifier: String) throws -> Bool {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard let enabled = attribute(target, kAXEnabledAttribute) as? Bool else {
      throw InteractionError("native control enabled state is unavailable: \(identifier)")
    }
    return enabled
  }

  public static func value(bundleIdentifier: String, identifier: String) throws -> String {
    let target = try element(bundleIdentifier: bundleIdentifier, identifier: identifier)
    guard let value = attribute(target, kAXValueAttribute) as? String else {
      throw InteractionError("native control value is unavailable: \(identifier)")
    }
    return value
  }

  // MARK: Private

  private static var relayClient: HostMouseRelayClient?
  private static var inputValidation: (() throws -> Void)?

  private static func mouseRelay() throws -> HostMouseRelayClient? {
    if relayClient == nil { relayClient = try HostMouseRelayClient.fromEnvironment() }
    return relayClient
  }

  private static func clickPoint(_ point: CGPoint) throws {
    if let relay = try mouseRelay() { try relay.click(at: point)
      return
    }
    try move(to: point)
    guard
      let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
    else { throw DriverError.eventSourceUnavailable }
    down.flags = []
    up.flags = []
    try inputValidation?()
    down.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.06)
    // Always release a pressed button, even if the VM lost focus meanwhile.
    up.post(tap: .cghidEventTap)
    Thread.sleep(forTimeInterval: 0.12)
  }

  /// AX exposes controls outside a scroll viewport too. Scroll them into view
  /// before posting a real mouse event; an offscreen coordinate is not a click.
  private static func reveal(_ target: AXUIElement) throws {
    // An automatically hidden menu bar still exposes AX items above the
    // display. Reveal the real bar before using the item's mouse coordinates.
    if attribute(target, kAXRoleAttribute) as? String == kAXMenuBarItemRole {
      let display = CGDisplayBounds(CGMainDisplayID())
      let frame = try bounds(of: target)
      if frame.minY < display.minY {
        try move(to: CGPoint(x: min(max(frame.midX, display.minX + 1), display.maxX - 1), y: display.minY + 1))
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !display.contains(try center(of: target)) {
          guard ContinuousClock.now < deadline else { throw InteractionError("menu bar item did not become visible") }
          Thread.sleep(forTimeInterval: 0.05)
        }
      }
    }
    var ancestors = [AXUIElement]()
    var node = target
    for _ in 0..<24 {
      guard let raw = attribute(node, kAXParentAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { break }
      node = unsafeDowncast(raw, to: AXUIElement.self)
      // A popup menu floats above its owner's scroll view; scrolling that
      // view cannot reveal a submenu item and can instead close the menu.
      if attribute(node, kAXRoleAttribute) as? String == kAXMenuRole { return }
      if attribute(node, kAXRoleAttribute) as? String == kAXScrollAreaRole { ancestors.append(node) }
    }
    for ancestor in ancestors.reversed() {
      var visible = false
      for _ in 0..<10 {
        let frame = try bounds(of: target)
        let viewport = try bounds(of: ancestor).insetBy(dx: 6, dy: 12)
        if viewport.contains(CGPoint(x: frame.midX, y: frame.midY)) { visible = true
          break
        }
        let delta: Double
        if frame.midY > viewport.maxY { delta = -min(400, max(100, frame.maxY - viewport.maxY + 24)) }
        else if frame.midY < viewport.minY { delta = min(400, max(100, viewport.minY - frame.minY + 24)) }
        else { throw InteractionError("control is outside the horizontal viewport") }
        try move(to: CGPoint(x: viewport.midX, y: viewport.midY))
        for _ in 0..<8 {
          guard
            let event = CGEvent(
              scrollWheelEvent2Source: nil,
              units: .pixel,
              wheelCount: 1,
              wheel1: Int32(delta / 8),
              wheel2: 0,
              wheel3: 0
            )
          else { throw DriverError.eventSourceUnavailable }
          event.flags = []
          event.post(tap: .cghidEventTap)
          Thread.sleep(forTimeInterval: 0.025)
        }
        Thread.sleep(forTimeInterval: 0.18)
      }
      guard visible else { throw InteractionError("control did not scroll into view") }
    }
  }

  private static func element(bundleIdentifier: String, identifier: String) throws -> AXUIElement {
    guard KeyDriver.isTrusted else { throw DriverError.notTrusted }
    guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
      throw InteractionError("app is not running: \(bundleIdentifier)")
    }
    let root = AXUIElementCreateApplication(app.processIdentifier)
    let deadline = ContinuousClock.now.advanced(by: .seconds(4))
    repeat {
      if let found = search(root, identifier: identifier, depth: 0) { return found }
      Thread.sleep(forTimeInterval: 0.08)
    } while ContinuousClock.now < deadline
    throw InteractionError("native control not found: \(bundleIdentifier) / \(identifier)")
  }

  private static func search(_ element: AXUIElement, identifier: String, depth: Int) -> AXUIElement? {
    guard depth < 30 else { return nil }
    if identifier.hasPrefix("sheet:") {
      if attribute(element, kAXRoleAttribute) as? String == kAXSheetRole {
        return search(element, identifier: String(identifier.dropFirst(6)), depth: depth + 1)
      }
      for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = search(child, identifier: identifier, depth: depth + 1) { return found }
      }
      return nil
    }
    let selectors = [
      "title:": kAXTitleAttribute,
      "help:": kAXHelpAttribute,
      "text:": kAXValueAttribute,
      "description:": kAXDescriptionAttribute,
    ]
    let roleSelectors = ["button:": kAXButtonRole, "heading:": "AXHeading"]
    if let selector = roleSelectors.first(where: { identifier.hasPrefix($0.key) }) {
      let label = String(identifier.dropFirst(selector.key.count))
      if
        attribute(element, kAXRoleAttribute) as? String == selector.value,
        [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
          .contains(where: { attribute(element, $0) as? String == label })
      {
        return element
      }
    } else if let selector = selectors.first(where: { identifier.hasPrefix($0.key) }) {
      if attribute(element, selector.value) as? String == String(identifier.dropFirst(selector.key.count)) { return element }
    } else if attribute(element, kAXIdentifierAttribute) as? String == identifier { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
      if let found = search(child, identifier: identifier, depth: depth + 1) { return found }
    }
    return nil
  }

  private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
  }

  private static func center(of element: AXUIElement) throws -> CGPoint {
    let frame = try bounds(of: element)
    return CGPoint(x: frame.midX, y: frame.midY)
  }

  private static func bounds(of element: AXUIElement) throws -> CGRect {
    guard
      let rawPosition = attribute(element, kAXPositionAttribute),
      let rawSize = attribute(element, kAXSizeAttribute),
      CFGetTypeID(rawPosition) == AXValueGetTypeID(), CFGetTypeID(rawSize) == AXValueGetTypeID()
    else { throw InteractionError("control has no accessible bounds") }
    var position = CGPoint.zero
    var size = CGSize.zero
    guard
      AXValueGetValue(unsafeDowncast(rawPosition, to: AXValue.self), .cgPoint, &position),
      AXValueGetValue(unsafeDowncast(rawSize, to: AXValue.self), .cgSize, &size), size.width > 0, size.height > 0
    else { throw InteractionError("control has invalid bounds") }
    return CGRect(origin: position, size: size)
  }

  private static func move(to point: CGPoint) throws {
    if let relay = try mouseRelay() { try relay.move(to: point)
      return
    }
    guard let start = CGEvent(source: nil)?.location else { throw DriverError.eventSourceUnavailable }
    for step in 1...18 {
      let t = Double(step) / 18
      let eased = t * t * (3 - 2 * t)
      let next = CGPoint(x: start.x + (point.x - start.x) * eased, y: start.y + (point.y - start.y) * eased)
      guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: next, mouseButton: .left)
      else { throw DriverError.eventSourceUnavailable }
      event.flags = []
      try inputValidation?()
      event.post(tap: .cghidEventTap)
      Thread.sleep(forTimeInterval: 0.012)
    }
  }
}

// MARK: - InteractionError

public struct InteractionError: Error, CustomStringConvertible {
  public init(_ description: String) {
    self.description = description
  }

  public let description: String
}
