import SwiftUI

/// A bubble light for the MQTT connection, pinned to the bottom of the sidebar.
///
/// Until this existed the app never showed whether MQTT was connected anywhere,
/// which meant every message about a deferred or failed action had to carry that
/// news itself — so each one invented its own wording and urgency. With the state
/// visible, those messages only have to state their own outcome.
///
/// Only shown on the MQTT transport: REST has no connection to report.
struct MQTTStatusLight: View {
    let connected: Bool
    let host: String
    let port: Int

    private var tint: Color { connected ? .green : .secondary }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle().stroke(tint.opacity(0.35), lineWidth: connected ? 3 : 0)
                )
            Text("MQTT")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .help(connected
              ? "Connected to \(host):\(port)"
              : "Not connected to \(host):\(port)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(connected ? "MQTT connected" : "MQTT not connected")
    }
}
