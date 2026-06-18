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

      Group {
        if line.isVerticalBlock {
          blockChip(for: line, width: width, height: height)
        } else {
          let rows = max(1, line.rowCount)
          let fontSize = max(8, min(96, height / CGFloat(rows) * 0.85))
          lineChip(for: line, fontSize: fontSize, rows: rows)
            .frame(width: width + 12, height: height + 4, alignment: .leading)
        }
      }
      .position(
        x: box.midX * size.width,
        y: box.midY * size.height
      )
    }
  }

  @ViewBuilder
  private func lineChip(for line: OverlayLine, fontSize: CGFloat, rows: Int) -> some View {
    background(
      for: line,
      cornerRadius: 8,
      label: Text(line.translated ?? line.sourceText)
        .font(.system(size: fontSize, weight: .semibold))
        .multilineTextAlignment(.leading)
        .lineLimit(rows)
        .truncationMode(.tail)
        .minimumScaleFactor(0.4)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    )
  }

  /// A stitched block of vertical CJK columns: fill the whole box with the
  /// translation as a wrapped paragraph, sized so it roughly fills the area, and
  /// scaled in by `minimumScaleFactor` if the wrapped text would overflow.
  @ViewBuilder
  private func blockChip(for line: OverlayLine, width: CGFloat, height: CGFloat) -> some View {
    let text = line.translated ?? line.sourceText
    let fontSize = max(8, min(96, (width * height / CGFloat(max(text.count, 1))).squareRoot() * 1.1))
    background(
      for: line,
      cornerRadius: 12,
      label: Text(text)
        .font(.system(size: fontSize, weight: .semibold))
        .multilineTextAlignment(.leading)
        .lineLimit(nil)
        .minimumScaleFactor(0.3)
        .padding(8)
        .frame(width: width, height: height, alignment: .topLeading)
    )
  }

  @ViewBuilder
  private func background(for line: OverlayLine, cornerRadius: CGFloat, label: some View) -> some View {
    if glass {
      label
        .foregroundStyle(line.translated == nil ? .secondary : .primary)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    } else {
      label
        .foregroundStyle(.white)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
  }
}
