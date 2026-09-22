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

    /// The file's text, its paragraphs reflowed for the sheet.
    var text: String {
        guard let url = Bundle.main.url(forResource: rawValue, withExtension: "txt"),
              let raw = try? String(contentsOf: url, encoding: .utf8) else {
            return "\(rawValue).txt is missing from the app bundle."
        }
        return Self.reflow(raw)
    }

    /// Undoes the line wraps inside a paragraph, so a paragraph fills the sheet's width.
    ///
    /// License files are wrapped at seventy-odd columns for a terminal, and shown as
    /// written they stop two thirds of the way across the sheet. The words are the file's;
    /// only the breaks inside a paragraph go. What stays on a line of its own: a blank
    /// line, a line indented eight or more (the GPL's centered headings), a short line
    /// (a title, a copyright line, a URL, a section heading), and whatever follows a line
    /// ending in `>` (the GPL's notice template, whose placeholders are one per line).
    /// A line is taken to have been wrapped when it runs to fifty-five characters or more.
    static func reflow(_ raw: String) -> String {
        var lines: [String] = []
        var previousWasWrapped = false
        for rawLine in raw.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix(while: { $0 == " " }).count
            if trimmed.isEmpty {
                lines.append("")
                previousWasWrapped = false
            } else if indent >= 8 {
                lines.append(trimmed)
                previousWasWrapped = false
            } else if previousWasWrapped, let last = lines.indices.last {
                lines[last] += " " + trimmed
                previousWasWrapped = Self.looksWrapped(trimmed)
            } else {
                lines.append(trimmed)
                previousWasWrapped = Self.looksWrapped(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func looksWrapped(_ line: String) -> Bool {
        line.count >= 55 && !line.hasSuffix(">")
    }
}

/// The full text of each license, one after another, opened at the one asked for. Plain
/// text in the reading font, the way acknowledgments read elsewhere on the Mac; a code
/// block made the GPL a wide monospaced box.
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
