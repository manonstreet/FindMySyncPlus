import SwiftUI

struct UUIDChip: View {
    let uuid: String
    var onDelete: () -> Void
    @State private var hovering = false
    @Environment(\.colorScheme) var scheme

    var body: some View {
        Text(uuid)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .padding(.trailing, 3)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.secondary.opacity(0.28), lineWidth: 0.5)
            )
            .overlay(alignment: .topTrailing) {
                Button(action: onDelete) {
                    ZStack {
                        Circle()
                            .fill(hovering ? Color.white : Color.black)

                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(hovering ? Color.red : Color.white)
                    }
                    .frame(width: 15, height: 15)
                    .overlay(
                        Circle().stroke(
                            Color(nsColor: .separatorColor).opacity(scheme == .dark ? 0.7 : 0.22),
                            lineWidth: 0.5
                        )
                    )
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .contentShape(Rectangle().inset(by: -6))
                .onHover { hovering = $0 }
                .help("Remove UUID")
                .accessibilityLabel("Remove UUID")
            }
    }
}
