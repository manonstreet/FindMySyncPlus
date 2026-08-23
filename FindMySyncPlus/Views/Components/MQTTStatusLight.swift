import SwiftUI

/// The MQTT connection state, as a quiet last row of the sidebar.
///
/// Until this existed the app never showed whether MQTT was connected anywhere,
/// so every message about a deferred or failed action had to carry that news
/// itself — which is why each one had invented its own wording. With the state
/// visible, those messages only state their own outcome.
///
/// Built on `Label` with the same icon-column width as `SidebarRow`, so its text
/// lands in the sidebar's label column rather than its icon column. An earlier
/// version used its own layout and semibold caption text: every element looked
/// fine alone, but it shared a left edge and a type style with nothing around it.
///
/// The dot follows the Scheduler card's existing `Status ● Stopped` idiom rather
/// than inventing a second status treatment. Regular weight, secondary — the dot
/// carries the state, the text names what it is about.
///
/// Only shown on the MQTT transport: REST has no connection to report.
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
            Label {
                // Caption, not the nav rows' body size. Matching their *column* is
                // what makes this belong; matching their type scale does not, because
                // every nav label is under eight characters and "MQTT Disconnected"
                // is seventeen — at body size it ellipsizes at the sidebar minimum.
                Text(connected ? "MQTT Connected" : "MQTT Disconnected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
                    .lineLimit(1)
            } icon: {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                    // Occupies the same width a `.title2` symbol does in
                    // `SidebarRow`, so the text starts in the same column.
                    .frame(width: 22, alignment: .center)
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
        // The host lives here rather than on a second line: the sidebar is
        // otherwise single-line throughout, and Home already shows the endpoint
        // under Configuration Summary.
        .help(connected
              ? "Connected to \(host):\(port) — open Access settings"
              : "Not connected to \(host):\(port) — open Access settings")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "MQTT connected to \(host)" : "MQTT not connected to \(host)")
        .accessibilityHint("Opens Access settings")
    }
}
