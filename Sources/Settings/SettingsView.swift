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
      Picker("Source", selection: Binding($settings.sourceLanguage)) {
        Text("Auto").tag(Language.auto)
        Divider()
        ForEach(sourceLanguages) { language in
          Text(language.displayName).tag(language)
        }
      }
      Picker("Target", selection: Binding($settings.targetLanguage)) {
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
          Slider(value: Binding($settings.captureInterval), in: 0.3...3.0, step: 0.1)
            .frame(width: 220)
          Text(String(format: "%.1f s", settings.captureInterval))
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
      Picker("OCR mode", selection: Binding($settings.ocrMode)) {
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
      Picker("Strategy", selection: Binding($settings.translationStrategy)) {
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
      Toggle("Enable overlay", isOn: Binding($settings.overlayEnabled))
      Toggle("Hide on hover", isOn: Binding($settings.overlayHideOnHover))
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
  var body: some View {
    Section {
      KeyboardShortcuts.Recorder("Capture once", name: .captureOnce)
      KeyboardShortcuts.Recorder("Toggle Live Mode", name: .toggleLive)
      KeyboardShortcuts.Recorder("Toggle overlay", name: .toggleOverlay)
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text("These hotkeys work even when the app is in the background.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }
}
