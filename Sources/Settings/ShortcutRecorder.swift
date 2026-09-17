// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import SwiftUI

// MARK: - ShortcutRecorder

/// A compact shortcut recorder field. Shows the combo with stable
/// English/QWERTY glyphs (e.g. `⌘S`) regardless of the active keyboard
/// layout, and records on a single click even when its window isn't key
/// (via `acceptsFirstMouse`) — which matters for this menu-bar
/// (LSUIElement) app. Input capture and conflict feedback follow Tatami's recorder.
struct ShortcutRecorder: View {

  // MARK: Internal

  let hotKey: HotKey?
  /// Action-specific VoiceOver label supplied by the row that owns this field.
  let accessibilityLabel: LocalizedStringResource
  /// Returns the name of another action already bound to a candidate combo,
  /// or nil if it's free (the recorder's own current key reads as free).
  var conflict: (HotKey) -> String? = { _ in nil }
  /// Commits a valid binding or clears it. Cancellation leaves the value unchanged.
  let onChange: (HotKey?) -> Void

  var body: some View {
    HStack(spacing: 4) {
      field
        .frame(width: 150, height: 24)
        .shortcutConflictPopover(item: $presentedConflict)

      Button {
        onChange(nil)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .font(.system(size: 14))
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Clear shortcut")
      .opacity(hotKey == nil ? 0 : 1)
      .disabled(hotKey == nil)
    }
  }

  // MARK: Private

  @State private var presentedConflict: ShortcutConflictPresentation?

  @Dependency(\.globalShortcuts) private var globalShortcuts

  /// Match the native capsule appearance used by the settings controls.
  @ViewBuilder
  private var field: some View {
    let representable = RecorderRepresentable(
      hotKey: hotKey,
      accessibilityLabel: String(localized: accessibilityLabel),
      conflict: conflict,
      isConflictPresented: presentedConflict != nil,
      onConflictPresentationChanged: { owner in
        presentedConflict = owner.map { ShortcutConflictPresentation(owner: $0) }
      },
      onRecordingChanged: { globalShortcuts.setEnabled(!$0) },
      onChange: onChange
    )
    if #available(macOS 26.0, *) {
      representable.glassEffect(.regular, in: Capsule())
    } else {
      representable.background(.ultraThinMaterial, in: Capsule())
    }
  }
}

// MARK: - RecorderRepresentable

private struct RecorderRepresentable: NSViewRepresentable {
  let hotKey: HotKey?
  let accessibilityLabel: String
  let conflict: (HotKey) -> String?
  let isConflictPresented: Bool
  let onConflictPresentationChanged: (String?) -> Void
  let onRecordingChanged: (Bool) -> Void
  let onChange: (HotKey?) -> Void

  static func dismantleNSView(_ field: RecorderField, coordinator _: ()) {
    field.cancelRecording()
    field.clearConflictFeedback()
  }

  func makeNSView(context _: Context) -> RecorderField {
    let field = RecorderField()
    field.setAccessibilityElement(true)
    field.setAccessibilityRole(.button)
    field.setAccessibilityLabel(accessibilityLabel)
    field.onChange = onChange
    field.conflict = conflict
    field.setConflictPresentationHandler(onConflictPresentationChanged)
    field.onRecordingChange = onRecordingChanged
    field.hotKey = hotKey
    field.updateAccessibilityValue(announce: false)
    return field
  }

  func updateNSView(_ field: RecorderField, context _: Context) {
    field.onChange = onChange
    field.conflict = conflict
    field.setConflictPresentationHandler(onConflictPresentationChanged)
    field.onRecordingChange = onRecordingChanged
    field.setAccessibilityLabel(accessibilityLabel)
    if !isConflictPresented {
      field.clearConflictFeedback()
    }
    // A clear or external edit ends the current input session. Merely redrawing
    // the same binding does not interrupt recording.
    field.synchronizeBinding(hotKey)
  }
}

// MARK: - RecorderField

final class RecorderField: NSView {

  // MARK: Internal

  var onChange: ((HotKey?) -> Void)?
  var conflict: ((HotKey) -> String?)?
  var onRecordingChange: ((Bool) -> Void)?

  var hotKey: HotKey? {
    didSet {
      guard hotKey != oldValue else { return }
      needsDisplay = true
      setAccessibilityValue(hotKey?.symbols ?? String(localized: "None"))
      if window != nil {
        NSAccessibility.post(element: self, notification: .valueChanged)
      }
    }
  }

  private(set) var isRecording = false {
    didSet {
      guard isRecording != oldValue else { return }
      needsDisplay = true
      updateAccessibilityValue()
      onRecordingChange?(isRecording)
    }
  }

  override var acceptsFirstResponder: Bool {
    true
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: 150, height: 24)
  }

  override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
    true
  }

  override func becomeFirstResponder() -> Bool {
    // Recording starts only on an explicit click (see mouseDown), not when
    // the window assigns us as its initial first responder on open.
    true
  }

  override func accessibilityPerformPress() -> Bool {
    window?.makeFirstResponder(self)
    startRecording()
    return true
  }

  override func resignFirstResponder() -> Bool {
    stopRecording()
    return true
  }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    if newWindow == nil {
      stopRecording()
      conflictPresenter.clear()
    }
    super.viewWillMove(toWindow: newWindow)
  }

  override func mouseDown(with _: NSEvent) {
    window?.makeFirstResponder(self)
    startRecording()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else { return super.performKeyEquivalent(with: event) }
    return record(event)
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording else { super.keyDown(with: event)
      return
    }
    _ = record(event)
  }

  func synchronizeBinding(_ value: HotKey?) {
    guard hotKey != value else { return }
    cancelRecording()
    hotKey = value
  }

  func cancelRecording() {
    stopRecording()
    conflictPresenter.clear()
  }

  override func draw(_: NSRect) {
    // The capsule behind us provides the fill; we draw the focus ring, the
    // combo text, and the clear button on top of it.
    if isRecording {
      let ring = NSBezierPath(
        roundedRect: bounds.insetBy(dx: 1, dy: 1),
        xRadius: bounds.height / 2,
        yRadius: bounds.height / 2
      )
      ring.lineWidth = 2
      NSColor.controlAccentColor.setStroke()
      ring.stroke()
    }

    let text: String
    let color: NSColor
    let bold: Bool
    let leadingSymbol: String?
    if conflictPresenter.isPresenting {
      text = String(localized: "In use")
      color = .systemOrange
      bold = true
      leadingSymbol = "exclamationmark.triangle.fill"
    } else if isRecording {
      text = String(localized: "Press shortcut…")
      color = .secondaryLabelColor
      bold = false
      leadingSymbol = nil
    } else if let hotKey {
      text = hotKey.symbols
      color = .labelColor
      bold = true
      leadingSymbol = nil
    } else {
      text = String(localized: "Set shortcut")
      color = .secondaryLabelColor
      bold = false
      leadingSymbol = nil
    }

    drawRecorderStatus(
      in: bounds,
      text: text,
      color: color,
      bold: bold,
      leadingSymbol: leadingSymbol,
      horizontalInset: 8
    )
  }

  // MARK: Fileprivate

  fileprivate func updateAccessibilityValue(announce: Bool = true) {
    let value = isRecording
      ? String(localized: "Recording")
      : hotKey?.symbols ?? String(localized: "None")
    setAccessibilityValue(value)
    if announce, window != nil {
      NSAccessibility.post(element: self, notification: .valueChanged)
    }
  }

  fileprivate func setConflictPresentationHandler(_ handler: @escaping (String?) -> Void) {
    conflictPresenter.onPresentationChanged = handler
  }

  fileprivate func clearConflictFeedback() {
    conflictPresenter.clear()
  }

  // MARK: Private

  /// Local keyDown monitor active only while recording. Capturing through a
  /// monitor (rather than keyDown/performKeyEquivalent) means special keys
  /// (Backspace, arrows, Return…) the SwiftUI responder chain would otherwise
  /// swallow still reach the recorder.
  private var monitor: Any?
  private var windowObserver: NSObjectProtocol?
  private lazy var conflictPresenter = ShortcutConflictPresenter(view: self)

  private func startRecording() {
    guard monitor == nil else { return }
    conflictPresenter.clear()
    isRecording = true
    monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
      guard let self, isRecording else { return event }
      guard event.window === window else {
        stopRecording()
        return event
      }
      return record(event) ? nil : event
    }
    if let window {
      windowObserver = NotificationCenter.default.addObserver(
        forName: NSWindow.didResignKeyNotification,
        object: window,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.stopRecording() }
      }
    }
  }

  private func stopRecording() {
    if let windowObserver {
      NotificationCenter.default.removeObserver(windowObserver)
      self.windowObserver = nil
    }
    if let monitor { NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    isRecording = false
  }

  /// Carbon modifier masks (cmd 256, shift 512, option 2048, control 4096).
  private func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> Int {
    var carbon = 0
    if flags.contains(.command) { carbon |= 256 }
    if flags.contains(.shift) { carbon |= 512 }
    if flags.contains(.option) { carbon |= 2048 }
    if flags.contains(.control) { carbon |= 4096 }
    return carbon
  }

  /// Records the combo from `event`, or beeps and keeps recording if it
  /// isn't a usable global shortcut. Returns whether the event was consumed.
  private func record(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape cancels without changing the stored shortcut.
      stopRecording()
      return true
    }
    let carbon = carbonModifiers(event.modifierFlags)
    // Function / navigation keys are fine bare; everything else needs a modifier.
    let standaloneOK = (96...122).contains(event.keyCode)
    guard carbon != 0 || standaloneOK else {
      NSSound.beep()
      return true
    }
    let candidate = HotKey(carbonKeyCode: Int(event.keyCode), carbonModifiers: carbon)
    // Already bound to another action — reject and say so. (The recorder's
    // own current key is excluded by the conflict closure, so it reads free.)
    if let owner = conflict?(candidate) {
      NSSound.beep()
      stopRecording()
      showConflict(owner)
      return true
    }
    hotKey = candidate
    onChange?(candidate)
    stopRecording()
    return true
  }

  private func showConflict(_ owner: String) {
    conflictPresenter.show(owner: owner)
  }

}

// MARK: - ShortcutConflictPresenter

/// Keeps conflict feedback compact at every width while making the complete
/// owner immediately readable. The recorder itself always shows the same short
/// warning; the popover and hover/VoiceOver help carry the untruncated detail.
@MainActor
private final class ShortcutConflictPresenter {

  // MARK: Lifecycle

  init(view: NSView) {
    self.view = view
  }

  // MARK: Internal

  private(set) var isPresenting = false
  var onPresentationChanged: ((String?) -> Void)?

  func show(owner: String) {
    clear()
    guard let view else { return }

    let message = String(localized: "This shortcut is already used by \(owner).")
    isPresenting = true
    previousAccessibilityValue = view.accessibilityValue()
    view.toolTip = message
    view.setAccessibilityHelp(message)
    view.setAccessibilityValue(message)
    view.needsDisplay = true
    NSAccessibility.post(
      element: NSApp as Any,
      notification: .announcementRequested,
      userInfo: [
        .announcement: message,
        .priority: NSAccessibilityPriorityLevel.high.rawValue,
      ]
    )
    onPresentationChanged?(owner)

    resetTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(4))
      guard !Task.isCancelled else { return }
      self?.clear()
    }
  }

  func clear() {
    let wasPresenting = isPresenting
    resetTask?.cancel()
    resetTask = nil
    isPresenting = false
    view?.toolTip = nil
    view?.setAccessibilityHelp(nil)
    if wasPresenting {
      view?.setAccessibilityValue(previousAccessibilityValue)
    }
    previousAccessibilityValue = nil
    view?.needsDisplay = true
    if wasPresenting {
      onPresentationChanged?(nil)
    }
  }

  // MARK: Private

  private weak var view: NSView?
  private var previousAccessibilityValue: Any?
  private var resetTask: Task<Void, Never>?
}

// MARK: - ShortcutConflictPresentation

private struct ShortcutConflictPresentation: Identifiable {
  let id = UUID()
  let owner: String
}

extension View {
  fileprivate func shortcutConflictPopover(
    item: Binding<ShortcutConflictPresentation?>
  ) -> some View {
    popover(
      item: item,
      attachmentAnchor: .rect(.bounds),
      arrowEdge: .trailing
    ) { presentation in
      ShortcutConflictPopover(owner: presentation.owner)
    }
  }
}

// MARK: - ShortcutConflictPopover

private struct ShortcutConflictPopover: View {
  let owner: String

  var body: some View {
    Label {
      Text(
        "This shortcut is already used by \(owner).",
        comment: "Shortcut recorder conflict. The variable is the action already using the shortcut."
      )
      .fixedSize(horizontal: false, vertical: true)
    } icon: {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
    }
    .padding(12)
    .frame(width: 280, alignment: .leading)
  }
}

@MainActor
private func drawRecorderStatus(
  in bounds: NSRect,
  text: String,
  color: NSColor,
  bold: Bool,
  leadingSymbol: String?,
  horizontalInset: CGFloat
) {
  let style = NSMutableParagraphStyle()
  style.alignment = .center
  style.lineBreakMode = .byTruncatingTail
  let attributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
    .foregroundColor: color,
    .paragraphStyle: style,
  ]
  let nsText = text as NSString
  let textSize = nsText.size(withAttributes: attributes)
  let iconSize: CGFloat = leadingSymbol == nil ? 0 : 12
  let spacing: CGFloat = leadingSymbol == nil ? 0 : 4
  let availableWidth = max(0, bounds.width - horizontalInset * 2)
  let textWidth = min(textSize.width, max(0, availableWidth - iconSize - spacing))
  let totalWidth = iconSize + spacing + textWidth
  let originX = max(horizontalInset, (bounds.width - totalWidth) / 2)

  if
    let leadingSymbol,
    let image = NSImage(systemSymbolName: leadingSymbol, accessibilityDescription: nil)?
      .withSymbolConfiguration(
        NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
          .applying(.init(hierarchicalColor: color))
      )
  {
    image.draw(
      in: NSRect(
        x: originX,
        y: (bounds.height - iconSize) / 2,
        width: iconSize,
        height: iconSize
      ),
      from: .zero,
      operation: .sourceOver,
      fraction: 1,
      respectFlipped: true,
      hints: nil
    )
  }

  let textX = originX + iconSize + spacing
  nsText.draw(
    in: NSRect(
      x: textX,
      y: (bounds.height - textSize.height) / 2,
      width: textWidth,
      height: textSize.height
    ),
    withAttributes: attributes
  )
}
