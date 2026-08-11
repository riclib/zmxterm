import CoreGraphics
import Foundation

/// Frames for every pane and divider in one pass.
///
/// The obvious SwiftUI shape — a recursive view where each split is a
/// `GeometryReader` handing `.frame(width:)` to its children — costs a layout
/// pass per level and settles over several frames. Panes visibly land on a
/// sliver width before reaching their real one, and each of those intermediate
/// sizes is a real `.Resize` on the wire. Computing the whole tree against one
/// rect instead makes placement a pure function with no layout feedback.
enum PaneLayout {
    struct Placed {
        let session: ZmxSession
        let rect: CGRect
        /// Share of the whole tab, which is what gets written back to `size`.
        let share: Double
    }

    /// The gap between two adjacent children of a split. The visible gap is
    /// `Theme.gap`; the grab strip overhangs both neighbours so the divider
    /// stays comfortable to hit without widening the seam.
    struct Divider: Identifiable {
        let id: String
        let axis: SplitAxis
        /// The visible seam.
        let rect: CGRect
        /// Which split it belongs to, and which boundary within it.
        let splitID: String
        let boundary: Int
        /// Child fractions of that split, and the extent they divide.
        let fractions: [Double]
        let extent: CGFloat
        /// Where the split's region starts along its axis, and the gap between
        /// its children. A drag needs these to turn an absolute pointer
        /// position into a fraction without ever consulting the moving handle.
        let regionOrigin: CGFloat
        let gap: CGFloat
    }

    struct Result {
        var panes: [Placed] = []
        var dividers: [Divider] = []
    }

    /// A pane never drags below this. A purely proportional floor compounds
    /// under nesting into slivers, so clamp against real points instead.
    static let minPaneExtent: CGFloat = 120

    static func compute(
        _ node: PaneNode,
        in rect: CGRect,
        gap: CGFloat,
        overrides: [String: [Double]] = [:]
    ) -> Result {
        var result = Result()
        place(node, rect: rect, gap: gap, path: "", share: 1.0, overrides: overrides, into: &result)
        return result
    }

    private static func place(
        _ node: PaneNode,
        rect: CGRect,
        gap: CGFloat,
        path: String,
        share: Double,
        overrides: [String: [Double]],
        into result: inout Result
    ) {
        switch node {
        case let .leaf(session):
            result.panes.append(Placed(session: session, rect: rect, share: share))

        case let .split(axis, children):
            let fractions = overrides[path] ?? children.map(\.fraction)
            let horizontal = axis == .horizontal
            let total = horizontal ? rect.width : rect.height
            let available = max(0, total - gap * CGFloat(children.count - 1))

            var cursor = horizontal ? rect.minX : rect.minY
            for (index, child) in children.enumerated() {
                let fraction = index < fractions.count ? fractions[index] : child.fraction
                let extent = available * fraction

                let childRect = horizontal
                    ? CGRect(x: cursor, y: rect.minY, width: extent, height: rect.height)
                    : CGRect(x: rect.minX, y: cursor, width: rect.width, height: extent)

                place(
                    child.node,
                    rect: childRect,
                    gap: gap,
                    path: path.isEmpty ? "\(index)" : "\(path).\(index)",
                    share: share * fraction,
                    overrides: overrides,
                    into: &result
                )

                cursor += extent
                if index < children.count - 1 {
                    let seam = horizontal
                        ? CGRect(x: cursor, y: rect.minY, width: gap, height: rect.height)
                        : CGRect(x: rect.minX, y: cursor, width: rect.width, height: gap)
                    result.dividers.append(Divider(
                        id: "\(path)#\(index)",
                        axis: axis,
                        rect: seam,
                        splitID: path,
                        boundary: index,
                        fractions: fractions,
                        extent: available,
                        regionOrigin: horizontal ? rect.minX : rect.minY,
                        gap: gap
                    ))
                    cursor += gap
                }
            }
        }
    }

    /// Move one boundary to follow an absolute pointer position.
    ///
    /// Taking the pointer's location rather than a translation is the whole
    /// trick. A handle dragged by its own translation reports in a coordinate
    /// space that moves with it, so the measurement feeds back into the thing
    /// being measured and the divider stutters. Every quantity here is fixed
    /// for the duration of a drag: `base` is the pre-drag fractions, and the
    /// children before the boundary never move, so their prefix is constant.
    static func fractions(
        draggingTo location: CGFloat,
        divider: Divider,
        base: [Double]
    ) -> [Double]? {
        guard divider.extent > 0, divider.boundary + 1 < base.count else { return nil }

        let prefix = base[0 ..< divider.boundary].reduce(0, +) * Double(divider.extent)
            + Double(divider.gap) * Double(divider.boundary)
        let desired = Double(location - divider.regionOrigin - divider.gap / 2) - prefix

        var moved = base
        let floor = Double(minPaneExtent / divider.extent)
        let before = desired / Double(divider.extent)
        let after = base[divider.boundary] + base[divider.boundary + 1] - before
        guard before >= floor, after >= floor else { return nil }

        moved[divider.boundary] = before
        moved[divider.boundary + 1] = after
        return moved
    }
}
