import SwiftUI

struct SourceBadge: View {
    let source: AppModel.DeviceSource
    var tint: Color? = nil
    @Environment(\.colorScheme) private var scheme

    private var resolvedTint: Color {
        if let tint { return tint }
        switch source {
        case .friend: return .purple
        default: return .accentColor
        }
    }

    var body: some View {
        let label: String = switch source {
        case .device: "Device"
        case .item: "Item"
        case .friend: "Friend"
        }
        let color = resolvedTint
        let fillOpacity: Double = (scheme == .dark) ? 0.28 : 0.12
        let strokeOpacity: Double = (scheme == .dark) ? 0.55 : 0.35

        Text(label)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                Capsule(style: .continuous)
                    .fill(color.opacity(fillOpacity))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(color.opacity(strokeOpacity), lineWidth: 0.5)
            )
            .foregroundStyle(.primary)
    }
}
