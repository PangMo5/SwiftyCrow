// SPDX-FileCopyrightText: 2021-2026 PangMo5 and contributors
// SPDX-License-Identifier: AGPL-3.0-only

import SwiftUI

struct BundledDocumentView: View {

  // MARK: Lifecycle

  init(document: BundledDocument) {
    self.document = document
  }

  // MARK: Internal

  var body: some View {
    NavigationStack {
      Group {
        if let loaded, loaded.request == request {
          documentContents(loaded.content)
        } else if let error, error.request == request {
          ContentUnavailableView(
            "Unable to Open Document",
            systemImage: "doc.badge.exclamationmark",
            description: Text(error.message)
          )
        } else {
          ProgressView("Loading document…")
        }
      }
      .navigationTitle(Text(current.document.title))
      .toolbar {
        if !history.isEmpty {
          ToolbarItem(placement: .cancellationAction) {
            Button { history.removeLast() } label: { Label("Back", systemImage: "chevron.backward") }
              .keyboardShortcut("[", modifiers: .command)
          }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
      }
    }
    .frame(minWidth: 680, idealWidth: 760, minHeight: 520, idealHeight: 640)
    .task(id: request) {
      let requested = request
      error = nil
      do {
        let result = try await BundledDocumentLoader.shared.load(requested.destination.document, language: requested.language)
        guard !Task.isCancelled else { return }
        loaded = Loaded(request: requested, content: result)
      } catch {
        guard !Task.isCancelled else { return }
        self.error = Failure(request: requested, message: error.localizedDescription)
      }
    }
  }

  // MARK: Private

  private struct Destination: Hashable {
    var document: BundledDocument
    var fragment: String?
  }

  private struct Request: Hashable { var destination: Destination
    var language: String
  }

  private struct Loaded { var request: Request
    var content: ParsedBundledDocument
  }

  private struct Failure { var request: Request
    var message: String
  }

  @Environment(\.dismiss) private var dismiss
  @State private var history = [Destination]()
  @State private var loaded: Loaded?
  @State private var error: Failure?

  private let document: BundledDocument

  private var current: Destination {
    history.last ?? Destination(document: document)
  }

  /// Bundle preferences reflect the app-language override rather than the Mac's
  /// independent region/number-format locale. Changing app language restarts it.
  private var language: String {
    BundledDocument.language(preferences: Bundle.main.preferredLocalizations)
  }

  private var request: Request {
    Request(destination: current, language: language)
  }

  private func documentContents(_ content: ParsedBundledDocument) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          ForEach(content.blocks) { block in
            blockView(block).id(block.id)
          }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .textSelection(.enabled)
      .environment(\.openURL, OpenURLAction { url in
        guard
          url.scheme == "swiftycrow-document", let host = url.host,
          let target = BundledDocument(rawValue: host)
        else { return .systemAction(url) }
        if target == current.document {
          let id = url.fragment.flatMap { content.anchors[$0] } ?? (url.fragment == nil ? content.blocks.first?.id : nil)
          if let id { proxy.scrollTo(id, anchor: .top)
            return .handled
          }
          var components = URLComponents(url: target.sourceURL, resolvingAgainstBaseURL: false)!
          components.fragment = url.fragment
          return .systemAction(components.url!)
        }
        history.append(Destination(document: target, fragment: url.fragment))
        return .handled
      })
      .onAppear {
        if let fragment = current.fragment, let id = content.anchors[fragment] { proxy.scrollTo(id, anchor: .top) }
      }
    }
    .id(current)
  }

  @ViewBuilder
  private func blockView(_ block: BundledDocumentBlock) -> some View {
    switch block.kind {
    case .heading(let level):
      Text(block.text)
        .font(level == 1 ? .title.weight(.semibold) : level == 2 ? .title2.weight(.semibold) : .headline)
        .accessibilityAddTraits(.isHeader)
        .padding(.top, level == 1 ? 0 : 8)

    case .rule:
      Divider()

    case .code:
      // Soft wrapping affects layout only; license content remains selectable.
      codeText(block)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

    case .table:
      ScrollView(.horizontal) {
        Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
          ForEach(block.rows) { row in
            GridRow {
              ForEach(row.cells) { cell in
                Text(cell.text)
                  .fontWeight(row.isHeader ? .semibold : .regular)
                  .frame(maxWidth: 420, alignment: .leading)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
        }
        .padding(12)
      }
      .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))

    case .text:
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        if block.isQuote { Rectangle().fill(.tertiary).frame(width: 3) }
        if let marker = block.marker { Text(verbatim: marker).foregroundStyle(.secondary) }
        Text(block.text).fixedSize(horizontal: false, vertical: true)
      }
      .padding(.leading, CGFloat(block.indentation) * 18)
    }
  }

  private func codeText(_ block: BundledDocumentBlock) -> some View {
    Text(verbatim: String(block.text.characters)).font(.system(.body, design: .monospaced))
  }

}
