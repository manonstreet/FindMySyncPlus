import SwiftUI

struct InfoTip: View {
    let message: String
    @State private var show = false

    @State private var hovering = false

    var body: some View {
        Button {
            show.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(hovering ? Color.accentColor : Color.accentColor.opacity(0.7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .popover(isPresented: $show, arrowEdge: .top) {
            Text(message)
                .font(.callout)
                .padding(12)
                .frame(maxWidth: 520)
        }
    }
}
