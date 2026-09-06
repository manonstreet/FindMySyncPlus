import SwiftUI
import AppKit

/// The row and container views the Device Manager lists are built from.
///
/// Split out of `DeviceManagerView.swift` so that file stays under SwiftLint's limits, and
/// so each of these can be rendered on its own — they take values and closures, never the
/// list's state.
struct SectionCard<Content: View>: View {
    let gutter: CGFloat          // area on the trailing edge reserved for the overlay scroller (outside the card)
    let innerTrailing: CGFloat   // space between content and the card’s right border
    @ViewBuilder var content: Content

    init(gutter: CGFloat = 14,
         innerTrailing: CGFloat = 10,
         @ViewBuilder content: () -> Content) {
        self.gutter = gutter
        self.innerTrailing = innerTrailing
        self.content = content()
    }

    var body: some View {
        let bg: Color = Color(nsColor: .controlBackgroundColor)

        ZStack(alignment: .leading) {
            GeometryReader { geo in
                let cardWidth = max(0, geo.size.width - gutter)
                Rectangle()
                    .fill(bg)
                    .frame(width: cardWidth, alignment: .leading)
                    .overlay(
                        Rectangle()
                            .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
                            .frame(width: cardWidth, alignment: .leading)
                    )
                    .allowsHitTesting(false)
            }
            content
                .padding(.trailing, innerTrailing)
        }
    }
}

struct AssignedBadge: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let color = Color.gray
        let fillOpacity: Double = (scheme == .dark) ? 0.28 : 0.12
        let strokeOpacity: Double = (scheme == .dark) ? 0.55 : 0.35
        Text("Assigned")
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

struct UnassignedRow: View {
    let name: String
    let id: String
    let source: DeviceSource
    var onAssign: () -> Void
    var showsDivider: Bool = true
    let isUpdate: Bool
    /// When set, renders a small disclosure pill on the right. Always visible
    /// so the expand affordance is discoverable without requiring hover.
    /// Tap toggles `isCollapsed` via `onToggle`. nil = no chevron.
    var disclosure: (isCollapsed: Bool, onToggle: () -> Void)? = nil
    /// True for grouped parents that already own an alias. The Assign button
    /// is disabled and an "Assigned" pill is shown next to the source badge.
    var isAssigned: Bool = false
    @State private var hovering = false
    @State private var pillHovering = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? "(Unnamed device)" : name)
                        .fontWeight(.semibold)
                    SourceBadge(source: source)
                    if isAssigned {
                        AssignedBadge()
                    }
                    // Small disclosure pill, sized to sit inline with the
                    // badges (similar visual weight). Only on parent rows.
                    if let disc = disclosure {
                        Button(action: disc.onToggle) {
                            Image(systemName: disc.isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .frame(width: 10, height: 10)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule(style: .continuous)
                                        .fill(Color.secondary.opacity(pillHovering ? 0.18 : 0.10))
                                )
                        }
                        .buttonStyle(.plain)
                        .onHover { pillHovering = $0 }
                        .help(disc.isCollapsed ? "Expand grouped sub-items" : "Collapse grouped sub-items")
                    }
                }
                Text(id)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onAssign) {
                Text(isUpdate ? "Update" : "Assign")
            }
            .disabled(isAssigned)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Rectangle()
                .fill(Color.secondary.opacity(hovering ? 0.05 : 0.0))
                .padding(.leading, -12)
                .padding(.trailing, -14)
        )
        .overlay(alignment: .bottom) {
            if showsDivider {
                Divider()
                    .padding(.leading, 12)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A group that is not itself aliased, shown so its aliased children can nest.
///
/// Carries a parent's visual weight - bold name and badges, as a real row has - so the
/// hierarchy reads correctly, and nothing else. No entity ID, no UUID chips, no Tracked
/// toggle, no rename or delete: those are visibly absent *because* this is not an alias,
/// which answers the objection that once parked this idea rather than arguing with it.
///
/// Deliberately no Assign button either. Assigning belongs to the Unassigned pane, and
/// duplicating it here would blur what each pane is for. Once the group is assigned, a
/// real alias row replaces this in place.
struct AliasGroupHeader: View {
    let name: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 6) {
            // Full weight, like the alias rows around it. Greyed, it read as a
            // disabled row rather than a heading — the badge is what says this is not
            // an alias, and it says it without making the name look switched off.
            Text(name)
                .font(.system(size: 16, weight: .semibold))
            SourceBadge(source: .group)
                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
            Text("Not aliased")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Capsule(style: .continuous).fill(Color.gray.opacity(scheme == .dark ? 0.28 : 0.12)))
                .overlay(Capsule(style: .continuous).stroke(Color.gray.opacity(scheme == .dark ? 0.55 : 0.35), lineWidth: 0.5))
                .foregroundStyle(.secondary)
        }
    }
}

struct AliasRowContainer<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var hovering = false
    var body: some View {
        content
            .padding(.leading, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Rectangle()
                    .fill(Color.secondary.opacity(hovering ? 0.05 : 0.0))
                    .padding(.leading, -12) // extend to left edge
                    .padding(.trailing, -14) // extend under overlay scroller
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// Wraps a parent row + its children (indented) in a vertical stack. The
/// chevron itself is rendered inline by UnassignedRow via the `disclosure`
/// param so we don't shift row content for a leading disclosure column.
struct ParentDisclosureRow<Header: View, Children: View>: View {
    let hasChildren: Bool
    let isCollapsed: Bool
    @ViewBuilder let header: () -> Header
    @ViewBuilder let children: () -> Children

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header()
            if hasChildren && !isCollapsed {
                children()
                    .padding(.leading, 12)
            }
        }
    }
}
