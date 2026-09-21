import SwiftUI

/// The card: content on a flat fill, inset from the column. Sections of a pane that are
/// not rows sit on one, under a floating label or a header of their own.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(18)
            .background(FlatFill())
            .padding(.horizontal, 18)
    }
}
