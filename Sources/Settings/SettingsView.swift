import ComposableArchitecture
import KeyboardShortcuts
import Sharing
import SwiftUI

// MARK: - SettingsView

struct SettingsView: View {
  var body: some View {
    TabView {
      Tab("Languages", systemImage: "globe") {
        Form { LanguagesSection() }
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
        Form { UpdatesSection() }
          .formStyle(.grouped)
      }
    }
    .scenePadding()
    .frame(minWidth: 520, minHeight: 360)
  }
}

// MARK: - LanguagesSection

private struct LanguagesSection: View {

  // MARK: Internal

  var body: some View {
    Section {
      Picker("Source", selection: Binding($settings.languages.source)) {
        ForEach(sourceLanguages) { language in
          Text(language.displayName).tag(language)
        }
      }
      Picker("Target", selection: Binding($settings.languages.target)) {
        ForEach(targetLanguages) { language in
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
    .task {
      sourceLanguages = await Language.systemSupported(intersectedWithOCR: true)
      targetLanguages = await Language.systemSupported(intersectedWithOCR: false)
    }
  }

  // MARK: Private

  @State private var sourceLanguages = [Language]()
  @State private var targetLanguages = [Language]()

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
    } header: {
      Text("Overlay")
    } footer: {
      Text("Translations are drawn in-place over each recognized line.")
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
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text("These hotkeys work even when the app is in the background, and are saved to config.toml.")
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
        updater.checkForUpdates()
      }
      .disabled(!canCheckForUpdates)
      .task {
        for await value in updater.canCheckForUpdates() {
          canCheckForUpdates = value
        }
      }
    } header: {
      Text("Software Update")
    } footer: {
      Text("SwiftyCrow checks in the background and notifies you when a new version is available.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

  @State private var canCheckForUpdates = false

  @Dependency(\.updater) private var updater

  @Shared(.settings) private var settings

}
