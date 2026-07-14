import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

// MARK: - SettingsView

/// System-Settings-style layout: a sidebar of panes on the left, one grouped
/// form per pane on the right. Mirrors the sibling Tatami / Amado apps.
struct SettingsView: View {

  // MARK: Internal

  let store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationSplitView {
      // `id: \.self` so the ForEach id type matches the optional selection
      // type — macOS only wires the selection gesture when they line up.
      List(Pane.allCases, id: \.self, selection: $pane) { pane in
        Label(pane.title, systemImage: pane.icon)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: {
      Form {
        switch pane ?? .general {
        case .general: GeneralSection(store: store)
        case .languages: LanguagesSection(store: store)
        case .capture: LiveCaptureSection()
        case .translation: TranslationSection()
        case .overlay: OverlaySection()
        case .shortcuts: ShortcutsSection()
        case .updates: UpdatesSection(store: store)
        case .about: AboutSection()
        }
      }
      .formStyle(.grouped)
      .navigationTitle((pane ?? .general).title)
    }
    .frame(minWidth: 640, minHeight: 460)
    .task { store.send(.task) }
  }

  // MARK: Private

  private enum Pane: String, CaseIterable, Identifiable {
    case general
    case languages
    case capture
    case translation
    case overlay
    case shortcuts
    case updates
    case about

    // MARK: Internal

    var id: String {
      rawValue
    }

    var title: String {
      switch self {
      case .general: "General"
      case .languages: "Languages"
      case .capture: "Capture"
      case .translation: "Translation"
      case .overlay: "Overlay"
      case .shortcuts: "Shortcuts"
      case .updates: "Updates"
      case .about: "About"
      }
    }

    var icon: String {
      switch self {
      case .general: "gearshape"
      case .languages: "globe"
      case .capture: "viewfinder"
      case .translation: "character.bubble"
      case .overlay: "rectangle.dashed"
      case .shortcuts: "command"
      case .updates: "arrow.down.circle"
      case .about: "info.circle"
      }
    }
  }

  @State private var pane: Pane? = .general
}

// MARK: - GeneralSection

private struct GeneralSection: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      Toggle(isOn: Binding(
        get: { store.launchAtLogin },
        set: { store.send(.launchAtLoginChanged($0)) }
      )) {
        Text("Launch at login")
        Text("Start SwiftyCrow automatically when you log in.")
      }
    } header: {
      Text("General")
    }
  }
}

// MARK: - LanguagesSection

private struct LanguagesSection: View {

  // MARK: Internal

  let store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      Picker("Source", selection: Binding($settings.languages.source)) {
        ForEach(store.sourceLanguages) { language in
          Text(language.displayName).tag(language)
        }
      }
      Picker("Target", selection: Binding($settings.languages.target)) {
        ForEach(store.targetLanguages) { language in
          Text(language.displayName).tag(language)
        }
      }
    } header: {
      Text("Languages")
    } footer: {
      Text("List is loaded from Apple Translation \u{00B7} Vision on this device.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @Shared(.settings) private var settings

}

// MARK: - LiveCaptureSection

private struct LiveCaptureSection: View {

  // MARK: Internal

  var body: some View {
    Section {
      LabeledContent("Capture interval") {
        VStack(alignment: .trailing, spacing: 2) {
          Slider(value: Binding($settings.capture.interval), in: 0.3...3.0, step: 0.1)
            .frame(width: 220)
          Text(String(format: "%.1f s", settings.capture.interval))
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
      }
    } header: {
      Text("Live Capture")
    } footer: {
      Text("How often Live Mode re-captures the overlay region.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @Shared(.settings) private var settings

}

// MARK: - TranslationSection

private struct TranslationSection: View {
  var body: some View {
    Section {
      Picker("Strategy", selection: Binding($settings.translation.strategy)) {
        ForEach(TranslationStrategy.allCases) { strategy in
          Text(strategy.displayName).tag(strategy)
        }
      }
    } header: {
      Text("Translation")
    } footer: {
      Text("High fidelity uses Apple Intelligence on devices that support it (macOS 26.4+).")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  @Shared(.settings) private var settings

}

// MARK: - OverlaySection

private struct OverlaySection: View {

  // MARK: Internal

  var body: some View {
    Section {
      Toggle("Hide on hover", isOn: Binding($settings.overlay.hideOnHover))
      Picker("Live mode", selection: Binding($settings.overlay.liveMode)) {
        ForEach(OverlayLiveMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
    } header: {
      Text("Overlay")
    } footer: {
      Text(
        "Start a live overlay from the menu bar or the Live overlay shortcut, then drag to select a region (press Space to pick a window). In-place draws the translation over the text; Window keeps the overlay a thin region frame and shows the translation in a separate window. The overlay always lets clicks pass through to the apps below."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @Shared(.settings) private var settings

}

// MARK: - ShortcutsSection

private struct ShortcutsSection: View {

  // MARK: Internal

  var body: some View {
    Section {
      recorder("Capture region", \.selectRegion)
      recorder("Live overlay (select a region)", \.liveOverlay)
      recorder("Show / hide overlay (last region)", \.toggleLiveOverlay)
      recorder("Pause / resume Live", \.toggleLive)
      recorder("Switch display (In-place / Window)", \.toggleLiveMode)
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text("These hotkeys work even when the app is in the background, and are saved to config.toml.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section {
      recorder("Save image", \.regionSave)
      recorder("Copy image", \.regionCopyImage)
      recorder("Copy original text", \.regionCopyOriginal)
      recorder("Copy translation", \.regionCopyTranslation)
    } header: {
      Text("Capture Window")
    } footer: {
      Text("Active only while a capture result window is focused.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  /// Action name + key path for every recordable shortcut, used both to detect
  /// conflicts and to name the offending action in the recorder.
  private static let allShortcuts: [(title: String, keyPath: WritableKeyPath<ShortcutSettings, HotKey?>)] = [
    ("Capture region", \.selectRegion),
    ("Live overlay", \.liveOverlay),
    ("Show / hide overlay", \.toggleLiveOverlay),
    ("Pause / resume Live", \.toggleLive),
    ("Switch display", \.toggleLiveMode),
    ("Save image", \.regionSave),
    ("Copy image", \.regionCopyImage),
    ("Copy original text", \.regionCopyOriginal),
    ("Copy translation", \.regionCopyTranslation),
  ]

  @Shared(.settings) private var settings

  private func recorder(_ title: String, _ keyPath: WritableKeyPath<ShortcutSettings, HotKey?>) -> some View {
    LabeledContent(title) {
      ShortcutRecorder(
        hotKey: settings.shortcuts[keyPath: keyPath],
        conflict: { candidate in conflictTitle(for: candidate, excluding: keyPath) }
      ) { hotKey in
        $settings.withLock { $0.shortcuts[keyPath: keyPath] = hotKey }
      }
    }
  }

  /// The name of another action already bound to `candidate`, or nil if free.
  private func conflictTitle(for candidate: HotKey, excluding keyPath: WritableKeyPath<ShortcutSettings, HotKey?>) -> String? {
    Self.allShortcuts.first { entry in
      entry.keyPath != keyPath && settings.shortcuts[keyPath: entry.keyPath] == candidate
    }?.title
  }

}

// MARK: - UpdatesSection

private struct UpdatesSection: View {

  // MARK: Internal

  let store: StoreOf<SettingsFeature>

  var body: some View {
    Section {
      Toggle("Automatically check for updates", isOn: Binding($settings.updates.automaticChecks))
      Picker("Check", selection: Binding($settings.updates.checkInterval)) {
        ForEach(UpdateCheckInterval.allCases) { interval in
          Text(interval.displayName).tag(interval)
        }
      }
      .disabled(!settings.updates.automaticChecks)
      Button("Check for Updates Now") {
        store.send(.checkForUpdatesTapped)
      }
      .disabled(!store.canCheckForUpdates)
    } header: {
      Text("Software Update")
    } footer: {
      Text("SwiftyCrow checks in the background and notifies you when a new version is available.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @Shared(.settings) private var settings

}

// MARK: - AboutSection

private struct AboutSection: View {

  // MARK: Internal

  var body: some View {
    Section {
      HStack(spacing: 14) {
        if let icon = NSApplication.shared.applicationIconImage {
          Image(nsImage: icon)
            .resizable()
            .frame(width: 56, height: 56)
        }
        VStack(alignment: .leading, spacing: 2) {
          Text("SwiftyCrow")
            .font(.title2.weight(.semibold))
          Text("On-device screen translator")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
      .padding(.vertical, 4)
    }

    Section("About") {
      LabeledContent("Version", value: Self.appVersion)
      LabeledContent("Created by") {
        Link("PangMo5", destination: URL(string: "https://github.com/PangMo5")!)
      }
      Link("GitHub", destination: URL(string: "https://github.com/PangMo5/SwiftyCrow")!)
    }

    Section("Built with") {
      ForEach(Self.acknowledgements, id: \.name) { item in
        creditLink(item.name, item.url)
      }
    }
  }

  // MARK: Private

  /// Open-source dependencies, credited in the About pane.
  private static let acknowledgements: [(name: String, url: String)] = [
    ("The Composable Architecture", "https://github.com/pointfreeco/swift-composable-architecture"),
    ("swift-sharing", "https://github.com/pointfreeco/swift-sharing"),
    ("Magnet", "https://github.com/Clipy/Magnet"),
    ("swift-toml", "https://github.com/mattt/swift-toml"),
    ("Sparkle", "https://github.com/sparkle-project/Sparkle"),
  ]

  /// Marketing version + build number from the app bundle, e.g. "2.1.0 (42)".
  private static let appVersion: String = {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "\u{2014}"
    let build = info?["CFBundleVersion"] as? String ?? "\u{2014}"
    return "\(short) (\(build))"
  }()

  private func creditLink(_ title: String, _ urlString: String) -> some View {
    Link(title, destination: URL(string: urlString)!)
  }

}
