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

private struct UnassignedRow: View {
    let name: String
    let id: String
    let source: AppModel.DeviceSource
    var onAssign: () -> Void
    var showsDivider: Bool = true
    let isUpdate: Bool
    @State private var hovering = false
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(name.isEmpty ? "(Unnamed device)" : name)
                        .fontWeight(.semibold)
                    SourceBadge(source: source)
                }
                Text(id)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onAssign) {
                Text(isUpdate ? "Update" : "Assign")
            }
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
    
    @State private var deleteAliasKey: String? = nil
    @State private var showDeleteConfirm = false

    // Unified source filter for both Unassigned and Aliases sections
    private enum SourceFilter: String, CaseIterable, Identifiable {
        case all, devices, items
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .devices: return "Devices"
            case .items: return "Items"
            }
        }
    }
    @State private var unassignedFilter: SourceFilter = .all
    @State private var aliasesFilter: SourceFilter = .all

    private var knownUUIDsSet: Set<String> {
        Set(settings.aliases.flatMap { $0.knownUUIDs })
    }

    private var entriesAll: [AppModel.LocatedEntry] {
        app.lastLocatedEntries
    }

    private var baseUnassigned: [AppModel.LocatedEntry] {
        entriesAll.filter { !knownUUIDsSet.contains($0.point.id.normalized()) }
    }

    private var filteredUnassigned: [AppModel.LocatedEntry] {
        switch unassignedFilter {
        case .all:     return baseUnassigned
        case .devices: return baseUnassigned.filter { $0.source == .device }
        case .items:   return baseUnassigned.filter { $0.source == .item }
        }
    }

    private var rowsSorted: [DeviceAlias] {
        settings.aliases.sorted { $0.alias.localizedStandardCompare($1.alias) == .orderedAscending }
    }

    private var sourceMap: [String: AppModel.DeviceSource] {
        app.sourceByUUIDMap(from: app.lastLocatedEntries)
    }

    private var hasDeviceAliases: Bool {
        rowsSorted.contains { singleSource(forKnownUUIDs: $0.knownUUIDs, using: sourceMap) == .device }
    }

    private var hasItemAliases: Bool {
        rowsSorted.contains { singleSource(forKnownUUIDs: $0.knownUUIDs, using: sourceMap) == .item }
    }

    private var filteredAliases: [DeviceAlias] {
        rowsSorted.filter { rec in
            let single = singleSource(forKnownUUIDs: rec.knownUUIDs, using: sourceMap)
            switch aliasesFilter {
            case .all:     return true
            case .devices: return single == .device
            case .items:   return single == .item
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
        case aliases(hasDeviceAliases: Bool, hasItemAliases: Bool)
        case unassigned(entriesAllEmpty: Bool,
                        hasAnyDevices: Bool,
                        hasAnyItems: Bool,
                        hasUnassignedDevices: Bool,
                        hasUnassignedItems: Bool)
    }

    private func emptyStateInfo(mode: EmptyStateMode,
                                filter: SourceFilter,
                                devicesEnabled: Bool,
                                itemsEnabled: Bool) -> (String, String)? {
        switch mode {
        case let .aliases(hasDeviceAliases, hasItemAliases):
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
            }

        case let .unassigned(entriesAllEmpty, hasAnyDevices, hasAnyItems, hasUnassignedDevices, hasUnassignedItems):
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
            }
        }
    }

    // Determine a single source for an alias record, if all mapped UUIDs agree
    private func singleSource(forKnownUUIDs uuids: [String], using map: [String: AppModel.DeviceSource]) -> AppModel.DeviceSource? {
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
                        tip: """
Link a device’s UUID to an alias.
Entity_id derives from the alias: dev_id == host_name == `findmy_<alias>`.
Identity is stable: mac is derived from the alias. Do not send `location_name` to preserve HA zones.
""",
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
                        tip: """
Add UUIDs here if Apple rotates them; the entity remains `findmy_<alias>`.
Renaming an alias creates a new HA Entity ID (dev_id/host_name).
""",
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
                logger.warn("Alias \"\(key)\" deleted. Clean up the HA entity if desired.")
            }
            Button("Cancel", role: .cancel) { }
        } message: { key in
            Text("This does not remove any Home Assistant entity. The alias “\(key)” and its UUID mappings will be removed from this app.")
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

        // Unassigned presence per type (overall)
        let hasUnassignedDevices = baseUnassigned.contains { $0.source == .device }
        let hasUnassignedItems   = baseUnassigned.contains { $0.source == .item }

        if filteredUnassigned.isEmpty {
            if let (img, msg) = emptyStateInfo(
                mode: .unassigned(
                    entriesAllEmpty: entriesAll.isEmpty,
                    hasAnyDevices: hasAnyDevices,
                    hasAnyItems: hasAnyItems,
                    hasUnassignedDevices: hasUnassignedDevices,
                    hasUnassignedItems: hasUnassignedItems
                ),
                filter: unassignedFilter,
                devicesEnabled: settings.enableDevices,
                itemsEnabled: settings.enableItems
            ) {
                emptyState(img, msg)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(filteredUnassigned.enumerated()), id: \.1.point.id) { idx, entry in
                        let d = entry.point
                        let matching = settings.aliases.filter { ($0.lastSeenName ?? "").caseInsensitiveCompare(d.name) == .orderedSame }
                        let isUpdate = !matching.isEmpty
                        UnassignedRow(name: d.name,
                                      id: d.id,
                                      source: entry.source,
                                      onAssign: {
                            if isUpdate {
                                settings.updateAliasWithCap(matching.first!.alias, addUUID: d.id, lastSeenName: d.name)
                                logger.info("Alias \"\(matching.first!.alias)\" updated with UUID \(d.id.normalized())")
                            } else {
                                assignUUID = d.id
                                assignName = d.name
                                assignAlias = slugifyAlias(d.name.isEmpty ? "device" : d.name)
                                showAssignSheet = true
                            }
                        }, showsDivider: idx < filteredUnassigned.count - 1, isUpdate: isUpdate)
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
                        hasItemAliases: hasItemAliases
                    ),
                    filter: aliasesFilter,
                    devicesEnabled: settings.enableDevices,
                    itemsEnabled: settings.enableItems
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
        let sourceBadge: AppModel.DeviceSource?
        let nameLabel: String
        
        var onToggleTracked: (Bool) -> Void
        var onRename: () -> Void
        var onDelete: () -> Void
        var onDeleteUUID: (String) -> Void
        
        @State private var hoverRename = false
        @State private var hoverTrash  = false
        @State private var showCopiedName = false
        
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
                            if let name = lastSeenName, !name.isEmpty {
                                Button(action: {
                                    let pb = NSPasteboard.general
                                    pb.clearContents()
                                    pb.setString(name, forType: .string)
                                    withAnimation(.easeInOut(duration: 0.15)) { showCopiedName = true }
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                                        withAnimation(.easeInOut(duration: 0.2)) { showCopiedName = false }
                                    }
                                }) {
                                    Image(systemName: "doc.on.doc")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Copy device name for known_devices.yaml")

                                Text("Copied")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .opacity(showCopiedName ? 1 : 0)
                            }
                        }
                        Spacer()
                    }
                    GridRow {
                        Text("Entity ID:")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("findmy_\(aliasKey)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
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

