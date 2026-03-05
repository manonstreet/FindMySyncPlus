import SwiftUI

struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var content: String = ""

    var body: some View {
        MarkdownView(markdown: content)
            .onAppear(perform: loadFile)
            .navigationTitle("Third-Party Notices")
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
    private func loadFile() {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let md = try? String(contentsOf: url, encoding: .utf8)
        else {
            content = "# Error\nCould not load `THIRD-PARTY-NOTICES.md` from the app bundle."
            return
        }
        content = md
    }
}
