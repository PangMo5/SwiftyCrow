// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import Sharing
import SwiftUI

// MARK: - SettingsView

/// System-Settings-style layout: a sidebar of panes on the left, one grouped
/// form per pane on the right. Mirrors the sibling Tatami / Amado apps.
struct SettingsView: View {

  let store: StoreOf<SettingsFeature>

  var body: some View {
    NavigationSplitView {
      // `id: \.self` so the ForEach id type matches the optional selection
      // type — macOS only wires the selection gesture when they line up.
      List(
        SettingsPane.allCases,
        id: \.self,
        selection: Binding(get: { Optional(store.pane) }, set: { if let pane = $0 { store.send(.paneSelected(pane)) } })
      ) { pane in
        Label(pane.title, systemImage: pane.icon)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    } detail: {
      Form {
        switch store.pane {
        case .general: GeneralSection(store: store)
        case .languages: LanguagesSection(store: store)
        case .translation: TranslationSection()
        case .overlay: OverlaySection()
        case .shortcuts: ShortcutsSection()
        case .updates: UpdatesSection(store: store)
        case .about: AboutSection()
        }
      }
      .formStyle(.grouped)
      .navigationTitle(Text((store.pane).title))
    }
    .frame(minWidth: 640, minHeight: 460)
    .task { await store.send(.task).finish() }
    .onDisappear { store.send(.taskEnded) }
  }

  // MARK: Private

}

// MARK: - SettingsPane

enum SettingsPane: String, CaseIterable, Identifiable {
  case general
  case languages
  case translation
  case overlay
  case shortcuts
  case updates
  case about

  // MARK: Internal

  var id: String {
    rawValue
  }

  var title: LocalizedStringResource {
    switch self {
    case .general: "General"
    case .languages: "Languages"
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
    case .translation: "character.bubble"
    case .overlay: "rectangle.dashed"
    case .shortcuts: "command"
    case .updates: "arrow.down.circle"
    case .about: "info.circle"
    }
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
    Section("Permissions") {
      ScreenRecordingPermissionRow(
        granted: store.hasScreenRecording,
        isRequesting: store.isRequestingAccess,
        grant: { store.send(.grantScreenRecordingTapped) },
        openSettings: { store.send(.openScreenRecordingSettingsTapped) }
      )
      if !store.hasScreenRecording {
        PermissionRelaunchNotice(isRelaunching: store.isRelaunching, error: store.relaunchError) { store.send(.relaunchTapped) }
      }
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

// MARK: - TranslationSection

private struct TranslationSection: View {

  // MARK: Internal

  var body: some View {
    Section {
      Picker("Preferred strategy", selection: Binding($settings.translation.strategy)) {
        ForEach(TranslationStrategy.allCases) { strategy in
          Text(strategy.displayName).tag(strategy)
        }
      }
    } header: {
      Text("Translation")
    } footer: {
      Text(
        "Your preferred strategy is used when its model is installed. Otherwise, SwiftyCrow uses an installed model and shows which strategy it selected. High fidelity uses Apple Intelligence on supported devices."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }
  }

  // MARK: Private

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
        "Start a live overlay from the menu bar or the Live overlay shortcut, then drag to select a region (press Space to pick a window). In-place draws the translation over the text; Window keeps the overlay a thin region frame and shows the translation in a separate window. The translation area lets clicks pass through; controls and an open information popover receive input."
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

  var body: some View {
    Section {
      ShortcutSettingRow("Capture region", \.selectRegion)
      ShortcutSettingRow("Live overlay (select a region)", \.liveOverlay)
      ShortcutSettingRow("Show / hide overlay (last region)", \.toggleLiveOverlay)
      ShortcutSettingRow("Pause / resume Live", \.toggleLive)
      ShortcutSettingRow("Switch display (In-place / Window)", \.toggleLiveMode)
    } header: {
      Text("Global Shortcuts")
    } footer: {
      Text("These hotkeys work even when the app is in the background, and are saved to config.toml.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Section {
      ShortcutSettingRow("Save image", \.regionSave)
      ShortcutSettingRow("Copy image", \.regionCopyImage)
      ShortcutSettingRow("Copy original text", \.regionCopyOriginal)
      ShortcutSettingRow("Copy translation", \.regionCopyTranslation)
    } header: {
      Text("Capture Window")
    } footer: {
      Text("Active only while a capture result window is focused.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

}

// MARK: - ShortcutSettingRow

/// Shared by Settings and Quick Setup so recording, persistence, and conflicts agree.
struct ShortcutSettingRow: View {

  // MARK: Lifecycle

  init(_ title: LocalizedStringResource, _ keyPath: WritableKeyPath<ShortcutSettings, HotKey?>) {
    self.title = title
    self.keyPath = keyPath
  }

  // MARK: Internal

  static let allShortcuts: [(title: LocalizedStringResource, keyPath: WritableKeyPath<ShortcutSettings, HotKey?>)] = [
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

  let title: LocalizedStringResource
  let keyPath: WritableKeyPath<ShortcutSettings, HotKey?>

  var body: some View {
    HStack(spacing: 16) {
      Text(title)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
      ShortcutRecorder(hotKey: settings.shortcuts[keyPath: keyPath], accessibilityLabel: title, conflict: { candidate in
        Self.allShortcuts.first { $0.keyPath != keyPath && settings.shortcuts[keyPath: $0.keyPath] == candidate }
          .map { String(localized: $0.title) }
      }) { hotKey in
        $settings.withLock { $0.shortcuts[keyPath: keyPath] = hotKey }
      }
      .fixedSize()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
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
          Text("Translate anything on your screen.\nEntirely on your Mac.")
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
      Link("Source Code", destination: URL(string: "https://github.com/PangMo5/SwiftyCrow")!)
      Button("View Changelog…") { showsChangelog = true }
        .buttonStyle(.link)
        .accessibilityIdentifier("about-changelog")
    }

    .sheet(isPresented: $showsChangelog) { BundledDocumentView(document: .changelog) }

    Section("Legal") {
      LabeledContent("Copyright", value: "© 2021–2026 PangMo5 and contributors")
      Text(
        "This program comes with no warranty. You may redistribute it under the GNU AGPL v3. Select License for details."
      )
      .font(.caption)
      .foregroundStyle(.secondary)

      ForEach([BundledDocument.license, .thirdPartyNotices]) { document in
        Button {
          presentedDocument = document
        } label: {
          Text(document.title)
        }
        .buttonStyle(.link)
      }
    }
    .sheet(item: $presentedDocument) { document in
      BundledDocumentView(document: document)
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
    let short = info?["CFBundleShortVersionString"] as? String ?? String(localized: "Unknown")
    let build = info?["CFBundleVersion"] as? String ?? String(localized: "Unknown")
    return "\(short) (\(build))"
  }()

  @State private var presentedDocument: BundledDocument?
  @State private var showsChangelog = false

  private func creditLink(_ title: String, _ urlString: String) -> some View {
    Link(title, destination: URL(string: urlString)!)
  }

}
