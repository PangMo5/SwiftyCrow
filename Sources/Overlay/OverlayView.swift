import SwiftUI

// MARK: - OverlayView

struct OverlayView: View {

  // MARK: Internal

  let lines: [OverlayLine]
  let isTranslating: Bool
  let isLive: Bool
  /// Translation failed (usually a missing model) — shows the "open Settings"
  /// hint banner along the bottom.
  var translationUnavailable = false
  /// Window live mode: the overlay is a thin region frame; the translation
  /// shows in a detached window.
  var frameOnly = false
  /// Whether the cursor is over the overlay — fades the move handle in/out.
  var showMoveHandle = false
  let onToggleLive: () -> Void
  let onClose: () -> Void

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
      .overlay(alignment: .topLeading) {
        // Drag handle: the only way to move the overlay. The window-background
        // drag is gated to this corner by the controller; the view itself takes
        // no hits, so the drag falls through to the window.
        MoveHandle()
          .opacity(showMoveHandle ? 1 : 0)
          .animation(.easeOut(duration: 0.15), value: showMoveHandle)
          .padding(8)
          .allowsHitTesting(false)
      }
      .overlay(alignment: .topTrailing) {
        HStack(spacing: 6) {
          if isTranslating {
            ProgressView()
              .controlSize(.small)
          }
          LiveHandle(isLive: isLive, action: onToggleLive)
          CloseHandle(action: onClose)
        }
        .padding(10)
      }
      .overlay(alignment: .bottom) {
        if translationUnavailable, !frameOnly {
          TranslationModelHint()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(8)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.15), value: frameOnly)
      .animation(.easeOut(duration: 0.15), value: translationUnavailable)
  }

  // MARK: Private

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

// MARK: - LiveHandle

/// Always-present control that toggles Live. It carries colour while Live is on
/// (a pulsing red dot + red-tinted glass) and goes monochrome when off.
private struct LiveHandle: View {

  // MARK: Internal

  let isLive: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
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
    .buttonStyle(.plain)
    .onAppear { pulse = true }
    .help(isLive ? "Live translation on — click to pause" : "Live translation off — click to resume")
  }

  // MARK: Private

  @State private var pulse = false

}

// MARK: - MoveHandle

/// Purely visual grab affordance shown at the top-left while the cursor is over
/// the overlay. The actual move is the window-background drag the controller
/// enables in this corner, so the handle takes no hits itself.
private struct MoveHandle: View {
  var body: some View {
    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
      .font(.system(size: 9, weight: .bold))
      .foregroundStyle(.secondary)
      .frame(width: 24, height: 18)
      .glassEffect(.regular, in: Capsule())
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
  }
}
