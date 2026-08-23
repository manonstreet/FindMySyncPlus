import SwiftUI
import AppKit

private struct SectionCard<Content: View>: View {
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

private struct AssignedBadge: View {
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

private struct UnassignedRow: View {
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

private struct AliasRowContainer<Content: View>: View {
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
private struct ParentDisclosureRow<Header: View, Children: View>: View {
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

struct DeviceManagerView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var app: AppModel
    @EnvironmentObject private var logger: LogStore

    @State private var assignUUID: String? = nil
    @State private var assignName: String = ""
    @State private var assignAlias: String = ""
    @State private var showAssignSheet = false

    @State private var pendingUUIDDelete: (aliasKey: String, uuid: String)? = nil

    @State private var renameAliasKey: String? = nil
    @State private var renameText: String = ""
    @State private var showRenameSheet = false

    @State private var reRegisterAliasKey: String? = nil
    @State private var showReRegisterConfirm = false

    @State private var deleteAliasKey: String? = nil
    @State private var showDeleteConfirm = false

    // Ephemeral expand state for parent group rows in the unassigned list.
    // Empty set means every parent is collapsed (the default), so the user
    // sees just parent rows and clicks the chevron to reveal sub-items.
    @State private var expandedParents: Set<String> = []

    // Unified source filter for both Unassigned and Aliases sections
    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all, devices, items, friends
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .devices: return "Devices"
            case .items: return "Items"
            case .friends: return "Friends"
            }
        }
    }
    @State private var unassignedFilter: SourceFilter = .all
    @State private var aliasesFilter: SourceFilter = .all

    private var knownUUIDsSet: Set<String> {
        Set(settings.aliases.flatMap { $0.knownUUIDs })
    }

    private var entriesAll: [LocatedEntry] {
        app.lastLocatedEntries
    }

    /// Set of normalized UUIDs that are referenced as a parent by some
    /// detected *unaliased* child entry. Used so aliased grouped parents
    /// stay visible in the Unassigned list (with their children nested)
    /// only when there's still a child left to alias. Once every child is
    /// also aliased, the parent disappears from the Unassigned list because
    /// nothing is left to manage there.
    private var groupedParentIDs: Set<String> {
        Set(entriesAll
            .filter { !knownUUIDsSet.contains($0.point.id.normalized()) }
            .compactMap { $0.point.parentID?.normalized() })
    }

    private var baseUnassigned: [LocatedEntry] {
        entriesAll.filter { entry in
            let normalized = entry.point.id.normalized()
            // Always include unaliased entries.
            guard knownUUIDsSet.contains(normalized) else { return true }
            // Aliased entries are normally hidden, except keep aliased grouped
            // parents visible so their children can stay nested under them.
            return groupedParentIDs.contains(normalized)
        }
    }

    private var filteredUnassigned: [LocatedEntry] {
        switch unassignedFilter {
        case .all:     return baseUnassigned
        case .devices: return baseUnassigned.filter { $0.source == .device }
        case .items:   return baseUnassigned.filter { $0.source == .item }
        case .friends: return baseUnassigned.filter { $0.source == .friend }
        }
    }

    private var rowsSorted: [DeviceAlias] {
        settings.aliases.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    private var sourceMap: [String: DeviceSource] {
        app.sourceByUUIDMap(from: app.lastLocatedEntries)
    }

    private var hasDeviceAliases: Bool {
        rowsSorted.contains { singleSource(forKnownUUIDs: $0.knownUUIDs, using: sourceMap) == .device }
    }

    private var hasItemAliases: Bool {
        rowsSorted.contains { singleSource(forKnownUUIDs: $0.knownUUIDs, using: sourceMap) == .item }
    }

    private var hasFriendAliases: Bool {
        rowsSorted.contains { singleSource(forKnownUUIDs: $0.knownUUIDs, using: sourceMap) == .friend }
    }

    private var filteredAliases: [DeviceAlias] {
        rowsSorted.filter { rec in
            let single = singleSource(forKnownUUIDs: rec.knownUUIDs, using: sourceMap)
            switch aliasesFilter {
            case .all:     return true
            case .devices: return single == .device
            case .items:   return single == .item
            case .friends: return single == .friend
            }
        }
    }

    private func emptyState(_ image: String, _ message: String) -> some View {
        EmptyStateView(systemImage: image, message: message)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
    }

    // Unified empty-state resolver
    private enum EmptyStateMode {
        case aliases(hasDeviceAliases: Bool, hasItemAliases: Bool, hasFriendAliases: Bool)
        case unassigned(entriesAllEmpty: Bool,
                        hasAnyDevices: Bool,
                        hasAnyItems: Bool,
                        hasAnyFriends: Bool,
                        hasUnassignedDevices: Bool,
                        hasUnassignedItems: Bool,
                        hasUnassignedFriends: Bool)
    }

    private func emptyStateInfo(mode: EmptyStateMode,
                                filter: SourceFilter,
                                devicesEnabled: Bool,
                                itemsEnabled: Bool,
                                friendsEnabled: Bool) -> (String, String)? {
        switch mode {
        case let .aliases(hasDeviceAliases, hasItemAliases, hasFriendAliases):
            switch filter {
            case .all:
                return ("rectangle.stack.person.crop", "No aliases to display.")
            case .devices:
                if devicesEnabled == false { return ("iphone.slash", "Device aliases are hidden because Devices are disabled in Settings.") }
                if hasDeviceAliases == false { return ("iphone", "No device aliases yet.") }
                return ("iphone", "No device aliases match the current filter.")
            case .items:
                if itemsEnabled == false { return ("tag.slash", "Item aliases are hidden because Items are disabled in Settings.") }
                if hasItemAliases == false { return ("tag", "No item aliases yet.") }
                return ("tag", "No item aliases match the current filter.")
            case .friends:
                if friendsEnabled == false { return ("person.2.slash", "Friend aliases are hidden because Friends are disabled in Settings.") }
                if hasFriendAliases == false { return ("person.2", "No friend aliases yet.") }
                return ("person.2", "No friend aliases match the current filter.")
            }

        case let .unassigned(entriesAllEmpty, hasAnyDevices, hasAnyItems, hasAnyFriends, hasUnassignedDevices, hasUnassignedItems, hasUnassignedFriends):
            switch filter {
            case .all:
                if entriesAllEmpty { return ("tray", "No entities available yet. Run once to discover entities.") }
                return ("tray", "No unassigned entities discovered.")
            case .devices:
                if devicesEnabled == false { return ("iphone.slash", "Device entries are hidden because Devices are disabled in Settings.") }
                if hasAnyDevices == false { return ("iphone", "No devices discovered.") }
                if hasUnassignedDevices == false { return ("iphone", "All devices are assigned.") }
                return ("iphone", "No unassigned devices.")
            case .items:
                if itemsEnabled == false { return ("tag.slash", "Item entries are hidden because Items are disabled in Settings.") }
                if hasAnyItems == false { return ("tag", "No items discovered.") }
                if hasUnassignedItems == false { return ("tag", "All items are assigned.") }
                return ("tag", "No unassigned items.")
            case .friends:
                if friendsEnabled == false { return ("person.2.slash", "Friend entries are hidden because Friends are disabled in Settings.") }
                if hasAnyFriends == false { return ("person.2", "No friends discovered.") }
                if hasUnassignedFriends == false { return ("person.2", "All friends are assigned.") }
                return ("person.2", "No unassigned friends.")
            }
        }
    }

    // Determine a single source for an alias record, if all mapped UUIDs agree
    private func singleSource(forKnownUUIDs uuids: [String], using map: [String: DeviceSource]) -> DeviceSource? {
        let sources = Set(uuids.compactMap { map[$0] })
        return sources.count == 1 ? sources.first : nil
    }

    var body: some View {
        ZStack {
            VSplitView {
                // --- Unassigned ---
                VStack(spacing: 0) {
                    sectionHeader(
                        title: "Unassigned",
                        tip: "Link a device’s UUID to an alias. The alias becomes a stable Home Assistant entity that persists even when Apple rotates UUIDs.",
                        trailing: {
                            Picker("", selection: $unassignedFilter) {
                                ForEach(SourceFilter.allCases) { f in
                                    Text(f.title).tag(f)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .labelsHidden()
                            .help("Filter unassigned entries by source")
                        }
                    )
                    SectionCard(gutter: 14, innerTrailing: 14) {
                        unassignedList
                    }
                    .padding(.top, 8)
                    .padding(.leading, 14)
                    .padding(.bottom, 14)
                    .frame(minHeight: 160)
                }

                // --- Aliases ---
                VStack(spacing: 0) {
                    sectionHeader(
                        title: "Aliases",
                        tip: "Manage your tracked aliases. Apple rotates UUIDs periodically — add new ones here and the HA entity stays the same. Renaming an alias changes its HA entity ID.",
                        trailing: {
                            Picker("", selection: $aliasesFilter) {
                                ForEach(SourceFilter.allCases) { f in
                                    Text(f.title).tag(f)
                                }
                            }
                            .pickerStyle(.menu)
                            .controlSize(.small)
                            .labelsHidden()
                            .help("Filter aliases by source")
                        }
                    )
                    SectionCard(gutter: 14, innerTrailing: 14) {
                        aliasesList
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 6)
                    .padding(.leading, 14)
                    .frame(minHeight: 160)
                }
            }
        }
        .padding(.bottom, 10)
        .frame(minWidth: 480, minHeight: 400)
        .sheet(isPresented: $showAssignSheet) {
            AssignAliasSheet(assignUUID: $assignUUID,
                             assignName: $assignName,
                             assignAlias: $assignAlias,
                             onConfirm: { uuid, name, alias in
                let key = settings.createAlias(from: alias, tracked: true, initialUUID: uuid, lastSeenName: name)
                logger.info("Alias \"\(key)\" now includes UUID \(uuid.normalized())")
            })
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameAliasSheet(aliasKey: $renameAliasKey,
                             renameText: $renameText,
                             onConfirm: { key, newName in
                let cleaned = slugifyAlias(newName)
                settings.renameAlias(from: key, to: cleaned)
                logger.info("Alias \"\(key)\" renamed to \"\(cleaned)\" (entity id will change).")
            })
        }
        .alert("Delete Alias?",
               isPresented: $showDeleteConfirm,
               presenting: deleteAliasKey) { key in
            Button("Delete", role: .destructive) {
                settings.deleteAlias(key)
                if settings.transportMode == .mqtt {
                    logger.warn("Alias \"\(key)\" deleted. Its retained MQTT topics clear on the next sync.")
                } else {
                    logger.warn("Alias \"\(key)\" deleted. Clean up the HA entity if desired.")
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { key in
            // Was "This does not remove any Home Assistant entity" — true until the
            // app started clearing retained topics for retired dev_ids. On MQTT it
            // now does exactly that, and telling users the opposite is worse than
            // saying nothing.
            if settings.transportMode == .mqtt {
                // swiftlint:disable:next line_length
                Text("The alias “\(key)” and its UUID mappings will be removed from this app. Its Home Assistant entity and last known location are cleared from the broker on the next sync.")
            } else {
                // swiftlint:disable:next line_length
                Text("This does not remove any Home Assistant entity. The alias “\(key)” and its UUID mappings will be removed from this app.")
            }
        }
        .alert("Re-create Home Assistant entity?",
               isPresented: $showReRegisterConfirm,
               presenting: reRegisterAliasKey) { key in
            Button("Re-create", role: .destructive) {
                Task { _ = await app.reRegisterEntity(alias: key) }
            }
            Button("Cancel", role: .cancel) { }
        } message: { key in
            // Names the specific before and after, which is the whole reason this is
            // per-alias rather than one global button: a sweep could not say either.
            // swiftlint:disable:next line_length
            Text("The entity will be removed and re-created as “\(DeviceAlias.haEntityID(for: key))”. Any rename, icon or area you set for it in Home Assistant will be cleared, and recorded history stays under the old entity ID.")
        }
        .alert("Remove last UUID?", isPresented: Binding(
            get: { pendingUUIDDelete != nil },
            set: { if !$0 { pendingUUIDDelete = nil } }
        )) {
            Button("Remove", role: .destructive) {
                guard let item = pendingUUIDDelete else { return }
                settings.updateAlias(item.aliasKey, removeUUID: item.uuid)
                logger.info(#"Alias "\#(item.aliasKey)" no longer includes UUID \#(item.uuid)"#)

                if let updated = settings.aliases.first(where: { $0.alias == item.aliasKey }),
                   updated.tracked, updated.knownUUIDs.isEmpty {
                    logger.warn(#"Alias "\#(item.aliasKey)" is tracked but has no known UUIDs; it won't post until a UUID is added."#)
                }
                pendingUUIDDelete = nil
            }
            Button("Cancel", role: .cancel) {
                pendingUUIDDelete = nil
            }
        } message: {
            if let item = pendingUUIDDelete {
                Text("This is the last UUID for the tracked alias “\(item.aliasKey)”. The alias will have no identifiers and won’t post until a new UUID is added.")
            } else {
                Text("") // shouldn’t hit, keeps compiler happy
            }
        }
    }

    @ViewBuilder
    private func sectionHeader<Trailing: View>(title: String, tip: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.title3).fontWeight(.semibold)
                InfoTip(message: tip)
                Spacer()
                trailing()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    @ViewBuilder
    var unassignedList: some View {
        // Source presence (overall)
        let hasAnyDevices = entriesAll.contains { $0.source == .device }
        let hasAnyItems   = entriesAll.contains { $0.source == .item }
        let hasAnyFriends = entriesAll.contains { $0.source == .friend }

        // Unassigned presence per type (overall)
        let hasUnassignedDevices = baseUnassigned.contains { $0.source == .device }
        let hasUnassignedItems   = baseUnassigned.contains { $0.source == .item }
        let hasUnassignedFriends = baseUnassigned.contains { $0.source == .friend }

        if filteredUnassigned.isEmpty {
            if let (img, msg) = emptyStateInfo(
                mode: .unassigned(
                    entriesAllEmpty: entriesAll.isEmpty,
                    hasAnyDevices: hasAnyDevices,
                    hasAnyItems: hasAnyItems,
                    hasAnyFriends: hasAnyFriends,
                    hasUnassignedDevices: hasUnassignedDevices,
                    hasUnassignedItems: hasUnassignedItems,
                    hasUnassignedFriends: hasUnassignedFriends
                ),
                filter: unassignedFilter,
                devicesEnabled: settings.enableDevices,
                itemsEnabled: settings.enableItems,
                friendsEnabled: settings.enableFriends
            ) {
                emptyState(img, msg)
            }
        } else {
            // Partition into top-level entries (no parentID) and children grouped
            // by parentID. Children whose parent isn't in the filtered list are
            // treated as orphans and shown flat at the top level.
            let topLevelIDs: Set<String> = Set(filteredUnassigned
                .filter { $0.point.parentID == nil }
                .map { $0.point.id.normalized() })
            let topLevel: [LocatedEntry] = filteredUnassigned.filter { e in
                guard let pid = e.point.parentID else { return true }
                return !topLevelIDs.contains(pid.normalized())
            }
            let childrenByParent: [String: [LocatedEntry]] = Dictionary(grouping:
                filteredUnassigned.filter { e in
                    guard let pid = e.point.parentID else { return false }
                    return topLevelIDs.contains(pid.normalized())
                }, by: { $0.point.parentID!.normalized() })

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(topLevel.enumerated()), id: \.1.point.id) { idx, entry in
                        let isLast = idx == topLevel.count - 1
                        let parentNormalizedID = entry.point.id.normalized()
                        let kids = childrenByParent[parentNormalizedID] ?? []
                        let isExpanded = expandedParents.contains(parentNormalizedID)
                        let disclosure: (isCollapsed: Bool, onToggle: () -> Void)? = kids.isEmpty
                            ? nil
                            : (!isExpanded, {
                                if expandedParents.contains(parentNormalizedID) {
                                    expandedParents.remove(parentNormalizedID)
                                } else {
                                    expandedParents.insert(parentNormalizedID)
                                }
                            })

                        ParentDisclosureRow(
                            hasChildren: !kids.isEmpty,
                            isCollapsed: !isExpanded,
                            header: {
                                unassignedRowFor(entry: entry,
                                                 isLast: kids.isEmpty || !isExpanded ? isLast : false,
                                                 disclosure: disclosure)
                            },
                            children: {
                                ForEach(Array(kids.enumerated()), id: \.1.point.id) { kIdx, kEntry in
                                    unassignedRowFor(entry: kEntry,
                                                     isLast: kIdx == kids.count - 1 && isLast)
                                }
                            }
                        )
                        .padding(.top, idx == 0 ? -8 : 0)
                    }
                }
                .padding(.leading, 12)
                .padding(.trailing, 14)
                .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func unassignedRowFor(
        entry: LocatedEntry,
        isLast: Bool,
        disclosure: (isCollapsed: Bool, onToggle: () -> Void)? = nil
    ) -> some View {
        let d = entry.point
        let isAssigned = knownUUIDsSet.contains(d.id.normalized())
        let matching = settings.aliases.filter { ($0.lastSeenName ?? "").caseInsensitiveCompare(d.name) == .orderedSame }
        // "Update" is the rotated-UUID flow: a name match on an alias whose
        // UUID rotated, so clicking adds the new UUID to the existing alias.
        // When this UUID is already in the alias, "Update" would no-op — show
        // a (disabled) "Assign" instead. The label change keeps the row honest.
        let isUpdate = !isAssigned && !matching.isEmpty
        UnassignedRow(name: d.name,
                      id: d.id,
                      source: entry.source,
                      onAssign: {
            if isUpdate, let match = matching.first {
                settings.updateAliasWithCap(match.alias, addUUID: d.id, lastSeenName: d.name)
                logger.info("Alias \"\(match.alias)\" updated with UUID \(d.id.normalized())")
            } else {
                assignUUID = d.id
                assignName = d.name
                assignAlias = slugifyAlias(d.name.isEmpty ? "device" : d.name)
                showAssignSheet = true
            }
        }, showsDivider: !isLast, isUpdate: isUpdate,
                      disclosure: disclosure, isAssigned: isAssigned)
    }

    @ViewBuilder
    private var aliasesList: some View {
        if rowsSorted.isEmpty {
            VStack(alignment: .center, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.stack.person.crop")
                        .foregroundStyle(.secondary)
                    Text("No aliases created. Use **Assign** above to create one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 16)
        } else {
            if filteredAliases.isEmpty {
                if let (img, msg) = emptyStateInfo(
                    mode: .aliases(
                        hasDeviceAliases: hasDeviceAliases,
                        hasItemAliases: hasItemAliases,
                        hasFriendAliases: hasFriendAliases
                    ),
                    filter: aliasesFilter,
                    devicesEnabled: settings.enableDevices,
                    itemsEnabled: settings.enableItems,
                    friendsEnabled: settings.enableFriends
                ) {
                    emptyState(img, msg)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAliases, id: \.alias) { rec in
                            let singleSource = singleSource(forKnownUUIDs: rec.knownUUIDs, using: sourceMap)
                            let sortedUUIDs = rec.knownUUIDs
                            AliasRowContainer {
                                AliasRowView(
                                    aliasKey: rec.alias,
                                    tracked: rec.tracked,
                                    knownUUIDs: sortedUUIDs,
                                    lastSeenName: rec.lastSeenName,
                                    sourceBadge: singleSource,
                                    nameLabel: "Name:",
                                    transportMode: settings.transportMode,
                                    mqttConnected: app.syncEngine.mqtt.connectionState == .connected,
                                    onToggleTracked: { (newValue: Bool) in
                                        settings.setAlias(rec.alias, tracked: newValue)
                                    },
                                    onRename: {
                                        renameAliasKey = rec.alias
                                        renameText = rec.alias
                                        showRenameSheet = true
                                    },
                                    onDelete: {
                                        deleteAliasKey = rec.alias
                                        showDeleteConfirm = true
                                    },
                                    onReRegister: {
                                        reRegisterAliasKey = rec.alias
                                        showReRegisterConfirm = true
                                    },
                                    onDeleteUUID: { uuid in
                                        if rec.tracked && rec.knownUUIDs.count == 1 && rec.knownUUIDs.contains(uuid) {
                                            pendingUUIDDelete = (aliasKey: rec.alias, uuid: uuid)
                                        } else {
                                            settings.updateAlias(rec.alias, removeUUID: uuid)
                                            logger.info(#"Alias "\#(rec.alias)" no longer includes UUID \#(uuid)"#)
                                        }
                                    }
                                )
                            }
                            .padding(.top, rec.alias == filteredAliases.first?.alias ? -8 : 0)
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.trailing, 14)
                }
            }
        }
    }

    private struct CompactSwitchStyle: ToggleStyle {
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

    private struct AliasRowView: View {
        let aliasKey: String
        let tracked: Bool
        let knownUUIDs: [String]
        let lastSeenName: String?
        let sourceBadge: DeviceSource?
        let nameLabel: String
        let transportMode: TransportMode
        let mqttConnected: Bool

        var onToggleTracked: (Bool) -> Void
        var onRename: () -> Void
        var onDelete: () -> Void
        var onReRegister: () -> Void
        var onDeleteUUID: (String) -> Void

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
                            .disabled(!mqttConnected)
                            .help(mqttConnected
                                  ? "Re-create the Home Assistant entity so its ID matches this alias"
                                  : "Connect to MQTT to re-create this entity")
                        }

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
}

private struct AssignAliasSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var assignUUID: String?
    @Binding var assignName: String
    @Binding var assignAlias: String
    var onConfirm: (_ uuid: String, _ name: String, _ alias: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "tag")
                Text("Assign Device")
            }
            .font(.title3).fontWeight(.semibold)
            Text("Create a new alias for this device. You can manage tracking on the Aliases list.")
                .foregroundStyle(.secondary)

            Grid(alignment: .leadingFirstTextBaseline) {
                GridRow {
                    Text("Device").fontWeight(.semibold)
                    Text(assignName.isEmpty ? "(Unnamed device)" : assignName)
                }
                GridRow {
                    Text("UUID").fontWeight(.semibold)
                    Text(assignUUID ?? "")
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                }
                GridRow {
                    Text("Alias").fontWeight(.semibold)
                    TextField("alias", text: $assignAlias)
                        // No live slugify — let the user type freely
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                }
                GridRow {
                    Text("") // spacer
                    Text("Allowed: letters, numbers, hyphen, underscore. Will be normalized on save.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    assignUUID = nil
                    dismiss()
                }
                Button("Create") {
                    guard let uuid = assignUUID else { return }
                    // Normalize just once on save, ensuring uniqueness
                    let cleaned = slugifyAlias(assignAlias)
                    onConfirm(uuid, assignName, cleaned)
                    assignUUID = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((assignUUID ?? "").isEmpty || assignAlias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 320)
    }
}

private struct RenameAliasSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var aliasKey: String?
    @Binding var renameText: String
    var onConfirm: (_ aliasKey: String, _ newAlias: String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.and.pencil")
                Text("Rename Alias")
            }
            .font(.title3).fontWeight(.semibold)
            Text("Renaming creates a new Home Assistant Entity ID.").foregroundStyle(.secondary)
            TextField("alias", text: $renameText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 320)

            HStack {
                Spacer()
                Button("Cancel") { aliasKey = nil; dismiss() }
                Button("Rename") {
                    if let key = aliasKey {
                        onConfirm(key, renameText)
                    }
                    aliasKey = nil
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled((aliasKey ?? "").isEmpty || renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 300)
    }
}

private struct EmptyStateView: View {
    let systemImage: String
    let message: String

    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
        .multilineTextAlignment(.center)
    }
}
