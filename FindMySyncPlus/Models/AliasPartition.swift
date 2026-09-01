import Foundation

/// Splits the Aliases list into top-level rows, their nested children, and headers for
/// groups that are not themselves aliased.
///
/// The Aliases list is persisted config: it holds rows for devices that did not report
/// this cycle, which is normal for anything offline. So the join for an **aliased**
/// parent is the persisted `parentAlias` rather than the run-scoped `parentID` map the
/// Unassigned list uses — joining persisted rows against live UUIDs would go flat for
/// every offline group, and UUIDs rotate while aliases do not.
///
/// A row nests exactly when its `parentAlias` names another row present in the list.
/// That is the whole rule: the "once every member is aliased" condition earlier drafts
/// described needs no evaluating, because a list of aliases contains only aliases.
///
/// **Headers cover the case that rule cannot reach.** `parentAlias` is written only when
/// both ends are aliased, so a user who aliased the children and never the group has no
/// stored value (issue #22). Those rows would otherwise sit flat. A header is drawn
/// from the live grouping instead, since it is the only source available; that is sound
/// rather than a compromise, because an unaliased parent with no position of its own
/// only reaches the list through revival, and revival needs a reporting child. Whenever
/// a child is present to nest, the parent is present to nest under.
///
/// Pure and value-typed so it can be tested away from the view — the cases it has to
/// survive come from three real systems, not from imagination. See `AliasNestingTests`.
struct AliasPartition {

    /// A group that is not itself aliased, shown so its aliased children can nest.
    ///
    /// Not an alias and not pretending to be one: it carries no entity, no tracking and
    /// no rename or delete. Assigning it is the Unassigned pane's job, and once assigned
    /// a real row replaces it in place.
    struct Header: Equatable {
        /// The parent's normalized id — stable within a run, and what the children join on.
        let id: String
        /// Apple's own name for the group, e.g. "AirPods Pro".
        let name: String
    }

    /// Rows shown at the top level, in the order given.
    let topLevel: [DeviceAlias]

    /// Groups present in this run whose own alias does not exist, in name order.
    let headers: [Header]

    private let childrenByParent: [String: [DeviceAlias]]
    private let childrenByHeader: [String: [DeviceAlias]]

    /// - Parameter liveGroups: alias → the group it belongs to this run, as
    ///   `(parent id, parent name)`. Only consulted for rows with no `parentAlias`; an
    ///   aliased parent always wins, so a real row supersedes a header rather than both
    ///   being drawn.
    init(_ aliases: [DeviceAlias], liveGroups: [String: (id: String, name: String)] = [:]) {
        let names = Set(aliases.map(\.alias))

        var children: [String: [DeviceAlias]] = [:]
        var headerChildren: [String: [DeviceAlias]] = [:]
        var headerNames: [String: String] = [:]
        var top: [DeviceAlias] = []

        // Every group id we know of, from this run or from what children persisted.
        // The persisted half is what lets the checks below work with nothing live.
        let knownGroupIDs = Set(liveGroups.values.map(\.id))
            .union(aliases.compactMap(\.parentGroupID))

        // An alias that owns one of those ids is the parent itself, not one of its own
        // children — without this it would nest under a header bearing its own name.
        //
        // Matched on `knownUUIDs` rather than on a live lookup, so an aliased parent
        // still supersedes a header when it did not report. Checking `liveGroups` alone
        // drew both a real row and a header for one group as soon as the persisted
        // fallback below could fire.
        let parentAliasByGroupID: [String: String] = Dictionary(
            aliases.flatMap { row in
                row.knownUUIDs.filter { knownGroupIDs.contains($0) }.map { ($0, row.alias) }
            },
            uniquingKeysWith: { first, _ in first }
        )
        let aliasedParentIDs = Set(parentAliasByGroupID.keys)

        for row in aliases {
            if let parent = row.parentAlias,
               parent != row.alias,             // self-reference
               names.contains(parent) {
                children[parent, default: []].append(row)
                continue
            }

            // No `parentAlias`, but the group's own row exists and owns this id. That is
            // the state left by aliasing a group *after* its children — the join was
            // observed when the group had no alias to record, so only the id was stored.
            // Nest under the real row: a header beside it would draw the same group
            // twice, and top level would lose the nesting the user just created.
            if let groupID = row.parentGroupID,
               let parent = parentAliasByGroupID[groupID],
               parent != row.alias {
                children[parent, default: []].append(row)
                continue
            }

            // No usable stored parent. The live grouping goes first because it carries
            // Apple's *current* name — a rename must not be masked by a stale copy.
            if let group = liveGroups[row.alias],
               !row.knownUUIDs.contains(group.id),      // not the parent itself
               !aliasedParentIDs.contains(group.id) {   // the parent has a real row
                headerChildren[group.id, default: []].append(row)
                headerNames[group.id] = group.name
                continue
            }

            // Nothing live: use what the child persisted about its group. This is what
            // makes a header behave like the rest of this list — present whether or not
            // anything reported — and it covers two states the live path cannot. A group
            // whose alias was deleted leaves its children pointing at a row that is
            // gone, and a group that has never reported has no live entry to find.
            if let groupID = row.parentGroupID,
               !row.knownUUIDs.contains(groupID),
               !aliasedParentIDs.contains(groupID) {
                headerChildren[groupID, default: []].append(row)
                // Only as a fallback: a live name for the same group already won above,
                // and must not be overwritten by another child's stale copy.
                if headerNames[groupID] == nil {
                    headerNames[groupID] = row.parentGroupName ?? "Group"
                }
                continue
            }

            top.append(row)
        }

        // One level only, which is all Apple's grouping produces. A row that is itself
        // nested cannot also be a parent: promote its would-be children rather than
        // rendering a second level or, worse, dropping them. This also breaks any cycle,
        // since at least one member of a cycle is never a top-level row.
        let nested = Set(children.values.joined().map(\.alias))
        for (parent, rows) in children where nested.contains(parent) {
            top.append(contentsOf: rows)
            children[parent] = nil
        }

        // Children keep name order within a parent, so a row does not move between runs
        // — the list is otherwise sorted by name, and nesting must not fight that.
        self.childrenByParent = children.mapValues { $0.sorted { $0.alias < $1.alias } }
        self.childrenByHeader = headerChildren.mapValues { $0.sorted { $0.alias < $1.alias } }
        self.topLevel = top
        self.headers = headerNames
            .map { Header(id: $0.key, name: $0.value) }
            .sorted { $0.name < $1.name }
    }

    func children(of alias: String) -> [DeviceAlias] {
        childrenByParent[alias] ?? []
    }

    func children(ofHeader id: String) -> [DeviceAlias] {
        childrenByHeader[id] ?? []
    }

    /// True when nothing nests — every row is top-level, with no headers either.
    ///
    /// The normal state on a Mac where no device record carries an `itemGroup` and the
    /// group is only described in `ItemGroups.data`: no join is ever observed, so no
    /// child acquires a `parentAlias` and no live grouping exists to draw a header from.
    var isFlat: Bool { childrenByParent.isEmpty && childrenByHeader.isEmpty }
}
