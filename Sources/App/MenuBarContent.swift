// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI

// MARK: - MenuBarContent

struct MenuBarContent: View {

  // MARK: Internal

  let store: StoreOf<AppFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      languageSummary
      VStack(spacing: 8) {
        Button { store.send(.capture(.selectRegionRequested)) } label: {
          actionLabel(
            "Capture translation",
            detail: "Translate and copy text from your screen",
            icon: "viewfinder",
            shortcut: store.settings.shortcuts.selectRegion
          )
        }
        .buttonStyle(MenuCardButtonStyle())
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("start-capture")
      }
      .controlSize(.large)
      liveSection
      if store.capture.translationUnavailable || store.capture.lastError != nil {
        CaptureErrorView(store: store.scope(state: \.capture, action: \.capture))
      }
      Divider()
      footer
    }
    .padding(18)
    .frame(width: 350)
  }

  // MARK: Private

  @Environment(\.openWindow) private var openWindow

  private var header: some View {
    HStack(spacing: 10) {
      Image(nsImage: SwiftyCrowIcon.brandImage)
        .resizable().frame(width: 36, height: 36)
        .clipShape(.rect(cornerRadius: 8))
        .accessibilityHidden(true)
      Text("SwiftyCrow").font(.headline)
      Spacer(minLength: 0)
      if store.capture.overlayActive {
        Circle().fill(store.capture.isLive ? Color.green : Color.orange).frame(width: 7, height: 7)
          .accessibilityLabel(store.capture.isLive ? "Live translation is running" : "Live translation is paused")
      }
    }
  }

  private var languageSummary: some View {
    Button {
      store.send(.settingsScreen(.paneSelected(.languages)))
      showSettings()
    } label: {
      HStack(spacing: 8) {
        Image(systemName: "globe").foregroundStyle(.secondary)
        Text(store.settings.languages.source.displayName).lineLimit(1)
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
        Text(store.settings.languages.target.displayName).fontWeight(.medium).lineLimit(1)
        Spacer(minLength: 0)
        Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
      }
      .font(.callout)
      .padding(10)
      .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 10))
      .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Change translation languages in Settings")
  }

  private var liveSection: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Button { store.send(.capture(.liveSelectRequested)) } label: {
          actionLabel(
            "Live translation",
            detail: "Select an area to translate continuously",
            icon: "captions.bubble",
            shortcut: store.settings.shortcuts.liveOverlay
          )
        }
        .buttonStyle(MenuLiveActionButtonStyle())
        .accessibilityIdentifier("start-live-translation")
        Toggle("Show overlay", isOn: Binding(
          get: { store.capture.overlayActive },
          set: { store.send(.capture(.setOverlayVisible($0))) }
        ))
        .toggleStyle(.switch).labelsHidden()
        .disabled(!store.capture.overlayFrame.hasSelection && !store.capture.overlayActive)
        .help(store.capture.overlayFrame.hasSelection
          ? "Show or hide translation in the selected area"
          : "Select an area with Live translation first")
          .accessibilityIdentifier("overlay-visibility")
          .padding(.trailing, 14)
      }
      if store.capture.overlayActive {
        Divider().padding(.horizontal, 14)
        liveControls.padding(14)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 12))
    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
  }

  private var liveControls: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label(
          store.capture.isLive ? "Translating live" : "Translation paused",
          systemImage: store.capture.isLive
            ? "waveform"
            : "pause.circle"
        )
        .font(.callout.weight(.medium))
        Spacer()
        Button {
          store.send(.capture(.toggleLiveRequested))
        } label: {
          Image(systemName: store.capture.isLive ? "pause.fill" : "play.fill")
        }
        .help(store.capture.isLive ? "Pause translation" : "Resume translation")
        .accessibilityLabel(store.capture.isLive ? "Pause translation" : "Resume translation")
      }
      Picker("Display", selection: Binding(get: { store.settings.overlay.liveMode }, set: { store.send(.setLiveMode($0)) })) {
        ForEach(OverlayLiveMode.allCases) { mode in Text(mode.displayName).tag(mode) }
      }
      .pickerStyle(.segmented).labelsHidden()
      MenuTranslationNotice(lines: store.capture.overlayLines)
    }
  }

  private var footer: some View {
    HStack {
      Button { showSettings() } label: { Label("Settings", systemImage: "gearshape") }
        .keyboardShortcut(",", modifiers: .command)
      Spacer()
      Menu {
        Button("What’s New") { store.send(.whatsNewTapped) }
        Button("Quick Setup") { store.send(.onboarding(.openRequested)) }
        Button("Check for Updates…") {
          NSApp.activate(ignoringOtherApps: true)
          store.send(.checkForUpdatesTapped)
        }
        .disabled(!store.canCheckForUpdates)
        Divider()
        Button("Quit SwiftyCrow") { NSApplication.shared.terminate(nil) }
          .keyboardShortcut("q", modifiers: .command)
      } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("More options")
    }
    .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
  }

  private func actionLabel(
    _ title: LocalizedStringResource,
    detail: LocalizedStringResource,
    icon: String,
    shortcut: HotKey?
  ) -> some View {
    HStack(spacing: 12) {
      Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 25)
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.body.weight(.semibold))
        Text(detail).font(.caption).opacity(0.75).fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 0)
      if let shortcut { Text(shortcut.symbols).font(.caption.monospaced()).opacity(0.75) }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(.rect)
  }

  private func showSettings() {
    openWindow(id: settingsWindowID)
    NSApp.activate(ignoringOtherApps: true)
  }
}

// MARK: - MenuCardButtonStyle

private struct MenuCardButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(14)
      .background(Color.primary.opacity(configuration.isPressed ? 0.09 : 0.035), in: .rect(cornerRadius: 12))
      .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)) }
  }
}

// MARK: - MenuLiveActionButtonStyle

private struct MenuLiveActionButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .padding(14)
      .contentShape(.rect)
      .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0), in: .rect(cornerRadius: 12))
  }
}

// MARK: - MenuTranslationNotice

/// Keep live-session context with its controls. Detailed model notices remain
/// available without creating a second material panel below the live card.
private struct MenuTranslationNotice: View {

  // MARK: Internal

  let lines: [OverlayLine]

  var body: some View {
    if lines.contains(where: { $0.source.needsReview }) {
      Label("Some text may be misread. Compare the translation with the original.", systemImage: "text.magnifyingglass")
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
    if !modelNotices.isEmpty {
      DisclosureGroup(isExpanded: $expanded) {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(modelNotices, id: \.self) { notice in
            Text(notice)
              .fixedSize(horizontal: false, vertical: true)
          }
          Button("Language model settings…") { openLanguageSettings() }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
      } label: {
        Label("Using another installed model", systemImage: "info.circle")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .accessibilityIdentifier("live-model-details")
    }
  }

  // MARK: Private

  @State private var expanded = false

  private var modelNotices: [String] {
    Array(Set(lines.compactMap(\.modelNotice))).sorted()
  }

}
