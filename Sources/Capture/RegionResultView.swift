import AppKit
import ComposableArchitecture
import KeyboardShortcuts
import SwiftUI
import UniformTypeIdentifiers

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
      toolbarButton("square.and.arrow.down", help: helpText("Save image", .regionSave), action: saveImage)
      toolbarButton("doc.on.doc", help: helpText("Copy image", .regionCopyImage), action: copyImage)
      toolbarButton("text.quote", help: helpText("Copy original text", .regionCopyOriginal), action: copyOriginal)
      toolbarButton("character.bubble", help: helpText("Copy translation", .regionCopyTranslation), action: copyTranslation)
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

  // MARK: Image composition + actions

  @MainActor
  private func composedImage() -> NSImage? {
    if let composed = store.composedImageData, let image = NSImage(data: composed) {
      return image
    }
    guard let data = store.imageData, let base = NSImage(data: data), store.imageSize != .zero else { return nil }
    let content = ZStack {
      Image(nsImage: base)
        .resizable()
      TranslationOverlayLayer(lines: store.overlayLines, glass: false)
    }
    .frame(width: store.imageSize.width, height: store.imageSize.height)
    let renderer = ImageRenderer(content: content)
    renderer.scale = 1
    return renderer.nsImage
  }

  private func copyImage() {
    guard let image = composedImage() else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.writeObjects([image])
    onClose()
  }

  private func saveImage() {
    guard
      let image = composedImage(),
      let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:])
    else { return }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "SwiftyCrow-\(formatter.string(from: Date())).png"
    if panel.runModal() == .OK, let url = panel.url {
      try? png.write(to: url)
      onClose()
    }
  }

  private func copyOriginal() {
    let text = store.overlayLines.map(\.sourceText).joined(separator: "\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    onClose()
  }

  private func copyTranslation() {
    let text = store.overlayLines.compactMap(\.translated).joined(separator: "\n")
    guard !text.isEmpty else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    onClose()
  }

  // MARK: Key handling

  // Match the customizable shortcuts locally; they aren't registered globally,
  // so they only fire while this window has focus.
  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      if event.keyCode == 53 { // Escape
        onClose()
        return nil
      }
      let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
      func matches(_ name: KeyboardShortcuts.Name) -> Bool {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        return Int(event.keyCode) == shortcut.carbonKeyCode && flags == shortcut.modifiers
      }
      if matches(.regionSave) { saveImage(); return nil }
      if matches(.regionCopyImage) { copyImage(); return nil }
      if matches(.regionCopyOriginal) { copyOriginal(); return nil }
      if matches(.regionCopyTranslation) { copyTranslation(); return nil }
      return event
    }
  }

  private func removeMonitor() {
    if let keyMonitor {
      NSEvent.removeMonitor(keyMonitor)
      self.keyMonitor = nil
    }
  }
}
