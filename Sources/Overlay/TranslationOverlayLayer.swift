import SwiftUI

/// Draws each translated line at its source bounding box, sized to that box's
/// height. Shared by the live overlay (Liquid Glass chips) and the
/// region-capture result. The result uses `glass: false` because ImageRenderer
/// can't rasterize Liquid Glass, so a solid chip keeps the saved/copied image
/// matching what's on screen.
struct TranslationOverlayLayer: View {
  let lines: [OverlayLine]
  var glass = true

  var body: some View {
    GeometryReader { proxy in
      ForEach(lines) { line in
        let box = line.box
        let width = max(1, box.width * proxy.size.width)
        let height = max(1, box.height * proxy.size.height)
        let fontSize = max(8, min(96, height * 0.85))

        chip(for: line, fontSize: fontSize)
          .frame(width: width + 12, height: height + 4, alignment: .leading)
          .position(
            x: box.midX * proxy.size.width,
            y: box.midY * proxy.size.height
          )
      }
    }
  }

  @ViewBuilder
  private func chip(for line: OverlayLine, fontSize: CGFloat) -> some View {
    let label = Text(line.translated ?? line.sourceText)
      .font(.system(size: fontSize, weight: .semibold))
      .multilineTextAlignment(.leading)
      .lineLimit(1)
      .truncationMode(.tail)
      .minimumScaleFactor(0.4)
      .padding(.horizontal, 6)
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)

    if glass {
      label
        .foregroundStyle(line.translated == nil ? .secondary : .primary)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    } else {
      label
        .foregroundStyle(.white)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
  }
}
