import SwiftUI

struct InfoTip: View {
    let message: String
    var systemImage = "questionmark.circle"
    var color = Color.accentColor
    @State private var show = false

    @State private var hovering = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(hovering ? color : color.opacity(0.7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $show, arrowEdge: .top) {
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: 520)
        }
    }
}
