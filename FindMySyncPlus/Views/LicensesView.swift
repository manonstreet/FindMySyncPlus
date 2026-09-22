import SwiftUI

/// The licenses whose text the app ships. The files in the bundle are the copies the
/// licenses require to accompany the app; this is how they are read from inside it.
enum ShippedLicense: String, CaseIterable, Identifiable {
    case findMySyncIcon = "FindMySync-GPL-3.0"
    case cocoaMQTT = "CocoaMQTT-EDL-1.0"
    case ink = "Ink-MIT"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .findMySyncIcon: "FindMySync icon"
        case .cocoaMQTT: "CocoaMQTT"
        case .ink: "Ink"
        }
    }

    var licenseName: String {
        switch self {
        case .findMySyncIcon: "GNU General Public License 3.0"
        case .cocoaMQTT: "Eclipse Distribution License 1.0"
        case .ink: "MIT License"
        }
    }

    /// The file's text as written, line breaks included.
    var text: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "\(rawValue).txt is missing from the app bundle."
        }
        return text
    }
}

/// The full text of each license, one after another, opened at the one asked for. Plain
/// text in the reading font with the file's own line breaks, the way acknowledgments read
/// elsewhere on the Mac; a code block made the GPL a wide monospaced box.
struct LicensesView: View {
    var showing: ShippedLicense?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // A raw ScrollView: the sheet is never rendered by the harness, and the reader
        // needs the real container to scroll to a license.
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    Text("Licenses").font(.title).fontWeight(.bold)
                    ForEach(ShippedLicense.allCases) { license in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(license.title).font(.title2).fontWeight(.semibold)
                            Text(license.licenseName).font(.callout).foregroundStyle(.secondary)
                            Text(license.text)
                                .font(.callout)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 6)
                        }
                        .id(license)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onAppear {
                if let showing { proxy.scrollTo(showing, anchor: .top) }
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .frame(minWidth: 500, idealWidth: 600, minHeight: 200, idealHeight: 300)
    }
}
