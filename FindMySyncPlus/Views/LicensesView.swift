import SwiftUI

/// The full text of each license the app ships, as one document over the license files
/// in the bundle. The files are the copies the licenses require to accompany the app; this
/// is the way to read them from inside it.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""

    /// In the order the Acknowledgments card lists them.
    private static let licenses: [(title: String, resource: String)] = [
        ("FindMySync icon: GNU General Public License 3.0", "FindMySync-GPL-3.0"),
        ("CocoaMQTT: Eclipse Distribution License 1.0", "CocoaMQTT-EDL-1.0"),
        ("Ink: MIT License", "Ink-MIT")
    ]

    var body: some View {
        MarkdownView(markdown: content)
            .onAppear(perform: load)
            .navigationTitle("Licenses")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .frame(minWidth: 500, idealWidth: 600, minHeight: 200, idealHeight: 300)
    }

    @MainActor
    private func load() {
        var markdown = "# Licenses\n\nThe full text of each license the app ships with.\n\n"
        for entry in Self.licenses {
            markdown += "## \(entry.title)\n\n"
            if let url = Bundle.main.url(forResource: entry.resource, withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                // Fenced, so the text reads as written: the GPL's own layout has indented
                // lines that markdown would otherwise take for code or fold into paragraphs.
                markdown += "```\n\(text)\n```\n\n"
            } else {
                markdown += "`\(entry.resource).txt` is missing from the app bundle.\n\n"
            }
        }
        content = markdown
    }
}
