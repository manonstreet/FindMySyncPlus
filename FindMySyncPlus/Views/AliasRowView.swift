import SwiftUI

/// One row of the Aliases list, and the switch style it uses.
///
/// Every input is a value or a closure — no environment, no access to the list that owns
/// it — so the row can be constructed and rendered in isolation.
struct CompactSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        let on = configuration.isOn
        return ZStack {
            // Track
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(on ? Color.accentColor : Color.secondary.opacity(0.35))
                .frame(width: 34, height: 18)

            // Knob
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                .frame(width: 16, height: 16)
                .frame(width: 34, alignment: on ? .trailing : .leading)
                .padding(.horizontal, 1)
                .animation(.snappy(duration: 0.15), value: on)
        }
        .contentShape(Rectangle())
        .onTapGesture { configuration.isOn.toggle() }
        .accessibilityLabel(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(.isButton)
    }
}

struct AliasRowView: View {
    let aliasKey: String
    let tracked: Bool
    let knownUUIDs: [String]
    let lastSeenName: String?
    let sourceBadge: DeviceSource?
    let nameLabel: String
    let transportMode: TransportMode

    /// Same contract as `UnassignedRow.disclosure`, so a grouped parent behaves
    /// identically in both lists: always-visible pill, tap toggles. nil = no chevron.
    var disclosure: (isCollapsed: Bool, onToggle: () -> Void)?

    var onToggleTracked: (Bool) -> Void
    var onRename: () -> Void
    var onDelete: () -> Void
    var onReRegister: () -> Void
    var onDeleteUUID: (String) -> Void

    @State private var pillHovering = false
    @State private var hoverRename = false
    @State private var hoverTrash  = false
    @State private var hoverReRegister = false
    @State private var showCopiedEntity = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HStack(spacing: 6) {
                    Text(aliasKey)
                        .font(.system(size: 16, weight: .semibold))
                    if let s = sourceBadge {
                        SourceBadge(source: s)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    }
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
                        .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                    }
                }

                HStack(spacing: 5) {
                    Button(action: onRename) {
                        Image(systemName: "square.and.pencil") // boxed pencil
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hoverRename ? Color.accentColor.opacity(0.9) : .secondary)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 0.5 } // nudge up
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverRename = $0 }
                    .help("Rename alias")

                    // MQTT only: REST derives the entity from dev_id directly, so
                    // there is nothing to re-register there.
                    if transportMode == .mqtt {
                        Button(action: onReRegister) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(hoverReRegister ? Color.accentColor.opacity(0.9) : .secondary)
                                .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 }
                        }
                        .buttonStyle(.plain)
                        .onHover { hoverReRegister = $0 }
                        // Deliberately never disabled. The action connects on
                        // demand if the scheduler is stopped, and reports a
                        // failure — a greyed control whose cause is invisible
                        // (connection state is surfaced nowhere) is worse.
                        .help("Re-create the Home Assistant entity so its ID matches this alias")
                    }

                    // Deleting a group's alias used to be blocked while children
                    // nested under it, because it would have orphaned them. It no
                    // longer does: the group falls back to an unaliased header and
                    // the children stay nested under that, which is the exact
                    // reverse of assigning the group and having its row take the
                    // header's place. Blocking a legal action to prevent a state
                    // that no longer occurs is worse than the state was.
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(hoverTrash ? Color.accentColor.opacity(0.9) : .secondary)
                            .alignmentGuide(.firstTextBaseline) { d in d[.bottom] - 1 } // nudge up
                    }
                    .buttonStyle(.plain)
                    .onHover { hoverTrash = $0 }
                    .help("Delete alias")
                }

                Spacer()

                HStack(spacing: 8) {
                    Text(tracked ? "Tracked" : "Not Tracked")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Toggle("", isOn: Binding(get: { tracked }, set: { onToggleTracked($0) }))
                        .toggleStyle(CompactSwitchStyle())
                        .help("Include this alias in posts to Home Assistant")
                }
                .alignmentGuide(.firstTextBaseline) { d in d[.firstTextBaseline] }
            }

            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 6, verticalSpacing: 2) {
                GridRow {
                    Text(nameLabel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text(lastSeenName ?? "—")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                }
                GridRow {
                    Text("Entity ID:")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    // The entity ID Home Assistant actually creates, not the
                    // dev_id. This row used to show `findmy_<alias>` under an
                    // "Entity ID" label, which is the topic key and unique_id —
                    // missing the domain and keeping hyphens HA converts. Issue
                    // #22's reporter reasonably expected what this label said.
                    HStack(spacing: 6) {
                        Text(DeviceAlias.haEntityID(for: aliasKey))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        Button(action: {
                            let pb = NSPasteboard.general
                            pb.clearContents()
                            pb.setString(DeviceAlias.haEntityID(for: aliasKey), forType: .string)
                            withAnimation(.easeInOut(duration: 0.15)) { showCopiedEntity = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                withAnimation(.easeInOut(duration: 0.2)) { showCopiedEntity = false }
                            }
                        }) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Copy entity ID")

                        Text("Copied")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .opacity(showCopiedEntity ? 1 : 0)
                    }
                    Spacer()
                }
                if transportMode == .rest {
                    GridRow {
                        Text("MAC:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(macFromAlias(aliasKey))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }
            }

            HStack(alignment: .center, spacing: 6) {
                Text("Known UUIDs:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if knownUUIDs.isEmpty {
                    Text("None")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                } else {
                    HStack(spacing: 6) {
                        ForEach(knownUUIDs, id: \.self) { u in
                            UUIDChip(uuid: u) { onDeleteUUID(u) }
                        }
                    }
                    .padding(.leading, 2) // tiny nudge so pills don’t collide with label
                    Spacer(minLength: 8)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 4)
        }
        .padding(.vertical, 4)
    }
}
