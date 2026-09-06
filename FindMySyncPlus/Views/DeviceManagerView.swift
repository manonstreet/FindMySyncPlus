import SwiftUI
import AppKit

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
    @State private var reRegisterFailed = false
    @State private var retirementFailed = false

    @State private var deleteAliasKey: String? = nil
    @State private var showDeleteConfirm = false

    // Ephemeral expand state for parent group rows in the unassigned list.
    // Empty set means every parent is collapsed (the default), so the user
    // sees just parent rows and clicks the chevron to reveal sub-items.
    @State private var expandedParents: Set<String> = []
    /// Which unaliased group headers the user has collapsed.
    ///
    /// Stored as *collapsed*, the opposite of the two sets above, because a header has
    /// no independent meaning. An alias parent row carries an entity, tracking and
    /// controls, so starting it collapsed merely hides its children; a header exists
    /// only to hold them, so collapsed it is a lone label above rows it has nothing to
    /// do with.
    @State private var collapsedHeaders: Set<String> = []

    /// Which alias groups are expanded. Same shape and same default as
    /// `expandedParents` above, so the identical control behaves identically in both
    /// lists: collapsed until opened, with the chevron always visible.
    @State private var expandedAliasParents: Set<String> = []

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
        var map = app.sourceByUUIDMap(from: app.lastLocatedEntries)
        // Anything other records point at as their parent is a group, not a device.
        // Badging it by the file it came from would label the same accessory
        // differently on two Macs, depending only on whether Apple embedded the group
        // in a device record or left it in ItemGroups.data.
        for parentID in entriesAll.compactMap({ $0.point.parentID?.normalized() }) {
            map[parentID] = .group
        }
        return map
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

    /// One Aliases row, rendered identically whether it sits at the top level or nested
    /// under its group. Lifted out of the list so nesting adds no second copy of it.
    /// Record the group relationship at the moment an alias is created, in both
    /// directions.
    ///
    /// `parentAlias` is written whenever a join is observed, and assigning an alias *is*
    /// an observation — the live grouping for this run is already on screen. Leaving it
    /// to the next sync means a group that plainly nests in Unassigned sits flat in
    /// Aliases for up to a full interval, which reads as the feature not working.
    ///
    /// Both directions matter: aliasing a child when the parent already has an alias,
    /// and aliasing a parent when its children already do. The second is the case that
    /// looks most broken, since the row the children need has just appeared.
    private func captureGroupJoin(newAlias: String, uuid: String) {
        let normalized = uuid.normalized()
        var updates: [(aliasKey: String, parentAlias: String)] = []

        // The new alias is a child: nest it under its parent's alias, if there is one.
        if let parentID = entriesAll.first(where: { $0.point.id.normalized() == normalized })?
            .point.parentID?.normalized(),
           let parentAlias = settings.aliases.first(where: {
               $0.knownUUIDs.contains(parentID)
           })?.alias, parentAlias != newAlias {
            updates.append((aliasKey: newAlias, parentAlias: parentAlias))
        }

        // The new alias is a parent: adopt any already-aliased children.
        let ownUUIDs = Set(settings.aliases.first(where: { $0.alias == newAlias })?.knownUUIDs ?? [normalized])
        for entry in entriesAll {
            guard let childParent = entry.point.parentID?.normalized(),
                  ownUUIDs.contains(childParent) else { continue }
            guard let childAlias = settings.aliases.first(where: {
                $0.knownUUIDs.contains(entry.point.id.normalized())
            })?.alias, childAlias != newAlias else { continue }
            updates.append((aliasKey: childAlias, parentAlias: newAlias))
        }

        settings.batchUpdateParentAliases(updates)
    }

    @ViewBuilder
    private func aliasRow(for rec: DeviceAlias,
                          disclosure: (isCollapsed: Bool, onToggle: () -> Void)? = nil) -> some View {
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
                            disclosure: disclosure,
                            onToggleTracked: { (newValue: Bool) in
                                settings.setAlias(rec.alias, tracked: newValue)
                                if !newValue {
                                    Task { if await app.publishPendingRetirements() == false { retirementFailed = true } }
                                }
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
    }

    /// Which group each aliased row belongs to *this run*, as `(parent id, name)`.
    ///
    /// Only consulted for rows with no stored `parentAlias` - that is, a group the user
    /// has never aliased (issue #22). There is no persisted
    /// value to read there, so the live grouping is the only source. It is dependable
    /// because an unaliased parent with no position of its own reaches the list only
    /// through revival, and revival needs a reporting child.
    private var liveGroupsByAlias: [String: (id: String, name: String)] {
        let parentNames: [String: String] = Dictionary(
            entriesAll.map { ($0.point.id.normalized(), $0.point.name) },
            uniquingKeysWith: { first, _ in first }
        )

        var map: [String: (id: String, name: String)] = [:]
        for entry in entriesAll {
            guard let parentID = entry.point.parentID?.normalized() else { continue }
            guard let alias = settings.aliases.first(where: {
                $0.knownUUIDs.contains(entry.point.id.normalized())
            })?.alias else { continue }
            map[alias] = (parentID, parentNames[parentID] ?? "Group")
        }

        // The parent's own alias too, so the partition can tell a real row from a header
        // and never draws both for one group.
        let groupIDs = Set(entriesAll.compactMap { $0.point.parentID?.normalized() })
        for row in settings.aliases where map[row.alias] == nil {
            for uuid in row.knownUUIDs where groupIDs.contains(uuid) {
                map[row.alias] = (uuid, parentNames[uuid] ?? "Group")
                break
            }
        }
        return map
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
            SnapshotSafeVSplit {
                // --- Unassigned ---
                VStack(spacing: 0) {
                    sectionHeader(
                        title: "Unassigned",
                        tip: "Link a device’s UUID to an alias. The alias becomes a stable Home Assistant entity that persists even when Apple rotates UUIDs.",
                        trailing: {
                            SnapshotSafeMenuPicker(selectionTitle: unassignedFilter.title) {
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
                            SnapshotSafeMenuPicker(selectionTitle: aliasesFilter.title) {
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
                captureGroupJoin(newAlias: key, uuid: uuid)
            })
        }
        .sheet(isPresented: $showRenameSheet) {
            RenameAliasSheet(aliasKey: $renameAliasKey,
                             renameText: $renameText,
                             onConfirm: { key, newName in
                let cleaned = slugifyAlias(newName)
                settings.renameAlias(from: key, to: cleaned)
                logger.info("Alias \"\(key)\" renamed to \"\(cleaned)\" (entity id will change).")
                // A rename needs both halves: the old entity cleared and the new one
                // published. A sync does both — its drain clears the tombstone and
                // its normal discovery publishes the new entity with current data.
                // Clearing alone would leave the device with no entity at all until
                // the next scheduled run.
                _ = app.runNowIfIdle()
            })
        }
        .alert("Delete Alias?",
               isPresented: $showDeleteConfirm,
               presenting: deleteAliasKey) { key in
            Button("Delete", role: .destructive) {
                settings.deleteAlias(key)
                Task { if await app.publishPendingRetirements() == false { retirementFailed = true } }
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
                Task {
                    // Never silently no-ops: with the scheduler stopped this
                    // connects on demand, and says so if it cannot.
                    if await app.reRegisterEntity(alias: key) == false {
                        reRegisterFailed = true
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { key in
            // Names the specific before and after, which is the whole reason this is
            // per-alias rather than one global button: a sweep could not say either.
            // swiftlint:disable:next line_length
            Text("The entity will be removed and re-created as “\(DeviceAlias.haEntityID(for: key))”. Any rename, icon or area you set for it in Home Assistant will be cleared, and recorded history stays under the old entity ID.")
        }
        .alert("Couldn't reach the broker", isPresented: $retirementFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            // The alias change itself always succeeds — it is local. Only the Home
            // Assistant side is outstanding, and saying so is the difference between
            // a useful message and one that implies the change was lost.
            Text("The change was saved, but Home Assistant could not be updated. It will catch up on the next successful sync.")
        }
        .alert("Couldn't reach the broker", isPresented: $reRegisterFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("The entity was not re-created. Check the MQTT settings under Access, and the log for details.")
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

            SnapshotSafeScroll {
                LazyVStack(spacing: 0) {
                    ForEach(Array(topLevel.enumerated()), id: \.1.point.id) { idx, entry in
                        let isLast = idx == topLevel.count - 1
                        let parentNormalizedID = entry.point.id.normalized()
                        let kids = childrenByParent[parentNormalizedID] ?? []
                        let isExpanded = ViewSnapshotExport.expandGroups
                            || expandedParents.contains(parentNormalizedID)
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
                SnapshotSafeScroll {
                    LazyVStack(spacing: 0) {
                        // Grouped accessories nest here as they already do in
                        // Unassigned. The join is the persisted `parentAlias`, not the
                        // run-scoped `parentID` map: this list is config and holds rows
                        // for devices that did not report this cycle, so a live join
                        // would go flat for every offline group.
                        //
                        // A row whose `parentAlias` names no row in the list is an
                        // orphan and stays at the top level — the user made it, so it
                        // is never hidden.
                        let partition = AliasPartition(filteredAliases, liveGroups: liveGroupsByAlias)
                        // The partition's shape, once, while a snapshot is being taken.
                        //
                        // Headers and nesting are UI-only: nothing in the log or the broker
                        // says whether a header was drawn, so a case could assert everything
                        // about the payload and still not notice the Aliases list going flat.
                        // `AliasNestingTests` covers the rule; this covers the *rendered*
                        // result, which is what the fixtures exist to exercise.
                        //
                        // Guarded on a render so it cannot fire from a view body during
                        // ordinary use, where it would log on every redraw.
                        let _ = ViewSnapshotExport.notePartition(
                            topLevel: partition.topLevel.count,
                            headers: partition.headers.map(\.name).sorted(),
                            nested: partition.topLevel.reduce(0) { $0 + partition.children(of: $1.alias).count }
                                + partition.headers.reduce(0) { $0 + partition.children(ofHeader: $1.id).count },
                            logger: logger)

                        // Groups whose own alias does not exist. Their children would
                        // otherwise sit flat (issue #22).
                        ForEach(partition.headers, id: \.id) { header in
                            let kids = partition.children(ofHeader: header.id)
                            let isCollapsed = collapsedHeaders.contains(header.id)
                            ParentDisclosureRow(
                                hasChildren: !kids.isEmpty,
                                isCollapsed: isCollapsed,
                                header: {
                                    AliasRowContainer {
                                        HStack(spacing: 6) {
                                            AliasGroupHeader(name: header.name)
                                                .padding(.vertical, 6)
                                            Button {
                                                if collapsedHeaders.contains(header.id) {
                                                    collapsedHeaders.remove(header.id)
                                                } else {
                                                    collapsedHeaders.insert(header.id)
                                                }
                                            } label: {
                                                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(Color.accentColor)
                                                    .frame(width: 10, height: 10)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 3)
                                                    .background(Capsule(style: .continuous).fill(Color.secondary.opacity(0.10)))
                                            }
                                            .buttonStyle(.plain)
                                            .help(isCollapsed ? "Expand grouped sub-items" : "Collapse grouped sub-items")
                                            Spacer()
                                        }
                                    }
                                },
                                children: {
                                    ForEach(kids, id: \.alias) { kid in
                                        Divider().padding(.horizontal, 12)
                                        aliasRow(for: kid)
                                    }
                                }
                            )
                            Divider().padding(.horizontal, 12)
                        }

                        ForEach(partition.topLevel, id: \.alias) { rec in
                            let kids = partition.children(of: rec.alias)
                            // Collapsed until opened, matching the Unassigned list
                            // exactly — same control, same default, so the same
                            // accessory behaves the same way in both places.
                            // A snapshot renders both states; see ViewSnapshotExport.expandGroups.
                            let isCollapsed = ViewSnapshotExport.expandGroups
                                ? false
                                : !expandedAliasParents.contains(rec.alias)
                            ParentDisclosureRow(
                                hasChildren: !kids.isEmpty,
                                isCollapsed: isCollapsed,
                                header: {
                                    aliasRow(
                                        for: rec,
                                        disclosure: kids.isEmpty ? nil : (isCollapsed, {
                                            if expandedAliasParents.contains(rec.alias) {
                                                expandedAliasParents.remove(rec.alias)
                                            } else {
                                                expandedAliasParents.insert(rec.alias)
                                            }
                                        })
                                    )
                                },
                                children: {
                                    ForEach(kids, id: \.alias) { kid in
                                        Divider().padding(.horizontal, 12)
                                        aliasRow(for: kid)
                                    }
                                }
                            )
                            Divider().padding(.horizontal, 12)
                        }
                    }
                    // Bottom only. Every row already carries its own vertical padding,
                    // so a top inset here would double up on whatever renders first —
                    // which is a group header or an alias row depending on the data.
                    .padding(.bottom, 8)
                    .padding(.trailing, 14)
                }
            }
        }
    }
}
