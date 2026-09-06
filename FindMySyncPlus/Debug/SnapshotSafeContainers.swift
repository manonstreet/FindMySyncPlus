import SwiftUI

/// Containers that fall back to a plain stack while a snapshot is being rendered.
///
/// `ImageRenderer` cannot draw AppKit-backed containers. Measured directly rather than
/// inferred — mean luminance of a 400x300 render of the same content:
///
/// | container | result |
/// |---|---|
/// | `VStack` | 0.202, draws correctly |
/// | `VSplitView` | 0.572, the yellow-and-red "cannot draw this" placeholder |
/// | `List` | 0.572, the same placeholder |
/// | `ScrollView` | 1.000, pure white — nothing drawn at all |
///
/// So a screen built from these renders as a placeholder or as nothing, and the export
/// would be worthless without this swap.
///
/// **What the substitution costs.** The rendered layout is not pixel-identical to what a
/// user sees: no draggable divider, no scroll position, and the content lays out at full
/// height instead of being clipped to a viewport. What is preserved is everything a
/// regression run is looking at — which rows appear, what they say, how they group, which
/// headers show. A change to parsing, grouping or backfill moves those either way.
///
/// Inert unless a render is in progress, so it costs a shipped build one boolean read.
struct SnapshotSafeVSplit<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if ViewSnapshotExport.isRendering {
            // `.fixedSize` vertically is what makes the render fit its content.
            //
            // Without it the stack absorbs whatever height it is offered and hands each pane
            // an equal share, so a short Unassigned list becomes a tall empty card. With an
            // *unbounded* height instead, `SectionCard`'s `GeometryReader` background — which
            // has no intrinsic height — expands and paints over the pane below, and the
            // Aliases section header silently disappears under it.
            //
            // A definite ideal height avoids both: each pane asks for what it needs, the
            // GeometryReader gets a real proposal, and the image ends where the content does.
            VStack(spacing: 0) { content }
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VSplitView { content }
        }
    }
}

struct SnapshotSafeScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if ViewSnapshotExport.isRendering {
            VStack(spacing: 0) { content }
        } else {
            ScrollView { content }
        }
    }
}

/// A menu `Picker` is `NSPopUpButton`-backed and renders as the same placeholder, so while
/// snapshotting it becomes a label showing the current selection.
///
/// A constant placeholder would be harmless to a comparison -- it never changes, so it never
/// causes a false failure. It is replaced because it hides which filter is applied, and a
/// render that cannot show the view's state is worth less to whoever reads it.
struct SnapshotSafeMenuPicker<Content: View>: View {
    let selectionTitle: String
    @ViewBuilder var content: Content
    var body: some View {
        if ViewSnapshotExport.isRendering {
            Text(selectionTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
        } else {
            content
        }
    }
}
