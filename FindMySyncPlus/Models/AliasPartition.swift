import Foundation

/// Splits the Aliases list into top-level rows, their nested children, and headers for
/// groups that are not themselves aliased.
///
/// The Aliases list is persisted config and holds rows for devices that did not report
/// this cycle, so an aliased parent joins on the persisted `parentAlias`, not the run-scoped
/// `parentID` map the Unassigned list uses — UUIDs rotate, aliases do not, and a live join
/// would go flat for every offline group. A row nests exactly when its `parentAlias` names
/// another row in the list.
///
/// Headers cover the case that rule cannot reach: `parentAlias` is written only when both
/// ends are aliased, so a user who aliased the children and never the group has nothing
/// stored. The header is drawn from the live grouping instead, which is sound because an
/// unaliased parent only reaches the list through a reporting child.
///
/// Pure and value-typed so it can be tested away from the view — see `AliasNestingTests`.
struct AliasPartition {

    /// A group that is not itself aliased, shown so its aliased children can nest. Not an
    /// alias: it carries no entity, tracking, rename or delete. Assigning it is the Unassigned
    /// pane's job; once assigned, a real row replaces it in place.
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
        // Matched on `knownUUIDs` rather than a live lookup, so an aliased parent still
        // supersedes a header when it did not report.
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

            // No `parentAlias`, but the group's own row exists and owns this id — the state
            // left by aliasing a group after its children. Nest under the real row; a header
            // beside it would draw the same group twice.
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

            // Nothing live: use what the child persisted. This is what makes a header present
            // whether or not anything reported, and covers a group whose alias was deleted
            // and a group that has never reported.
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

    /// True when nothing nests. The normal state on a Mac where no device record carries an
    /// `itemGroup` and the group lives only in `ItemGroups.data`: no join is observed, so no
    /// child acquires a `parentAlias` and there is no live grouping to draw a header from.
    var isFlat: Bool { childrenByParent.isEmpty && childrenByHeader.isEmpty }
}
