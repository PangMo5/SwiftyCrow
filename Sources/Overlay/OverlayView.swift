import KeyboardShortcuts
import SwiftUI

// MARK: - OverlayView

struct OverlayView: View {

  // MARK: Internal

  let lines: [OverlayLine]
  let isTranslating: Bool
  let isLive: Bool
  /// Window live mode: the overlay is a thin region frame; the translation
  /// shows in a detached window.
  var frameOnly = false
  var showGuide = true

  var body: some View {
    bodyContent
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .overlay(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .strokeBorder(
            frameOnly ? AnyShapeStyle(.tint) : AnyShapeStyle(.white.opacity(0.35)),
            lineWidth: frameOnly ? 2.5 : 1.5
          )
      )
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 6) {
          if isLive {
            LiveBadge()
          }
          if isTranslating {
            ProgressView()
              .controlSize(.small)
          }
        }
        .padding(10)
      }
      .animation(.easeOut(duration: 0.15), value: frameOnly)
  }

  // MARK: Private

  @ViewBuilder
  private var bodyContent: some View {
    if frameOnly {
      // Region marker only — the translation lives in the detached window.
      Color.clear
    } else if !lines.isEmpty {
      TranslationOverlayLayer(lines: lines)
    } else if showGuide {
      ScrollView(.vertical, showsIndicators: false) {
        EmptyOverlayGuide()
      }
      .scrollBounceBehavior(.basedOnSize)
      .padding(.horizontal, 12)
      .padding(.vertical, 8)
      .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .padding(12)
    } else {
      // Idle after a Live toggle: just a transparent, draggable frame.
      Color.clear
    }
  }
}

// MARK: - LiveBadge

private struct LiveBadge: View {

  // MARK: Internal

  var body: some View {
    HStack(spacing: 4) {
      Circle()
        .fill(.red)
        .frame(width: 7, height: 7)
        .opacity(pulse ? 0.35 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
        .onAppear { pulse = true }
      Text("LIVE")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .foregroundStyle(.primary)
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .glassEffect(.regular, in: Capsule())
  }

  // MARK: Private

  @State private var pulse = false

}

// MARK: - EmptyOverlayGuide

private struct EmptyOverlayGuide: View {

  // MARK: Internal

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 6) {
        Image(systemName: "rectangle.dashed")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.secondary)
        Text("Drag this window over text to translate.")
          .font(.subheadline)
          .foregroundStyle(.primary)
      }

      VStack(alignment: .leading, spacing: 4) {
        GuideRow(
          icon: "camera.viewfinder",
          title: "Capture region",
          shortcut: shortcutDescription(for: .selectRegion)
        )
        GuideRow(
          icon: "play.fill",
          title: "Toggle Live Mode",
          shortcut: shortcutDescription(for: .toggleLive)
        )
        GuideRow(
          icon: "rectangle.on.rectangle",
          title: "Toggle overlay",
          shortcut: shortcutDescription(for: .toggleOverlay)
        )
      }

      Text("Bind hotkeys in Settings → Shortcuts.")
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: Private

  private func shortcutDescription(for name: KeyboardShortcuts.Name) -> String? {
    KeyboardShortcuts.getShortcut(for: name)?.description
  }
}

// MARK: - GuideRow

private struct GuideRow: View {
  let icon: String
  let title: String
  let shortcut: String?

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: icon)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 14)
      Text(title)
        .font(.callout)
        .foregroundStyle(.primary)
      Spacer(minLength: 8)
      Text(shortcut ?? "Unbound")
        .font(.system(.caption, design: .monospaced))
        .foregroundStyle(shortcut == nil ? .tertiary : .secondary)
    }
  }
}
