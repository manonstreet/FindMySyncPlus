import SwiftUI

/// The MQTT connection state, as a quiet last row of the sidebar. The dot follows the
/// Scheduler card's `Status ● Stopped` idiom rather than inventing a second status
/// treatment. Only shown on the MQTT transport — REST has no connection to report.
struct MQTTStatusLight: View {
    let connected: Bool
    let host: String
    let port: Int
    /// Opens Access settings. Seeing "Disconnected" and being able to click
    /// straight to where you would fix it is the point of making this interactive.
    var onTap: () -> Void

    @State private var hovering = false

    private var tint: Color { connected ? .green : .secondary }

    var body: some View {
        Button(action: onTap) {
            // Not a Label in the nav rows' icon column: a 7pt dot in a .title2 symbol's slot
            // is stranded in a gap. This is footer chrome; the dot starts where their icons do.
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(connected ? "MQTT Connected" : "MQTT Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(hovering ? 0.10 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // The host lives here, not on a second line: the sidebar is single-line throughout
        // and Home already shows the endpoint.
        .help(connected
              ? "Connected to \(host):\(port) — open Access settings"
              : "Not connected to \(host):\(port) — open Access settings")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "MQTT connected to \(host)" : "MQTT not connected to \(host)")
        .accessibilityHint("Opens Access settings")
    }
}
