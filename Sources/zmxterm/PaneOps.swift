import Foundation

/// Label edits that create a pane, expressed as data so they can be tested
/// without a window and applied by anything that can run `zmx set`.
///
/// Splitting is not an app operation that happens to write labels — it *is* the
/// labels. The same edits from a shell script produce the same pane, which is
/// why an agent gets "split right" without the app exposing an API for it.
enum PaneOps {
    struct LabelChange: Equatable {
        let session: String
        var position: String?
        var size: Double?
        var tab: String?
        var ephemeral: Bool = false
    }

    /// Where a new pane goes relative to the focused one.
    ///
    /// Two shapes are possible and only one is pleasant. If the focused pane's
    /// parent already splits on the axis you asked for, the newcomer becomes a
    /// sibling — three panes side by side stay `h[a b c]`. Ghostty and Enso
    /// can't do this because their trees are binary, so a third split always
    /// nests into `h[a h[b c]]` and the dividers stop lining up with what you
    /// think you're dragging. Deepening is reserved for a genuine change of
    /// axis.
    static func split(
        panes: [ZmxSession],
        focused: String,
        axis: SplitAxis,
        newSession: String,
        tab: String
    ) -> [LabelChange] {
        guard let focusedPane = panes.first(where: { $0.name == focused }) else { return [] }

        let path = PosSegment.parse(focusedPane.position ?? "")
        let shares = normalizedShares(panes)
        let half = (shares[focused] ?? 1.0 / Double(max(panes.count, 1))) / 2

        var changes: [LabelChange] = []

        if let last = path.last, last.axis == axis {
            // Sibling insert: everything after the focused slot shifts up one.
            let parent = path.dropLast()
            let prefix = render(Array(parent))
            for pane in panes where pane.name != focused {
                let panePath = PosSegment.parse(pane.position ?? "")
                guard panePath.count > parent.count,
                      render(Array(panePath.prefix(parent.count))) == prefix,
                      panePath[parent.count].axis == axis,
                      panePath[parent.count].index > last.index
                else { continue }
                var shifted = panePath
                shifted[parent.count] = PosSegment(axis: axis, index: shifted[parent.count].index + 1)
                changes.append(LabelChange(session: pane.name, position: render(shifted)))
            }
            changes.append(LabelChange(session: focused, position: nil, size: half))
            changes.append(LabelChange(
                session: newSession,
                position: render(Array(parent) + [PosSegment(axis: axis, index: last.index + 1)]),
                size: half,
                tab: tab,
                ephemeral: true
            ))
        } else {
            // Deepen: the focused leaf becomes a split holding itself and the
            // newcomer. Only these two rows move.
            changes.append(LabelChange(
                session: focused,
                position: render(path + [PosSegment(axis: axis, index: 0)]),
                size: half
            ))
            changes.append(LabelChange(
                session: newSession,
                position: render(path + [PosSegment(axis: axis, index: 1)]),
                size: half,
                tab: tab,
                ephemeral: true
            ))
        }

        return changes
    }

    /// What renaming a tab would actually do, decided before anything is
    /// written.
    ///
    /// A tab's identity *is* its `tab` label, so a rename is a rewrite of that
    /// label across its panes — and rewriting it to a name already in use is
    /// indistinguishable, at the moment of writing, from deliberately merging
    /// two tabs into one. The label was the only record of which tab a pane
    /// came from, so once both sets share a value there is nothing left to
    /// separate them by: the merge cannot be undone by renaming back.
    ///
    /// Hence a decision returned as data rather than a bare success/failure.
    /// Merging is a reasonable thing to want; arriving at it by typing a name
    /// that happened to be taken is not, so the caller is expected to ask.
    enum TabRename: Equatable {
        /// Nothing to do — the name folded to empty, or to the name it already has.
        case unchanged
        /// The destination is free.
        case rename(to: String)
        /// The destination already holds panes, which this would join.
        case merge(into: String)
    }

    /// Note the collision test asks for each pane's *effective* tab, not its
    /// label. A session called `beta` with no `tab` label still occupies the
    /// name `beta`, because that is where it renders; a check against labels
    /// alone would call the name free and merge into it anyway.
    static func renameTab(_ tab: String, to raw: String, among panes: [ZmxSession]) -> TabRename {
        let slug = Zmx.slug(raw)
        guard !slug.isEmpty, slug != tab else { return .unchanged }
        return panes.contains { $0.tab == slug } ? .merge(into: slug) : .rename(to: slug)
    }

    /// Each pane's share of the tab, filling in equal shares where `size` is
    /// absent so halving a pane means something even before anyone has dragged
    /// a divider.
    private static func normalizedShares(_ panes: [ZmxSession]) -> [String: Double] {
        let declared = panes.compactMap(\.sizeFraction).reduce(0, +)
        let undeclared = panes.filter { $0.sizeFraction == nil }.count
        let fallback = undeclared > 0 ? max(0, 1 - declared) / Double(undeclared) : 0

        var shares: [String: Double] = [:]
        for pane in panes {
            shares[pane.name] = pane.sizeFraction ?? fallback
        }
        let total = shares.values.reduce(0, +)
        guard total > 0 else {
            return Dictionary(uniqueKeysWithValues: panes.map { ($0.name, 1.0 / Double(panes.count)) })
        }
        return shares.mapValues { $0 / total }
    }

    private static func render(_ path: [PosSegment]) -> String {
        path.map { "\($0.axis.label)\($0.index)" }.joined(separator: ".")
    }
}
