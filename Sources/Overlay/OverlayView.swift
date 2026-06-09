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
    VStack(spacing: 16) {
      Image(systemName: "text.viewfinder")
        .font(.system(size: 36, weight: .light))
        .foregroundStyle(.tint)
        .symbolRenderingMode(.hierarchical)

      VStack(spacing: 4) {
        Text("Drag over text to translate")
          .font(.headline)
        Text("Position this window, then capture or turn on Live.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 8) {
        GuideRow(icon: "viewfinder", title: "Capture region", shortcut: shortcut(for: .selectRegion))
        GuideRow(icon: "dot.radiowaves.left.and.right", title: "Toggle Live", shortcut: shortcut(for: .toggleLive))
        GuideRow(icon: "rectangle.on.rectangle", title: "Toggle overlay", shortcut: shortcut(for: .toggleOverlay))
      }
      .padding(.top, 2)
    }
    .padding(22)
    .frame(maxWidth: .infinity)
  }

  // MARK: Private

  private func shortcut(for name: KeyboardShortcuts.Name) -> String? {
    KeyboardShortcuts.getShortcut(for: name)?.description
  }
}

// MARK: - GuideRow

private struct GuideRow: View {
  let icon: String
  let title: String
  let shortcut: String?

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: icon)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 18)
      Text(title)
        .font(.callout)
      Spacer(minLength: 12)
      Text(shortcut ?? "Set in Settings")
        .font(shortcut == nil ? .caption : .system(.caption, design: .rounded).weight(.medium))
        .foregroundStyle(shortcut == nil ? .tertiary : .secondary)
        .padding(.horizontal, shortcut == nil ? 0 : 7)
        .padding(.vertical, shortcut == nil ? 0 : 3)
        .background {
          if shortcut != nil {
            Capsule().fill(.secondary.opacity(0.15))
          }
        }
    }
  }
}
