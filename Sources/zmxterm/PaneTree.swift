import Foundation

enum SplitAxis: Character {
    case horizontal = "h" // children side by side
    case vertical = "v" // children stacked

    var label: String { self == .horizontal ? "h" : "v" }
}

/// One step down the split tree: the axis its parent splits on, and which child
/// it is. A full position is these joined with dots — `v0.h1.v2`.
///
/// The path lives in a label, so it must survive zmx's value charset, which
/// allows only `[A-Za-z0-9._-]`. Letter-plus-index does, and it keeps every
/// pane self-describing: no central layout record to drift from the sessions.
struct PosSegment: Equatable {
    let axis: SplitAxis
    let index: Int

    static func parse(_ raw: String) -> [PosSegment] {
        raw.split(separator: ".").compactMap { piece in
            guard let first = piece.first,
                  let axis = SplitAxis(rawValue: first),
                  let index = Int(piece.dropFirst())
            else { return nil }
            return PosSegment(axis: axis, index: index)
        }
    }
}

indirect enum PaneNode {
    case leaf(ZmxSession)
    case split(axis: SplitAxis, children: [PaneChild])
}

struct PaneChild {
    let fraction: Double
    let node: PaneNode
}

enum PaneTree {
    /// Rebuild a tab's split tree from its panes' `pos` labels. Panes with no
    /// position land side by side, which is what a tab assembled by hand — or
    /// by an agent that didn't bother — should look like.
    static func build(_ panes: [ZmxSession]) -> PaneNode? {
        let entries = panes.map { Entry(path: PosSegment.parse($0.position ?? "")[...], session: $0) }
        return build(entries)
    }

    private struct Entry {
        var path: ArraySlice<PosSegment>
        let session: ZmxSession
    }

    private static func build(_ entries: [Entry]) -> PaneNode? {
        guard !entries.isEmpty else { return nil }
        // A lone pane is a leaf regardless of how deep its path claims to be:
        // a split with one child is just the child.
        if entries.count == 1 { return .leaf(entries[0].session) }

        let axis = entries.compactMap { $0.path.first?.axis }.first ?? .horizontal

        // A pane whose path ran out while siblings remain has no slot of its
        // own — an unlabelled pane, a stale label, or two panes claiming one
        // position. Give each its own slot after the claimed ones rather than
        // dropping it: a visible pane beats a tidy tree, and grouping them
        // together would recurse on an unchanged set forever.
        let highestClaimed = entries.compactMap { $0.path.first?.index }.max() ?? -1
        var nextFreeSlot = highestClaimed + 1
        var slotted: [(slot: Int, entry: Entry)] = []
        for entry in entries.sorted(by: { $0.session.name < $1.session.name }) {
            if let claimed = entry.path.first?.index {
                slotted.append((claimed, entry))
            } else {
                slotted.append((nextFreeSlot, entry))
                nextFreeSlot += 1
            }
        }

        let groups = Dictionary(grouping: slotted, by: \.slot)
        var children: [PaneChild] = []
        for key in groups.keys.sorted() {
            let group = groups[key]!.map { Entry(path: $0.entry.path.dropFirst(), session: $0.entry.session) }
            guard let node = build(group) else { continue }
            children.append(PaneChild(fraction: node.declaredShare, node: node))
        }
        guard !children.isEmpty else { return nil }
        return .split(axis: axis, children: normalize(children))
    }

    /// Turn declared shares into fractions that sum to 1. Panes with no `size`
    /// split whatever the declared ones left over.
    private static func normalize(_ children: [PaneChild]) -> [PaneChild] {
        let declared = children.filter { $0.fraction > 0 }
        let declaredTotal = declared.reduce(0) { $0 + $1.fraction }
        let undeclaredCount = children.count - declared.count

        guard undeclaredCount > 0 else {
            guard declaredTotal > 0 else { return children }
            return children.map { PaneChild(fraction: $0.fraction / declaredTotal, node: $0.node) }
        }

        let remainder = max(0, 1 - declaredTotal)
        let perUndeclared = remainder > 0 ? remainder / Double(undeclaredCount) : 1.0 / Double(children.count)
        let resolved = children.map {
            PaneChild(fraction: $0.fraction > 0 ? $0.fraction : perUndeclared, node: $0.node)
        }
        let total = resolved.reduce(0) { $0 + $1.fraction }
        guard total > 0 else { return children }
        return resolved.map { PaneChild(fraction: $0.fraction / total, node: $0.node) }
    }
}

extension PaneNode {
    /// Sum of the `size` labels beneath this node.
    ///
    /// `size` is a pane's share of the *whole tab*, not of its parent split.
    /// Share-of-parent reads more naturally until you try to place an internal
    /// node — a column of three panes is not a session, so it has no label of
    /// its own, and borrowing one from a leaf makes that leaf's number mean two
    /// different things at two different levels. Whole-tab shares just add up.
    /// Panes that declare nothing split whatever is left over, which is what
    /// "resize to roughly equal" wants anyway.
    var declaredShare: Double {
        switch self {
        case let .leaf(session): session.sizeFraction ?? 0
        case let .split(_, children): children.reduce(0) { $0 + $1.node.declaredShare }
        }
    }

    /// Depth-first pane list, left to right, top to bottom.
    var leaves: [ZmxSession] {
        switch self {
        case let .leaf(session): [session]
        case let .split(_, children): children.flatMap(\.node.leaves)
        }
    }

    /// Bracketed rendering used by `--selftest`, e.g. `v[h[orc v[d1 d2]] h[s1 s2]]`.
    var debugShape: String {
        switch self {
        case let .leaf(session): session.name
        case let .split(axis, children): "\(axis.label)[\(children.map(\.node.debugShape).joined(separator: " "))]"
        }
    }
}
