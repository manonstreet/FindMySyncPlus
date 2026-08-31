import SwiftUI

struct SettingsToggleRow: View {
    let label: String
    @Binding var isOn: Bool
    var disabled: Bool = false
    /// Qualifies the label when the row cannot be used — rendered as a grey
    /// parenthetical, the same shape as "Update Interval (minutes)" elsewhere in this
    /// window. Keeps the explanation with the label so the control keeps its own side
    /// of the row and the middle stays clear, as on every other row.
    var qualifier: String?

    var body: some View {
        HStack {
            // Two views rather than concatenated Text: `Text.+` is deprecated from
            // macOS 26, and this renders the same.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(label)
                if let qualifier {
                    Text("(\(qualifier))")
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(disabled)
        }
    }
}
