import SwiftUI

// Reusable card container: material in dark mode, solid in light mode
struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let useMaterial = (scheme == .dark)
        let border = Color(nsColor: .separatorColor).opacity(useMaterial ? 0.50 : 0.18)
        let highlight = Color.white.opacity(useMaterial ? 0.0 : 0.06) // subtle inner lift only in light mode
        let shadowColor = Color.black.opacity(useMaterial ? 0.18 : 0.08)
        let shadowRadius: CGFloat = useMaterial ? 1 : 4
        let shadowY: CGFloat = useMaterial ? 0.5 : 2

        content
            .padding(18)
            .background {
                if useMaterial {
                    shape.fill(.ultraThinMaterial)
                } else {
                    shape.fill(Color(nsColor: .controlBackgroundColor))
                }
            }
            .overlay(
                shape.stroke(border, lineWidth: 1)
            )
            .overlay(
                shape.stroke(highlight, lineWidth: 0.5)
            )
            .shadow(color: shadowColor, radius: shadowRadius, y: shadowY)
            .padding(.horizontal, 18)
    }
}
