import AppKit
import ComposableArchitecture
import KeyboardShortcuts
import SwiftUI

struct RegionResultView: View {

  // MARK: Internal

  let store: StoreOf<RegionCaptureFeature>
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().opacity(0.4)
      content
    }
    .frame(minWidth: 360, minHeight: 280)
    .background(.ultraThinMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
    )
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

  @ViewBuilder
  private var translatedImage: some View {
    if let composed = store.composedImageData, let image = NSImage(data: composed) {
      // Finished: blurred composition (identical to copy/save).
      Image(nsImage: image)
        .resizable()
        .aspectRatio(aspectRatio, contentMode: .fit)
    } else if let data = store.imageData, let image = NSImage(data: data) {
      // In progress: live overlay while translations land.
      ZStack {
        Image(nsImage: image)
          .resizable()
        TranslationOverlayLayer(lines: store.overlayLines, glass: false)
      }
      .aspectRatio(aspectRatio, contentMode: .fit)
    }
  }

  private var aspectRatio: CGFloat {
    guard store.imageSize.height > 0 else { return 1 }
    return store.imageSize.width / store.imageSize.height
  }

  private var toolbar: some View {
    HStack(spacing: 10) {
      Text(hoveredHelp ?? "Capture")
        .font(.headline)
        .foregroundStyle(hoveredHelp == nil ? .primary : .secondary)
        .animation(.easeOut(duration: 0.12), value: hoveredHelp)
      if store.isTranslating {
        ProgressView().controlSize(.small)
      }
      Spacer()
      toolbarButton("square.and.arrow.down", help: helpText("Save image", .regionSave)) {
        store.send(.saveRequested)
      }
      toolbarButton("doc.on.doc", help: helpText("Copy image", .regionCopyImage)) {
        store.send(.copyImageRequested)
      }
      toolbarButton("text.quote", help: helpText("Copy original text", .regionCopyOriginal)) {
        store.send(.copyOriginalRequested)
      }
      toolbarButton("character.bubble", help: helpText("Copy translation", .regionCopyTranslation)) {
        store.send(.copyTranslationRequested)
      }
      toolbarButton("xmark", help: "Close (Esc)", action: onClose)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
  }

  @ViewBuilder
  private var content: some View {
    if store.imageData != nil {
      translatedImage
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(12)
    } else if let error = store.lastError {
      Label(error, systemImage: "exclamationmark.triangle.fill")
        .foregroundStyle(.red)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }

  private func toolbarButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: systemName)
        .font(.system(size: 13, weight: .semibold))
        .frame(width: 26, height: 26)
    }
    .buttonStyle(.plain)
    .help(help)
    .onHover { hovering in
      if hovering {
        hoveredHelp = help
      } else if hoveredHelp == help {
        hoveredHelp = nil
      }
    }
  }

  private func helpText(_ label: String, _ name: KeyboardShortcuts.Name) -> String {
    if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
      return "\(label) (\(shortcut))"
    }
    return label
  }

  // Match the customizable shortcuts locally; they aren't registered globally,
  // so they only fire while this window has focus.
  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated {
        if event.keyCode == 53 { // Escape
          onClose()
          return nil
        }
        if matches(event, .regionSave) { store.send(.saveRequested); return nil }
        if matches(event, .regionCopyImage) { store.send(.copyImageRequested); return nil }
        if matches(event, .regionCopyOriginal) { store.send(.copyOriginalRequested); return nil }
        if matches(event, .regionCopyTranslation) { store.send(.copyTranslationRequested); return nil }
        return event
      }
    }
  }

  private func removeMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }

  private func matches(_ event: NSEvent, _ name: KeyboardShortcuts.Name) -> Bool {
    guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
    let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
    return Int(event.keyCode) == shortcut.carbonKeyCode && flags == shortcut.modifiers
  }
}
