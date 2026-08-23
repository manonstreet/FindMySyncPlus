import SwiftUI

/// A bubble light for the MQTT connection, pinned below the sidebar.
///
/// Until this existed the app never showed whether MQTT was connected anywhere,
/// which meant every message about a deferred or failed action had to carry that
/// news itself — so each one invented its own wording and urgency. With the state
/// visible, those messages only have to state their own outcome.
///
/// The state is spelled out rather than left to the dot's colour: grey reads as
/// "disabled" as easily as "disconnected", and colour alone is no signal at all to
/// a colour-blind user.
///
/// Only shown on the MQTT transport — REST has no connection to report.
struct MQTTStatusLight: View {
    let connected: Bool
    let host: String
    let port: Int
    /// Jumps to Access settings. Seeing "Disconnected" and being able to click
    /// straight to where you would fix it is the point of making this interactive.
    var onTap: () -> Void

    @State private var hovering = false

    private var tint: Color { connected ? .green : .secondary }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .overlay(
                            Circle().stroke(tint.opacity(0.35), lineWidth: connected ? 3 : 0)
                        )
                    // Semibold + primary, deliberately not the secondary uppercase of
                    // the sidebar's section headers — this is live state, not a label,
                    // and must not read as a third section.
                    Text(connected ? "MQTT Connected" : "MQTT Disconnected")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
                Text(host.isEmpty ? "No broker configured" : host)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    // Middle, not tail: `some-long-host.lan` stays identifiable as
                    // `some-lo…ost.lan`, where tail truncation loses the part that
                    // distinguishes one host from another.
                    .truncationMode(.middle)
                    // Aligned under the label rather than the dot, so it reads as a
                    // subtitle instead of a second item.
                    .padding(.leading, 13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(hovering ? 0.10 : 0.0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(connected
              ? "Connected to \(host):\(port) — open Access settings"
              : "Not connected to \(host):\(port) — open Access settings")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "MQTT connected to \(host)" : "MQTT not connected to \(host)")
        .accessibilityHint("Opens Access settings")
    }
}
