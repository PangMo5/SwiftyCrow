import ComposableArchitecture
import KeyboardShortcuts
import Sharing
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
  let store: StoreOf<SettingsFeature>

  var body: some View {
    TabView {
      Tab("General", systemImage: "gearshape") {
        Form { GeneralSection(store: store) }
          .formStyle(.grouped)
      }
      Tab("Languages", systemImage: "globe") {
        Form { LanguagesSection(store: store) }
          .formStyle(.grouped)
      }
      Tab("Recognition", systemImage: "viewfinder") {
        Form {
          LiveCaptureSection()
          RecognitionSection()
        }
        .formStyle(.grouped)
      }
      Tab("Translation", systemImage: "character.bubble") {
        Form { TranslationSection() }
          .formStyle(.grouped)
      }
      Tab("Overlay", systemImage: "rectangle.dashed") {
        Form { OverlaySection() }
          .formStyle(.grouped)
      }
      Tab("Shortcuts", systemImage: "command") {
        Form { ShortcutsSection() }
          .formStyle(.grouped)
      }
      Tab("Updates", systemImage: "arrow.down.circle") {
        Form { UpdatesSection(store: store) }
          .formStyle(.grouped)
      }
      Tab("About", systemImage: "info.circle") {
        Form { AboutSection() }
          .formStyle(.grouped)
      }
    }
    .scenePadding()
    .frame(minWidth: 520, minHeight: 360)
    .task { store.send(.task) }
  }
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

// MARK: - RecognitionSection

private struct RecognitionSection: View {
  var body: some View {
    Section {
      Picker("OCR mode", selection: Binding($settings.recognition.mode)) {
        ForEach(OCRMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
    } header: {
      Text("Recognition")
    } footer: {
      Text("Document mode groups recognized text into paragraphs (macOS 26+).")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

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
      Toggle("Enable overlay", isOn: Binding($settings.overlay.enabled))
      Toggle("Hide on hover", isOn: Binding($settings.overlay.hideOnHover))
      Picker("Live mode", selection: Binding($settings.overlay.liveMode)) {
        ForEach(OverlayLiveMode.allCases) { mode in
          Text(mode.displayName).tag(mode)
        }
      }
    } header: {
      Text("Overlay")
    } footer: {
      Text("In-place draws the translation over the text. Window keeps the overlay a thin region frame and shows the translation in a separate window. Clicks pass through to the apps below once a translation is shown.")
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
      KeyboardShortcuts.Recorder("Capture region", name: .selectRegion) { shortcut in
        $settings.withLock { $0.shortcuts.selectRegion = shortcut.map(HotKey.init) }
      }
      KeyboardShortcuts.Recorder("Toggle Live Mode", name: .toggleLive) { shortcut in
        $settings.withLock { $0.shortcuts.toggleLive = shortcut.map(HotKey.init) }
      }
      KeyboardShortcuts.Recorder("Toggle overlay", name: .toggleOverlay) { shortcut in
        $settings.withLock { $0.shortcuts.toggleOverlay = shortcut.map(HotKey.init) }
      }
      KeyboardShortcuts.Recorder("Toggle live mode (In-place / Window)", name: .toggleLiveMode) { shortcut in
        $settings.withLock { $0.shortcuts.toggleLiveMode = shortcut.map(HotKey.init) }
      }
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text("These hotkeys work even when the app is in the background, and are saved to config.toml.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section {
      KeyboardShortcuts.Recorder("Save image", name: .regionSave)
      KeyboardShortcuts.Recorder("Copy image", name: .regionCopyImage)
      KeyboardShortcuts.Recorder("Copy original text", name: .regionCopyOriginal)
      KeyboardShortcuts.Recorder("Copy translation", name: .regionCopyTranslation)
    } header: {
      Text("Capture Window")
    } footer: {
      Text("Active only while a capture result window is focused.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @Shared(.settings) private var settings

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
    ("KeyboardShortcuts", "https://github.com/sindresorhus/KeyboardShortcuts"),
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
