// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import AppKit
import ComposableArchitecture
import CoreGraphics
import DependenciesMacros
import Foundation
import Sharing
import SwiftUI

// MARK: - RegionCaptureFeature

@Reducer
struct RegionCaptureFeature {

  // MARK: Internal

  @ObservableState
  struct State: Equatable {
    var target: CaptureTarget
    var imageData: Data?
    var imageSize = CGSize.zero
    var overlayLines = [OverlayLine]()
    var isTranslating = false
    /// The capture is taking long enough that it needs explaining — practically
    /// always Vision loading a cold document model, which takes tens of seconds.
    /// Without this the window is an unlabelled spinner and reads as a hang.
    var isTakingLong = false
    var lastError: String?
    /// True when a translation failed — almost always because the language's
    /// on-device model isn't installed. Drives the "open Settings" hint.
    var translationUnavailable = false
    /// Set once the user copies the text; the window observes this to close.
    /// Image save/copy renders the complete capture in the result view; the
    /// window controller handles delivery and closes the originating window.
    var finished = false

    @Shared(.settings) var settings
  }

  enum Action {
    case task
    case captureIsTakingLong
    case captured(Result<CapturedRegion, any Error>)
    case translationResponse(id: UUID, translation: TranslatedText, target: Locale.Language)
    case translationUnavailable(lineIDs: Set<UUID>, message: String?)
    case copyOriginalRequested
    case copyTranslationRequested
  }

  @Dependency(\.continuousClock) var clock
  @Dependency(\.languageDetection) var languageDetection
  @Dependency(\.ocr) var ocr
  @Dependency(\.pasteboard) var pasteboard
  @Dependency(\.screenCapture) var screenCapture
  @Dependency(\.translation) var translation
  @Dependency(\.uuid) var uuid

  var body: some Reducer<State, Action> {
    Reduce { state, action in
      switch action {
      case .task:
        let target = state.target
        return .merge(
          .run { [clock] send in
            try await clock.sleep(for: .seconds(2))
            await send(.captureIsTakingLong)
          },
          captureEffect(target: target, settings: state.$settings)
        )

      case .captureIsTakingLong:
        // The capture may already have landed; the hint would be stale then.
        guard state.imageData == nil, state.lastError == nil else { return .none }
        state.isTakingLong = true
        return .none

      case .captured(.success(let captured)):
        state.isTakingLong = false
        state.imageData = captured.pngData
        state.imageSize = captured.size
        let configured = state.settings.languages.source
        let target = state.settings.languages.target.localeLanguage
        let strategy = state.settings.translation.strategy
        // Auto resolves a source per line (with a whole-capture fallback for
        // short lines). Lines already in the target language show their source.
        let lineSources = languageDetection.resolveSources(for: captured.lines.map(\.text), configured: configured)
        let sourceLines = captured.lines.indices.map {
          OverlayLine.Source(
            recognized: captured.lines[$0],
            language: lineSources[$0].localeLanguage
          )
        }
        let preservesSource = sourceLines.indices.map {
          OverlayTranslationPolicy.preservesSource(at: $0, in: sourceLines)
        }

        var newLines = [OverlayLine]()
        // Lines to translate, grouped by source language (one session per group).
        var groups = [String: (source: Locale.Language, items: [TranslationLine])]()
        for (index, line) in captured.lines.enumerated() {
          let source = lineSources[index].localeLanguage
          let sameLanguage = source.usesSameWritingSystem(as: target)
          let sourceLine = sourceLines[index]
          let needsTranslation = !sameLanguage && !preservesSource[index]
          let overlayLine = OverlayLine(
            id: uuid(),
            source: sourceLine,
            initialContent: needsTranslation ? .pending : .source
          )
          newLines.append(overlayLine)
          if needsTranslation {
            groups[source.maximalIdentifier, default: (source, [])].items
              .append(TranslationLine(
                id: overlayLine.id,
                text: line.text,
                attributedText: overlayLine.source.attributedTextForTranslation(),
                trailingContext: OverlayTranslationPolicy.trailingContext(
                  at: index,
                  in: sourceLines
                )
              ))
          }
        }
        state.overlayLines = newLines

        guard !state.overlayLines.isEmpty, !groups.isEmpty else { return .none }
        state.isTranslating = true
        let batches = Array(groups.values)
        return Effect<Action>.run { send in
          await withTaskGroup(of: Void.self) { group in
            for batch in batches {
              group.addTask {
                var remaining = Set(batch.items.map(\.id))
                do {
                  for try await result in translation.translateBatch(batch.items, batch.source, target, strategy) {
                    remaining.remove(result.id)
                    await send(.translationResponse(
                      id: result.id,
                      translation: TranslatedText(
                        text: result.text,
                        attributedText: result.attributedText,
                        modelNotice: result.modelNotice
                      ),
                      target: target
                    ))
                  }
                } catch is CancellationError {
                  // Window closed mid-flight — nothing to report.
                  return
                } catch {
                  // The model for this language likely isn't installed; show the
                  // hint pointing the user to System Settings to download it.
                  guard !remaining.isEmpty else { return }
                  await send(.translationUnavailable(lineIDs: remaining, message: error.localizedDescription))
                  return
                }
                if !remaining.isEmpty {
                  await send(.translationUnavailable(lineIDs: remaining, message: nil))
                }
              }
            }
          }
        }

      case .captured(.failure(let error)):
        state.isTakingLong = false
        state.lastError = error.localizedDescription
        return .none

      case .translationResponse(let id, let translation, let target):
        let text = translation.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
          if let index = state.overlayLines.firstIndex(where: { $0.id == id }) {
            state.overlayLines[index].showUnavailable()
          }
          state.isTranslating = state.overlayLines.contains(where: \.isPending)
          state.lastError = "Translation returned empty text."
          return .none
        }
        if
          let index = state.overlayLines.firstIndex(where: { $0.id == id }),
          state.overlayLines[index].isPending || state.overlayLines[index].translatedText == text
        {
          state.overlayLines[index].showTranslation(
            text,
            attributedText: text == translation.text ? translation.attributedText : nil,
            language: target,
            modelNotice: translation.modelNotice
          )
        }
        state.isTranslating = state.overlayLines.contains(where: \.isPending)
        return .none

      case .translationUnavailable(let lineIDs, let message):
        for index in state.overlayLines.indices where lineIDs.contains(state.overlayLines[index].id) {
          state.overlayLines[index].showUnavailable()
        }
        state.isTranslating = state.overlayLines.contains(where: \.isPending)
        state.lastError = message ?? "Translation did not return every requested line."
        if message != nil {
          state.translationUnavailable = true
        }
        return .none

      case .copyOriginalRequested:
        let text = state.overlayLines.map(\.source.text).joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        state.finished = true
        return .run { _ in await pasteboard.copyString(text) }

      case .copyTranslationRequested:
        guard !state.overlayLines.contains(where: \.isPending) else { return .none }
        let text = state.overlayLines
          .map(\.displayedText)
          .filter { !$0.isEmpty }
          .joined(separator: "\n")
        guard !text.isEmpty else { return .none }
        state.finished = true
        return .run { _ in await pasteboard.copyString(text) }
      }
    }
  }

  // MARK: Private

  private func captureEffect(target: CaptureTarget, settings: Shared<AppSettings>) -> Effect<Action> {
    .run { [clock, ocr, screenCapture] send in
      let captured = await Result {
        let snapshot = settings.wrappedValue
        // Both stages are bounded so a daemon that stops answering surfaces as an
        // error instead of an endlessly spinning window, and the message names
        // which stage it was.
        let image = try await withDeadline(
          CaptureDeadline.screenCapture,
          stage: .screenCapture,
          clock: clock
        ) {
          let image: CGImage =
            switch target {
            case .region(let region):
              try await screenCapture.captureImage(
                region,
                displayID(coveringMostOf: region),
                ProcessInfo.processInfo.processIdentifier
              )

            case .window(let id, _):
              try await screenCapture.captureWindow(id)
            }
          return image
        }
        let result = try await withDeadline(CaptureDeadline.ocr, stage: .ocr, clock: clock) {
          try await ocr.recognizeText(image, snapshot.languages.source)
        }
        return CapturedRegion(
          pngData: image.pngData,
          size: CGSize(width: image.width, height: image.height),
          lines: result.lines
        )
      }
      if case .failure(let error) = captured {
        Log.capture.error("Region capture failed: \(error.localizedDescription, privacy: .public)")
      }
      await send(.captured(captured))
    }
  }
}

// MARK: - CapturedRegion

struct CapturedRegion: Equatable, Sendable {
  var pngData: Data?
  var size: CGSize
  var lines: [OCRResult.Line]
}

// MARK: - CGImage PNG

extension CGImage {
  var pngData: Data? {
    let rep = NSBitmapImageRep(cgImage: self)
    return rep.representation(using: .png, properties: [:])
  }
}

// MARK: - RegionResultClient

@DependencyClient
struct RegionResultClient {
  /// Captures `target` (a dragged region or a picked window), runs OCR + per-line
  /// translation, and shows the result window with the translation drawn in place
  /// over the screenshot.
  var present: @Sendable (_ target: CaptureTarget) async -> Void
}

// MARK: DependencyKey

extension RegionResultClient: DependencyKey {
  static let liveValue: RegionResultClient = {
    // The controller touches AppKit, so build it lazily on the main actor.
    nonisolated(unsafe) var controller: RegionResultWindowController?
    let resolve: @MainActor @Sendable () -> RegionResultWindowController = {
      if let controller { return controller }
      let new = RegionResultWindowController()
      controller = new
      return new
    }
    return RegionResultClient(
      present: { target in await resolve().present(target: target) }
    )
  }()
}

extension DependencyValues {
  var regionResult: RegionResultClient {
    get { self[RegionResultClient.self] }
    set { self[RegionResultClient.self] = newValue }
  }
}

// MARK: - RegionResultWindowController

@MainActor
private final class RegionResultWindowController {

  // MARK: Internal

  func present(target: CaptureTarget) {
    panel?.close()

    // The app is normally a menu-bar agent (.accessory), which can't become
    // frontmost — so it never receives ⌘-key events. Promote to .regular while
    // a result window is open so its shortcuts work, then revert on close. The
    // shared coordinator ref-counts this against the Settings window so closing
    // one while the other is open doesn't drop the app back to accessory early.
    WindowActivation.opened()

    let store = Store(initialState: RegionCaptureFeature.State(target: target)) {
      RegionCaptureFeature()
    }
    let panel = ResultPanel(
      contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
      styleMask: [.borderless, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.level = .floating
    panel.isMovableByWindowBackground = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

    // NSHostingController (not NSHostingView) joins the responder chain, so
    // SwiftUI .keyboardShortcut and .help work inside the window.
    let hosting = NSHostingController(
      rootView: RegionResultView(
        store: store,
        owningWindow: { [weak panel] in panel },
        onSaveImage: { [weak self, weak panel] data in self?.saveImage(data, panel: panel) },
        onCopyImage: { [weak self, weak panel] data in self?.copyImage(data, panel: panel) },
        onClose: { [weak panel] in panel?.close() }
      )
    )
    panel.contentViewController = hosting

    panel.center()
    panel.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)

    self.panel = panel
    // Resize the window to the screenshot's aspect ratio once the capture
    // lands, so the image initially fits the available screen.
    observeToken = observe { [weak self, weak panel] in
      guard let self, let panel, store.imageSize != .zero else { return }
      fitWindow(panel, toPixelSize: store.imageSize)
    }
    NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification,
      object: panel,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        // Balance the opened() from this panel's present() exactly once — even
        // when a newer present() has already replaced `panel` (so the identity
        // guard below is false). Otherwise the ref-count would leak on replace.
        WindowActivation.closed()
        if self?.panel === panel { self?.panel = nil }
      }
    }
  }

  // MARK: Private

  @Dependency(\.date.now) private var now
  @Dependency(\.pasteboard) private var pasteboard
  @Dependency(\.savePanel) private var savePanel

  private var panel: NSWindow?
  private var observeToken: ObserveToken?

  private func saveImage(_ data: Data, panel: NSWindow?) {
    Task { @MainActor in
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd-HHmmss"
      let name = "SwiftyCrow-\(formatter.string(from: now)).png"
      if await savePanel.savePNG(data, name) {
        panel?.close()
      }
    }
  }

  private func copyImage(_ data: Data, panel: NSWindow?) {
    Task { @MainActor in
      await pasteboard.copyImage(data)
      panel?.close()
    }
  }

  private func fitWindow(_ panel: NSWindow, toPixelSize pixelSize: CGSize) {
    let screen = panel.screen ?? NSScreen.main
    let scale = screen?.backingScaleFactor ?? 2
    let visible = screen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
    let chromeHeight: CGFloat = 86
    let padding: CGFloat = 24

    var width = pixelSize.width / scale + padding
    var height = pixelSize.height / scale + padding
    let maxWidth = visible.width * 0.85
    let maxHeight = visible.height * 0.85 - chromeHeight
    let ratio = min(min(maxWidth / width, maxHeight / height), 1)
    width *= ratio
    height *= ratio

    panel.setContentSize(CGSize(width: max(360, width), height: height + chromeHeight))
    panel.center()
  }
}

// MARK: - ResultPanel

/// A borderless NSWindow (not NSPanel) so it reliably becomes the key window
/// and receives ⌘-key events.
private final class ResultPanel: NSWindow {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    true
  }
}
