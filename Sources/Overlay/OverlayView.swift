// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

// MARK: - OverlayChromeMetrics

enum OverlayChromeMetrics {
  static let moveHandleSize = CGSize(width: 56, height: 40)
}

// MARK: - OverlayView

struct OverlayView: View {

  // MARK: Internal

  let lines: [OverlayLine]
  let isTranslating: Bool
  let isLive: Bool
  /// Translation failed (usually a missing model). Details and recovery live
  /// in the warning popover, without a duplicate banner over the source text.
  var translationUnavailable = false
  var lastError: String? = nil
  /// Recognition or subsequent layout analysis has exceeded the hint delay.
  var isPreparingRecognition = false
  /// Window live mode: the overlay is a thin region frame; the translation
  /// shows in a detached window.
  var frameOnly = false
  /// Whether the cursor is over the overlay — fades the move handle in/out.
  var showMoveHandle = false
  var allowsRepositioning = true
  let onToggleLive: () -> Void
  let onClose: () -> Void

  var body: some View {
    bodyContent
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .overlay {
        // Keep the overlay boundary visible in both modes. Source-replacement
        // patches inside the boundary remain borderless.
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(
            frameOnly ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.35)),
            lineWidth: frameOnly ? 2.5 : 1.5
          )
      }
      .overlay(alignment: .topLeading) {
        // Drag handle: the only way to move the overlay. Use SwiftUI's native
        // window gesture so dragging remains reliable inside NSHostingView.
        if allowsRepositioning {
          MoveHandle()
            .opacity(showsControls ? 1 : 0)
            .animation(.easeOut(duration: 0.15), value: showsControls)
            .padding(8)
            .frame(
              width: OverlayChromeMetrics.moveHandleSize.width,
              height: OverlayChromeMetrics.moveHandleSize.height,
              alignment: .topLeading
            )
            .contentShape(.rect)
            .gesture(WindowDragGesture())
        }
      }
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 6) {
          if hasWarnings {
            CaptureWarningButton(
              needsReview: lines.contains(where: { $0.source.needsReview }),
              translationUnavailable: translationUnavailable,
              message: lastError
            )
          }
          // A small spinner while the overlay is busy (capturing / OCR or
          // translating); nothing otherwise.
          if isTranslating {
            ProgressView()
              .controlSize(.small)
          }
          if showsControls || hasWarnings {
            HStack(spacing: 6) {
              if showsControls {
                LiveHandle(isLive: isLive, action: onToggleLive)
              } else {
                // Reserve the exact localized label width without mounting
                // an invisible pulsing indicator. Hover cannot move the
                // leading warning away from the cursor.
                LiveHandleLabel(isLive: isLive).hidden()
              }
              CloseHandle(action: onClose)
                .opacity(showsControls ? 1 : 0)
            }
            .allowsHitTesting(showsControls)
            .accessibilityHidden(!showsControls)
            .transition(.move(edge: .trailing).combined(with: .opacity))
          }
        }
        .animation(.easeOut(duration: 0.18), value: showsControls)
        .padding(10)
      }
      .overlay(alignment: .bottom) {
        if isPreparingRecognition {
          // Shown in Window mode too: there the overlay is just a frame, which
          // makes an unexplained wait even harder to read.
          PreparingRecognitionNote()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.15), value: frameOnly)
      .animation(.easeOut(duration: 0.15), value: translationUnavailable)
      .animation(.easeOut(duration: 0.15), value: isPreparingRecognition)
  }

  // MARK: Private

  private var hasWarnings: Bool {
    lastError != nil || translationUnavailable || lines.contains(where: { $0.source.needsReview })
  }

  private var showsControls: Bool {
    showMoveHandle
  }

  @ViewBuilder
  private var bodyContent: some View {
    if frameOnly {
      // Region marker only — the translation lives in the detached window.
      Color.clear
    } else if !lines.isEmpty {
      TranslationOverlayLayer(lines: lines)
    } else {
      // Idle (live off / waiting): a transparent, pass-through frame.
      Color.clear
    }
  }
}

// MARK: - CaptureWarningButton

/// Remains available even when setup advice is dismissed or the translation
/// lives in a separate window. The native popover owns its own mouse handling;
/// the overlay's interior continues passing events through to the source app.
private struct CaptureWarningButton: View {

  // MARK: Internal

  let needsReview: Bool
  let translationUnavailable: Bool
  let message: String?

  var body: some View {
    Button { isPresented.toggle() } label: {
      Image(systemName: "exclamationmark.triangle")
        .foregroundStyle(.orange)
        .frame(width: 24, height: 24)
        .contentShape(.rect)
    }
    .buttonStyle(.plain)
    .help("Show capture warnings")
    .accessibilityLabel("Show capture warnings")
    .popover(isPresented: $isPresented, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 12) {
        if translationUnavailable {
          TranslationFailureDetails(message: message)
        } else if let message {
          Label("Capture", systemImage: "exclamationmark.triangle.fill")
            .fontWeight(.semibold)
          Text(message)
            .fixedSize(horizontal: false, vertical: true)
        }
        if needsReview {
          Label("Some text may be misread. Compare the translation with the original.", systemImage: "text.magnifyingglass")
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .font(.callout)
      .padding(16)
      .frame(width: 320, alignment: .leading)
      .textSelection(.enabled)
    }
  }

  // MARK: Private

  @State private var isPresented = false

}

// MARK: - LiveHandle

/// Always-present control that toggles Live. It carries colour while Live is on
/// (a pulsing red dot + red-tinted glass) and goes monochrome when off.
private struct LiveHandle: View {

  // MARK: Internal

  let isLive: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      LiveHandleLabel(isLive: isLive, pulse: pulse)
    }
    .buttonStyle(.plain)
    .onAppear { pulse = true }
    .help(isLive ? "Live translation on — click to pause" : "Live translation off — click to resume")
    .accessibilityLabel(isLive ? "Pause translation" : "Resume translation")
  }

  // MARK: Private

  @State private var pulse = false

}

// MARK: - LiveHandleLabel

private struct LiveHandleLabel: View {
  let isLive: Bool
  var pulse = false

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(isLive ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .frame(width: 7, height: 7)
        .opacity(isLive && pulse ? 0.35 : 1)
        .animation(
          isLive ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true) : .default,
          value: pulse
        )
      Text("LIVE")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(isLive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .glassEffect(.regular.tint(isLive ? .red : nil), in: Capsule())
  }
}

// MARK: - MoveHandle

/// Grab affordance shown at the top-left while the cursor is over the overlay.
private struct MoveHandle: View {
  var body: some View {
    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.secondary)
      .frame(width: 24, height: 18)
      .glassEffect(.regular, in: Capsule())
      .help("Drag to move overlay")
      .accessibilityLabel("Move overlay")
      .accessibilityHint("Drag to reposition the translation overlay")
  }
}

// MARK: - CloseHandle

private struct CloseHandle: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "xmark")
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(width: 18, height: 18)
        .glassEffect(.regular, in: Circle())
    }
    .buttonStyle(.plain)
    .help("Close overlay")
    .accessibilityLabel("Close overlay")
  }
}
