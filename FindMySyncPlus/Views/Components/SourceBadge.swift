import SwiftUI

struct SourceBadge: View {
    let source: AppModel.DeviceSource
    var tint: Color = .accentColor
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let label = (source == .device ? "Device" : "Item")
        let fillOpacity: Double = (scheme == .dark) ? 0.28 : 0.12
        let strokeOpacity: Double = (scheme == .dark) ? 0.55 : 0.35

        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(fillOpacity))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(strokeOpacity), lineWidth: 0.5)
            )
            .foregroundStyle(.primary)
    }
}
