// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import ComposableArchitecture
import SwiftUI

// MARK: - OnboardingView

struct OnboardingView: View {

  // MARK: Internal

  let store: StoreOf<OnboardingFeature>

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider()
      VStack(spacing: 0) {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            switch store.step {
            case .welcome: welcome
            case .prepare: preparation
            case .shortcuts: shortcuts
            case .ready: ready
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(32)
        }
        Divider()
        footer
      }
    }
    .frame(width: 800, height: 570)
    .task { store.send(.appeared) }
    .task(id: modelCheckKey) { store.send(.checkModelsTapped) }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      store.send(.checkModelsTapped)
    }
  }

  // MARK: Private

  private var sidebar: some View {
    VStack(alignment: .leading, spacing: 24) {
      VStack(alignment: .leading, spacing: 10) {
        Image(nsImage: SwiftyCrowIcon.brandImage)
          .resizable().frame(width: 44, height: 44)
          .clipShape(.rect(cornerRadius: 10))
          .accessibilityHidden(true)
        Text("SwiftyCrow").font(.title2.weight(.semibold))
        Text("Quick Setup").foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 10) {
        ForEach(OnboardingFeature.Step.allCases) { step in
          HStack(spacing: 10) {
            Image(systemName: step.position < store.step.position ? "checkmark.circle.fill" : step.symbol)
              .frame(width: 20)
            Text(step.title).font(.callout.weight(.medium))
          }
          .foregroundStyle(step == store.step ? Color.accentColor : Color.secondary)
          .padding(12)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(step == store.step ? Color.accentColor.opacity(0.1) : .clear, in: .rect(cornerRadius: 10))
          .accessibilityAddTraits(step == store.step ? .isSelected : [])
        }
      }
      Spacer()
      Label("Entirely on your Mac", systemImage: "lock.shield")
        .font(.caption).foregroundStyle(.secondary)
    }
    .padding(22)
    .frame(width: 210)
    .background(.thinMaterial)
  }

  private var welcome: some View {
    Group {
      heading(
        "Read any text on your screen.",
        detail: "Translate the text on your screen without leaving the app you're using."
      )
      lesson(
        "Capture translation",
        icon: "viewfinder",
        detail: "Select part of your screen, read the translation, and copy text or a translated image."
      )
      lesson(
        "Live translation",
        icon: "captions.bubble",
        detail: "Choose an area once. Keep translating the text inside as it changes."
      )
      Label("No account or API key needed.", systemImage: "checkmark.shield")
        .font(.callout).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .center)
    }
  }

  private var preparation: some View {
    Group {
      heading("Prepare your first translation.", detail: "Allow screen access and choose the language you want to read.")
      ScreenRecordingPermissionRow(
        granted: store.hasScreenRecording,
        isRequesting: store.isRequestingAccess,
        grant: { store.send(.grantAccessTapped) },
        openSettings: { store.send(.openAccessSettingsTapped) }
      )
      .setupCard()
      if !store.hasScreenRecording {
        PermissionRelaunchNotice(isRelaunching: store.isRelaunching, error: store.relaunchError) { store.send(.relaunchTapped) }
          .setupCard()
      }
      VStack(alignment: .leading, spacing: 12) {
        Picker("Translate into", selection: Binding(get: { store.target }, set: { store.send(.targetChanged($0)) })) {
          if !store.targetLanguages.contains(store.target) {
            Text(store.target.displayName).tag(store.target)
          }
          ForEach(store.targetLanguages) { language in Text(language.displayName).tag(language) }
        }
        Picker(
          "Source language to check",
          selection: Binding(get: { store.modelSource }, set: { store.send(.modelSourceChanged($0)) })
        ) {
          if !store.targetLanguages.contains(store.modelSource) { Text(store.modelSource.displayName).tag(store.modelSource) }
          ForEach(store.targetLanguages) { language in Text(language.displayName).tag(language) }
        }
        languageReadiness
        Text("This checks only this language pair. Your source-language setting stays unchanged.")
          .font(.caption).foregroundStyle(.secondary)
        if store.modelReadiness == .downloadRequired {
          Text(
            "Download the languages you want to translate from and into. For English → Korean, download both English and Korean."
          )
          .font(.callout).foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 6) {
            Text("1. Open Language & Region below.")
            Text("2. Choose Translation Languages at the bottom.")
            Text("3. Download both languages, then return here.")
          }
          .font(.callout)
        }
        Button("Open Language & Region…") { openLanguageSettings() }
        Button("Check downloads again") { store.send(.checkModelsTapped) }
          .disabled(store.modelReadiness == .checking)
      }
      .setupCard()
    }
  }

  private var modelCheckKey: String {
    "\(store.modelSource.id)|\(store.target.id)|\(store.settings.translation.strategy)"
  }

  @ViewBuilder
  private var languageReadiness: some View {
    switch store.modelReadiness {
    case .unchecked:
      Label("Language downloads have not been checked.", systemImage: "questionmark.circle")

    case .checking:
      HStack { ProgressView().controlSize(.small)
        Text("Checking language downloads…")
      }

    case .installed:
      Label("Ready to translate this language pair.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)

    case .alternativeInstalled:
      Label("Ready using another installed translation mode.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)

    case .downloadRequired:
      Label("Download these languages to start translating.", systemImage: "arrow.down.circle").foregroundStyle(.orange)

    case .unsupported:
      Label("This language pair is not supported. Choose another language.", systemImage: "exclamationmark.circle")
        .foregroundStyle(.orange)

    case .sameLanguage:
      Label("Choose a different source language to check downloads.", systemImage: "info.circle")
    }
  }

  private var shortcuts: some View {
    Group {
      heading("Translate with a shortcut.", detail: "Start a translation from any app without opening the menu bar.")
      VStack(spacing: 18) {
        ShortcutSettingRow("Capture translation", \.selectRegion)
        Divider()
        ShortcutSettingRow("Live overlay (select a region)", \.liveOverlay)
        Divider()
        ShortcutSettingRow("Show / hide overlay (last region)", \.toggleLiveOverlay)
      }
      .setupCard()
      Text("Click a shortcut and press the keys you want. Press Escape to cancel, or use × to clear it.")
        .font(.callout).foregroundStyle(.secondary)
      Text("Changes are saved immediately. You can change all shortcuts later in Settings.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }

  private var ready: some View {
    Group {
      heading(
        "Your next translation is in the menu bar.",
        detail: "SwiftyCrow stays at the top of your screen, ready whenever you need it."
      )
      HStack {
        Text("SwiftyCrow").font(.headline)
        Spacer()
        Image(nsImage: SwiftyCrowIcon.menuBarImage)
          .foregroundStyle(.primary)
          .padding(9)
          .background(Color.accentColor.opacity(0.12), in: .rect(cornerRadius: 8))
        Image(systemName: "wifi")
        Image(systemName: "battery.100percent")
      }
      .padding(18)
      .background(.thinMaterial, in: .rect(cornerRadius: 14))
      lesson(
        "Start with a capture",
        icon: "cursorarrow.rays",
        detail: "Click the menu bar icon and choose Capture translation. Drag over text, or press Space to select a whole window."
      )
      lesson(
        "Come back anytime",
        icon: "questionmark.circle",
        detail: "Open Quick Setup again from the menu bar. Languages and shortcuts are always available in Settings."
      )
      if !store.hasScreenRecording {
        Label("You can finish setup now and allow screen access before your first capture.", systemImage: "info.circle")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Set up later") { store.send(.skipTapped) }
        .buttonStyle(.plain).foregroundStyle(.secondary)
      Spacer()
      if store.step != .welcome { Button("Back") { store.send(.backTapped) } }
      if store.step == .ready {
        Button("Finish") { store.send(.finishTapped(startCapture: false)) }
        if store.hasScreenRecording {
          Button("Try a capture") { store.send(.finishTapped(startCapture: true)) }
            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
      } else {
        Button("Continue") { store.send(.nextTapped) }
          .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
  }

  private func heading(_ title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(title).font(.system(size: 28, weight: .bold)).fixedSize(horizontal: false, vertical: true)
      Text(detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  private func lesson(_ title: LocalizedStringResource, icon: String, detail: LocalizedStringResource) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon).font(.title2).foregroundStyle(.tint).frame(width: 28)
      VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      }
    }
    .setupCard()
  }
}

extension OnboardingFeature.Step {
  var title: LocalizedStringResource {
    switch self {
    case .welcome: "Welcome"
    case .prepare: "Get ready"
    case .shortcuts: "Shortcuts"
    case .ready: "First capture"
    }
  }

  var symbol: String {
    switch self {
    case .welcome: "hand.wave"
    case .prepare: "slider.horizontal.3"
    case .shortcuts: "command"
    case .ready: "viewfinder"
    }
  }
}

extension View {
  fileprivate func setupCard() -> some View {
    frame(maxWidth: .infinity, alignment: .leading)
      .padding(18)
      .background(Color.primary.opacity(0.035), in: .rect(cornerRadius: 14))
      .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.07)) }
  }
}
