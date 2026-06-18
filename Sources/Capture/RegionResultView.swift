import AppKit
import ComposableArchitecture
import SwiftUI

struct RegionResultView: View {

  // MARK: Internal

  let store: StoreOf<RegionCaptureFeature>
  /// Reports the on-screen rect of the image area (window top-left coords) so
  /// the controller can screen-capture exactly that region for save/copy.
  let onImageFrame: (CGRect) -> Void
  let onSaveImage: () -> Void
  let onCopyImage: () -> Void
  let onClose: () -> Void

  var body: some View {
    VStack(spacing: 0) {
      toolbar
      Divider().opacity(0.4)
      if store.translationUnavailable {
        TranslationModelHint()
      }
      content
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

  /// Blurred screenshot (original text hidden) when ready, else the raw capture
  /// while the backdrop is being built; glass translation chips on top — the
  /// same TranslationOverlayLayer the live overlay uses.
  @ViewBuilder
  private var translatedImage: some View {
    let backdrop = store.backgroundImageData.flatMap(NSImage.init(data:))
      ?? store.imageData.flatMap(NSImage.init(data:))
    if let backdrop {
      ZStack {
        Image(nsImage: backdrop)
          .resizable()
        TranslationOverlayLayer(lines: store.overlayLines, glass: true)
      }
      .aspectRatio(aspectRatio, contentMode: .fit)
      .background(
        GeometryReader { proxy in
          Color.clear
            .onAppear { onImageFrame(proxy.frame(in: .global)) }
            .onChange(of: proxy.frame(in: .global)) { _, frame in onImageFrame(frame) }
        }
      )
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
      toolbarButton("square.and.arrow.down", help: helpText("Save image", shortcuts.regionSave), action: onSaveImage)
      toolbarButton("doc.on.doc", help: helpText("Copy image", shortcuts.regionCopyImage), action: onCopyImage)
      toolbarButton("text.quote", help: helpText("Copy original text", shortcuts.regionCopyOriginal)) {
        store.send(.copyOriginalRequested)
      }
      toolbarButton("character.bubble", help: helpText("Copy translation", shortcuts.regionCopyTranslation)) {
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

  private var shortcuts: ShortcutSettings {
    store.settings.shortcuts
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

  private func helpText(_ label: String, _ hotKey: HotKey?) -> String {
    guard let hotKey else { return label }
    return "\(label) (\(hotKey.displayString))"
  }

  /// Match the customizable shortcuts locally; they aren't registered globally,
  /// so they only fire while this window has focus.
  private func installMonitor() {
    guard keyMonitor == nil else { return }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      MainActor.assumeIsolated {
        if event.keyCode == 53 { // Escape
          onClose()
          return nil
        }
        if matches(event, shortcuts.regionSave) { onSaveImage()
          return nil
        }
        if matches(event, shortcuts.regionCopyImage) { onCopyImage()
          return nil
        }
        if matches(event, shortcuts.regionCopyOriginal) { store.send(.copyOriginalRequested)
          return nil
        }
        if matches(event, shortcuts.regionCopyTranslation) { store.send(.copyTranslationRequested)
          return nil
        }
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

  private func matches(_ event: NSEvent, _ hotKey: HotKey?) -> Bool {
    guard let hotKey, Int(event.keyCode) == hotKey.carbonKeyCode else { return false }
    var carbon = 0
    let flags = event.modifierFlags
    if flags.contains(.command) { carbon |= 256 }
    if flags.contains(.shift) { carbon |= 512 }
    if flags.contains(.option) { carbon |= 2048 }
    if flags.contains(.control) { carbon |= 4096 }
    return carbon == hotKey.carbonModifiers
  }
}
