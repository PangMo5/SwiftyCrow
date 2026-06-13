import AppKit
import SwiftUI

// MARK: - ShortcutRecorder

/// A compact recorder field, styled to match the app's Liquid Glass UI. Shows
/// the shortcut with stable English/QWERTY glyphs (e.g. `⌘S`) regardless of the
/// active keyboard layout, and records on a single click even when its window
/// isn't key (via `acceptsFirstMouse`) — which matters for this menu-bar app.
struct ShortcutRecorder: View {
  let hotKey: HotKey?
  /// Returns the name of another action already bound to a candidate combo, or
  /// nil if it's free (the recorder's own current key is treated as free).
  var conflict: (HotKey) -> String? = { _ in nil }
  let onChange: (HotKey?) -> Void

  var body: some View {
    HStack(spacing: 4) {
      RecorderRepresentable(hotKey: hotKey, conflict: conflict, onChange: onChange)
        .glassEffect(.regular, in: Capsule())
        .frame(width: 150, height: 24)

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
}

// MARK: - RecorderRepresentable

private struct RecorderRepresentable: NSViewRepresentable {
  let hotKey: HotKey?
  let conflict: (HotKey) -> String?
  let onChange: (HotKey?) -> Void

  func makeNSView(context _: Context) -> RecorderField {
    let field = RecorderField()
    field.onChange = onChange
    field.conflict = conflict
    field.hotKey = hotKey
    return field
  }

  func updateNSView(_ field: RecorderField, context _: Context) {
    field.onChange = onChange
    field.conflict = conflict
    // Don't clobber an in-progress recording with the bound value.
    if !field.isRecording {
      field.hotKey = hotKey
    }
  }
}

// MARK: - RecorderField

final class RecorderField: NSView {

  // MARK: Internal

  var onChange: ((HotKey?) -> Void)?
  var conflict: ((HotKey) -> String?)?

  var hotKey: HotKey? {
    didSet { needsDisplay = true }
  }

  private(set) var isRecording = false {
    didSet { needsDisplay = true }
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
    // Recording starts only on an explicit click (see mouseDown), not when the
    // window assigns us as its initial first responder on open.
    true
  }

  override func resignFirstResponder() -> Bool {
    isRecording = false
    return true
  }

  override func mouseDown(with _: NSEvent) {
    window?.makeFirstResponder(self)
    isRecording = true
  }

  /// ⌘-based combos arrive as key equivalents, not plain keyDowns, so capture
  /// both paths while recording.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard isRecording else { return super.performKeyEquivalent(with: event) }
    return record(event)
  }

  override func keyDown(with event: NSEvent) {
    guard isRecording, record(event) else {
      super.keyDown(with: event)
      return
    }
  }

  override func draw(_: NSRect) {
    // The glass capsule behind us provides the fill; we draw the focus ring,
    // the combo text, and the clear button on top of it.
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
    if let conflictText {
      text = conflictText
      color = .systemOrange
      bold = true
    } else if isRecording {
      text = "Press shortcut\u{2026}"
      color = .secondaryLabelColor
      bold = false
    } else if let hotKey {
      text = hotKey.symbols
      color = .labelColor
      bold = true
    } else {
      text = "Set shortcut"
      color = .secondaryLabelColor
      bold = false
    }

    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byTruncatingTail
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: bold ? .semibold : .regular),
      .foregroundColor: color,
      .paragraphStyle: style,
    ]
    let nsText = text as NSString
    let height = nsText.size(withAttributes: attributes).height
    nsText.draw(
      in: NSRect(x: 8, y: (bounds.height - height) / 2, width: bounds.width - 16, height: height),
      withAttributes: attributes
    )
  }

  // MARK: Private

  private var conflictResetTask: Task<Void, Never>?

  private var conflictText: String? {
    didSet { needsDisplay = true }
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

  /// Records the combo from `event`, or beeps and keeps recording if it isn't a
  /// usable global shortcut. Returns whether the event was consumed.
  private func record(_ event: NSEvent) -> Bool {
    if event.keyCode == 53 { // Escape cancels.
      window?.makeFirstResponder(nil)
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
    // Already bound to another action — reject and say so. (The recorder's own
    // current key is excluded by the conflict closure, so it's treated as free.)
    if let owner = conflict?(candidate) {
      NSSound.beep()
      window?.makeFirstResponder(nil)
      showConflict(owner)
      return true
    }
    hotKey = candidate
    onChange?(candidate)
    window?.makeFirstResponder(nil)
    return true
  }

  private func showConflict(_ owner: String) {
    conflictText = "In use: \(owner)"
    conflictResetTask?.cancel()
    conflictResetTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(1.8))
      guard !Task.isCancelled, let self else { return }
      conflictText = nil
    }
  }
}
