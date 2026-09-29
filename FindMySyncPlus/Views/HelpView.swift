import SwiftUI

/// A pane's help page, one of the Markdown files in `Docs/`.
enum HelpDoc: String, Identifiable {
    case tracking = "TRACKING"
    case access = "ACCESS"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tracking: "Tracking Help"
        case .access: "Access Help"
        }
    }
}

struct HelpView: View {
    let doc: HelpDoc
    @State private var markdown: String = "Loading…"

    var body: some View {
        MarkdownView(markdown: markdown)
            .frame(minWidth: 640, minHeight: 480)
            .onAppear(perform: load)
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: doc.rawValue, withExtension: "md"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        markdown = s
    }
}

/// A help page as a sheet, the shape of the Licenses sheet: the markdown view, a Done
/// button, presented at the same size.
struct HelpSheet: View {
    let doc: HelpDoc
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HelpView(doc: doc)
            .navigationTitle(doc.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
    }
}
