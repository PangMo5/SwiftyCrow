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
      chips(in: proxy.size)
    }
  }

  @ViewBuilder
  private func chips(in size: CGSize) -> some View {
    ForEach(lines) { line in
      let box = line.box
      let width = max(1, box.width * size.width)
      let height = max(1, box.height * size.height)
      let rows = max(1, line.rowCount)
      let fontSize = max(8, min(96, height / CGFloat(rows) * 0.85))

      chip(for: line, fontSize: fontSize, rows: rows)
        .frame(width: width + 12, height: height + 4, alignment: .leading)
        .position(
          x: box.midX * size.width,
          y: box.midY * size.height
        )
    }
  }

  @ViewBuilder
  private func chip(for line: OverlayLine, fontSize: CGFloat, rows: Int) -> some View {
    let label = Text(line.translated ?? line.sourceText)
      .font(.system(size: fontSize, weight: .semibold))
      .multilineTextAlignment(.leading)
      .lineLimit(rows)
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
