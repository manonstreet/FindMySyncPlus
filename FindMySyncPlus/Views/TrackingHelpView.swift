import SwiftUI

struct TrackingHelpView: View {
    @State private var markdown: String = "# Tracking\n\nLoading…"

    var body: some View {
        MarkdownView(markdown: markdown)
            .frame(minWidth: 640, minHeight: 480)
            .onAppear(perform: load)
    }

    private func load() {
        guard let url = Bundle.main.url(forResource: "TRACKING", withExtension: "md"),
              let data = try? Data(contentsOf: url),
              let s = String(data: data, encoding: .utf8),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        markdown = s
    }
}
