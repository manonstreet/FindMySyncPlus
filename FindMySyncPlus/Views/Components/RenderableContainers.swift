import SwiftUI

/// The app's container vocabulary.
///
/// `ImageRenderer` cannot draw AppKit-backed containers — `VSplitView` and `List` render as
/// a placeholder, `ScrollView` as nothing. These types use the real container normally and
/// a plain stack while a snapshot is being taken. The substitution loses dividers, scroll
/// position and viewport clipping; it keeps which rows appear, what they say and how they
/// group, which is what a regression run reads.

/// The only place in the app that decides whether a render is in progress.
///
/// Gated on the output directory as well as the in-flight flag: if `isRendering` ever stuck
/// true, every `ScrollView` in a shipped build would become a `VStack`. Requiring
/// `demoRenderExport` too makes that unreachable for anyone who has not opted in.
@MainActor @ViewBuilder
func substituting<Real: View, Fallback: View>(
    _ real: () -> Real,
    whileRendering fallback: () -> Fallback
) -> some View {
    if ViewSnapshotExport.isRendering, ViewSnapshotExport.outputDirectory != nil {
        fallback()
    } else {
        real()
    }
}

/// A vertical split. A plain stack while rendering.
struct AppVSplit<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ VSplitView { content } },
                     whileRendering: { stack })
    }
    /// `.fixedSize` vertically is what makes a render fit its content. Without it the stack
    /// takes whatever height it is offered and splits it equally, so a short list becomes a
    /// tall empty card; unbounded, `SectionCard`'s `GeometryReader` background expands and
    /// paints over the pane below.
    private var stack: some View {
        VStack(spacing: 0) { content }.fixedSize(horizontal: false, vertical: true)
    }
}

/// A scrolling container. A plain stack while rendering.
///
/// Takes no scroll parameters on purpose: a modifier aimed at the container would land on
/// this wrapper with the real `ScrollView` inside a `_ConditionalContent` and might silently
/// stop binding. `StatusView` needs three such modifiers and keeps its raw `ScrollView`.
struct AppScroll<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ ScrollView { content } },
                     whileRendering: { VStack(spacing: 0) { content } })
    }
}

/// A menu picker. While rendering, a label naming the current selection — a menu `Picker`
/// is `NSPopUpButton`-backed and renders as the placeholder, which would hide which filter
/// is applied.
///
/// The picker is sized to its content here rather than at each call site. Left to itself a
/// menu picker takes whatever width its row offers, which on macOS 15 is the whole header;
/// macOS 27 sizes it to the selection, so the difference shows only on the older system.
/// The substitute drawn while rendering is sized already, which is the other half of why no
/// baseline covers this.
struct AppMenuPicker<Content: View>: View {
    let selectionTitle: String
    @ViewBuilder var content: Content
    var body: some View {
        substituting({ content.fixedSize() }, whileRendering: { label })
    }
    private var label: some View {
        Text(selectionTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke(Color.secondary.opacity(0.4), lineWidth: 1))
    }
}
