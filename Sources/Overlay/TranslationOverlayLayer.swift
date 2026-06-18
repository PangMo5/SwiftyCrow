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
          // The chip hugs the vertical text (so the glass matches it) and is
          // pinned to the box's top-right, where vertical CJK starts reading.
          // A column's width is the source character size, so render near that
          // scale to keep the page's font hierarchy.
          blockChip(for: line, width: width, height: height, sourceFont: line.verticalCharScale * size.width)
            .frame(width: width, height: height, alignment: .topTrailing)
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

  /// A stitched block of vertical CJK columns: lay the translation out the same
  /// way the source reads — characters top-to-bottom, columns right-to-left —
  /// so it sits over the original like an in-place replacement. Sized so the
  /// text roughly fills the box.
  @ViewBuilder
  private func blockChip(for line: OverlayLine, width: CGFloat, height: CGFloat, sourceFont: CGFloat) -> some View {
    let text = line.translated ?? line.sourceText
    // Largest font that still fits the box, then prefer the source font scale so
    // the hierarchy is kept — capped to the fit so a long translation can't spill.
    let fit = (width * height / CGFloat(max(text.count, 1))).squareRoot() * 0.9
    let fontSize = max(8, min(fit, sourceFont > 0 ? sourceFont : fit))
    background(
      for: line,
      cornerRadius: 12,
      // The chip sizes to the text (columns wrap at the box height), so the
      // glass background matches the translation instead of the full box.
      label: VerticalText(text: text, fontSize: fontSize, availableHeight: max(1, height - 12))
        .padding(6)
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

// MARK: - Vertical text

/// Lays out a string as vertical CJK writing: each character upright, stacked
/// top-to-bottom, columns advancing right-to-left.
private struct VerticalText: View {
  let text: String
  let fontSize: CGFloat
  /// Height to wrap columns at — the chip then sizes itself to the content.
  let availableHeight: CGFloat

  var body: some View {
    VerticalColumns(charExtent: fontSize * 1.18, availableHeight: availableHeight) {
      ForEach(Array(text.enumerated()), id: \.offset) { _, character in
        Text(String(character))
          .font(.system(size: fontSize, weight: .semibold))
      }
    }
  }
}

/// Places each subview (one character) top-to-bottom; when a column fills
/// `availableHeight` it wraps to a new column on the left. Reports the size it
/// actually uses so the surrounding chip hugs the text.
private struct VerticalColumns: Layout {
  var charExtent: CGFloat
  var availableHeight: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard !subviews.isEmpty else { return .zero }
    let columnWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? charExtent
    let perColumn = max(1, Int(availableHeight / charExtent))
    let columns = Int(ceil(Double(subviews.count) / Double(perColumn)))
    let rows = min(subviews.count, perColumn)
    return CGSize(width: CGFloat(columns) * columnWidth, height: CGFloat(rows) * charExtent)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard !subviews.isEmpty else { return }
    let columnWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? charExtent
    let perColumn = max(1, Int(availableHeight / charExtent))
    var x = bounds.maxX - columnWidth
    var y = bounds.minY
    var placed = 0
    for subview in subviews {
      subview.place(
        at: CGPoint(x: x, y: y),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: columnWidth, height: charExtent)
      )
      placed += 1
      y += charExtent
      if placed >= perColumn {
        placed = 0
        y = bounds.minY
        x -= columnWidth
      }
    }
  }
}
