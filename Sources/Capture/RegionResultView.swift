// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import SwiftUI

// MARK: - RegionResultView

struct RegionResultView: View {

  // MARK: Internal

  let store: StoreOf<RegionCaptureFeature>
  let owningWindow: () -> NSWindow?
  let onSaveImage: (Data) -> Void
  let onCopyImage: (Data) -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().opacity(0.4)
      if store.translationUnavailable {
        TranslationModelHint(message: store.lastError)
      } else if let error = store.lastError, store.imageData != nil {
        Label(error, systemImage: "exclamationmark.triangle.fill")
          .font(.caption)
          .foregroundStyle(.red)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
      }
      if let exportError {
        Text(exportError)
          .font(.caption)
          .foregroundStyle(.red)
          .padding(.horizontal, 14)
      }
      CaptureStatusNote(lines: store.overlayLines)
      content
      Divider().opacity(0.4)
      HStack {
        Spacer(minLength: 0)
        CaptureZoomControls(model: zoomModel)
          .disabled(store.imageData == nil)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 6)
    }
    .frame(minWidth: 360, minHeight: 280)
    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .task { store.send(.task) }
    .onAppear(perform: installMonitor)
    .onDisappear(perform: removeMonitor)
    .onChange(of: store.finished) { _, finished in
      if finished { onClose() }
    }
  }

  // MARK: Private

  @State private var hoveredHelp: String?
  @State private var keyMonitor: Any?
  @State private var exportError: String?
  @State private var zoomModel = CaptureZoomModel()
  @Environment(\.displayScale) private var displayScale

  private var toolbar: some View {
    HStack(spacing: 10) {
      HStack(spacing: 10) {
        Text(hoveredHelp ?? "Capture")
          .font(.headline)
          .foregroundStyle(hoveredHelp == nil ? .primary : .secondary)
          .animation(.easeOut(duration: 0.12), value: hoveredHelp)
        if store.isTranslating {
          ProgressView().controlSize(.small)
        }
        Spacer(minLength: 0)
      }
      .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
      .contentShape(Rectangle())
      .gesture(WindowDragGesture())
      .allowsWindowActivationEvents()
      toolbarButton(
        "square.and.arrow.down",
        help: helpText("Save image", shortcuts.regionSave),
        action: { exportImage(onSaveImage) }
      )
      toolbarButton("doc.on.doc", help: helpText("Copy image", shortcuts.regionCopyImage), action: { exportImage(onCopyImage) })
      toolbarButton("text.quote", help: helpText("Copy original text", shortcuts.regionCopyOriginal)) {
        store.send(.copyOriginalRequested)
      }
      toolbarButton("character.bubble", help: helpText("Copy translation", shortcuts.regionCopyTranslation)) {
        store.send(.copyTranslationRequested)
      }
      .disabled(store.isTranslating || store.overlayLines.isEmpty)
      toolbarButton("xmark", help: "Close (Esc)", action: onClose)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var content: some View {
    if store.imageData != nil {
      ZoomableCaptureCanvas(imageSize: store.imageSize, backingScale: displayScale, model: zoomModel) {
        CaptureResultImage(imageData: store.imageData, imageSize: store.imageSize, lines: store.overlayLines)
          .equatable()
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(12)
    } else if let error = store.lastError {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      VStack(spacing: 12) {
        ProgressView()
        if store.isTakingLong {
          // Practically always Vision loading a cold document-recognition model,
          // which takes tens of seconds. Saying so is the difference between a
          // wait and an apparent hang.
          VStack(spacing: 4) {
            Text("Preparing text recognition")
              .font(.callout.weight(.semibold))
            Text("macOS is loading the recognition model.\nThis only happens the first time, or after it has been unloaded.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          .multilineTextAlignment(.center)
          .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.2), value: store.isTakingLong)
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private var shortcuts: ShortcutSettings {
    store.settings.shortcuts
  }

  private func exportImage(_ action: (Data) -> Void) {
    guard
      let data = CaptureResultImage.png(
        imageData: store.imageData,
        imageSize: store.imageSize,
        lines: store.overlayLines
      )
    else {
      exportError = "Could not render the capture image. Please try again."
      return
    }
    exportError = nil
    action(data)
  }

  private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text(help))
    .help(help)
    .onHover { hovering in
      if hovering {
        hoveredHelp = help
      } else if hoveredHelp == help {
        hoveredHelp = nil
      }
    }
  }

  private func helpText(_ label: String, _ hotKey: HotKey?) -> String {
    guard let hotKey else { return label }
    return "\(label) (\(hotKey.displayString))"
  }

  /// Match the customizable shortcuts locally; they aren't registered globally,
  /// so they only fire while this window has focus.
  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      let windowNumber = event.windowNumber
      let characters = event.charactersIgnoringModifiers
      let keyCode = Int(event.keyCode)
      var carbonModifiers = 0
      let flags = event.modifierFlags
      if flags.contains(.command) { carbonModifiers |= 256 }
      if flags.contains(.shift) { carbonModifiers |= 512 }
      if flags.contains(.option) { carbonModifiers |= 2048 }
      if flags.contains(.control) { carbonModifiers |= 4096 }
      let consumed = MainActor.assumeIsolated {
        guard owningWindow()?.windowNumber == windowNumber, owningWindow()?.isKeyWindow == true else { return false }
        if keyCode == 53 { // Escape
          onClose()
          return true
        }
        if matches(keyCode, carbonModifiers, shortcuts.regionSave) { exportImage(onSaveImage)
          return true
        }
        if matches(keyCode, carbonModifiers, shortcuts.regionCopyImage) { exportImage(onCopyImage)
          return true
        }
        if matches(keyCode, carbonModifiers, shortcuts.regionCopyOriginal) { store.send(.copyOriginalRequested)
          return true
        }
        if matches(keyCode, carbonModifiers, shortcuts.regionCopyTranslation) {
          store.send(.copyTranslationRequested)
          return true
        }
        if store.imageData != nil, carbonModifiers == 256 || carbonModifiers == 768 {
          switch characters {
          case "+",
               "=": zoomModel.zoomIn()
          case "-": zoomModel.zoomOut()
          case "0": zoomModel.resetToFit()
          default: return false
          }
          return true
        }
        return false
      }
      return consumed ? nil : event
    }
  }

  private func removeMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }

  private func matches(_ keyCode: Int, _ carbonModifiers: Int, _ hotKey: HotKey?) -> Bool {
    guard let hotKey, keyCode == hotKey.carbonKeyCode else { return false }
    return carbonModifiers == hotKey.carbonModifiers
  }
}

// MARK: - CaptureZoomControls

/// Keep frequent magnification updates local to the controls. The source image
/// and translated document do not need to be rebuilt while pinching or panning.
private struct CaptureZoomControls: View {
  let model: CaptureZoomModel

  var body: some View {
    HStack(spacing: 10) {
      Button(action: model.zoomOut) {
        Image(systemName: "minus.magnifyingglass").frame(width: 26, height: 26)
      }
      .disabled(!model.canZoomOut)
      .accessibilityLabel("Zoom out")
      .help("Zoom out (⌘−)")
      Button(action: model.resetToFit) {
        Text("\(model.percentage)%")
          .font(.caption.monospacedDigit())
          .frame(minWidth: 40, minHeight: 26)
          .contentShape(Rectangle())
      }
      .accessibilityLabel("Zoom \(model.percentage) percent. Fit image")
      .help("Fit image (⌘0)")
      Button(action: model.zoomIn) {
        Image(systemName: "plus.magnifyingglass").frame(width: 26, height: 26)
      }
      .disabled(!model.canZoomIn)
      .accessibilityLabel("Zoom in")
      .help("Zoom in (⌘+)")
    }
    .buttonStyle(.plain)
  }
}
