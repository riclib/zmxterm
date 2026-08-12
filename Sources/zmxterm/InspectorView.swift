import AppKit
import GhosttyTerminal
import SwiftUI

/// The panels the right sidebar can show.
///
/// One case today. The container is built around this enum rather than around
/// the file tree so that the second panel — the markdown preview in #20 — is a
/// case, an icon, and one line in the `switch` in `InspectorView.panelBody`,
/// with the header, the collapse rail, the width and the preference already
/// working. Whatever a panel needs from the focused pane arrives the same way
/// the files panel gets it: as the pane and its model, passed in.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case files

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder"
        }
    }
}

/// The right sidebar: the mirror of `SidebarView`, and a sibling of it.
///
/// The left rail answers "which pane", so it is a list of sessions; this one
/// answers "what is that pane looking at", so its content follows the focused
/// pane rather than choosing one. Collapsed it becomes a strip of panel icons,
/// the same trade the left rail makes — vertical space is plentiful on a tall
/// screen and horizontal is not.
struct InspectorView: View {
    /// The focused pane, and the live model behind it. Nil when the window has
    /// no tab, or a tab with no panes.
    let pane: ZmxSession?
    let model: PaneModel?
    @Binding var collapsed: Bool
    @Binding var width: Double
    @Binding var panel: String

    static let collapsedWidth: Double = 34
    static let minimumWidth: Double = 180
    static let maximumWidth: Double = 560

    /// The width the sidebar had when the current drag started. Fixed for the
    /// whole gesture: the handle moves as the sidebar resizes, so measuring
    /// against anything that moves with it stutters.
    @State private var dragBase: Double?

    private var selectedPanel: InspectorPanel {
        InspectorPanel(rawValue: panel) ?? .files
    }

    var body: some View {
        Group {
            if collapsed {
                collapsedRail
            } else {
                VStack(spacing: 0) {
                    header
                    Divider()
                    panelBody
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.chrome)
        .overlay(alignment: .leading) { if !collapsed { resizeHandle } }
    }

    /// One button per panel, so a collapsed sidebar still says what is behind
    /// it and opens straight onto the one you pointed at.
    private var collapsedRail: some View {
        VStack(spacing: 4) {
            ForEach(InspectorPanel.allCases) { item in
                Button {
                    panel = item.rawValue
                    collapsed = false
                } label: {
                    Image(systemName: item.icon)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(item.title) (⌥⌘B)")
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 6)
    }

    private var header: some View {
        HStack(spacing: 6) {
            // A picker only once there is something to pick. With one panel it
            // would be a segmented control of one, which reads as broken.
            if InspectorPanel.allCases.count > 1 {
                Picker("", selection: $panel) {
                    ForEach(InspectorPanel.allCases) { item in
                        Image(systemName: item.icon).tag(item.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            } else {
                Image(systemName: selectedPanel.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(selectedPanel.title)
                    .font(.system(size: 11, weight: .medium))
            }
            Spacer(minLength: 0)
            Button { collapsed = true } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Hide (⌥⌘B)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var panelBody: some View {
        switch selectedPanel {
        case .files:
            if let pane, let model {
                FilesPanel(pane: pane, model: model, terminal: model.terminal)
            } else {
                InspectorPlaceholder(text: "No pane focused")
            }
        }
    }

    /// A grab strip on the inner edge. The gesture reports in `.global`, which
    /// is the one coordinate space that does not move while the sidebar it is
    /// attached to changes width.
    private var resizeHandle: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 6)
            .contentShape(Rectangle())
            .onHover { hovering in
                // push/pop rather than set: the system resets the cursor on
                // every mouse-moved event, so a plain set flickers.
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let base = dragBase ?? width
                        dragBase = base
                        // Dragging left widens: the sidebar grows out of the
                        // window's trailing edge.
                        let proposed = base - (value.location.x - value.startLocation.x)
                        width = min(max(proposed, Self.minimumWidth), Self.maximumWidth)
                    }
                    .onEnded { _ in dragBase = nil }
            )
    }
}

struct InspectorPlaceholder: View {
    let text: String

    var body: some View {
        VStack {
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The file tree, rooted wherever the focused pane currently is.
///
/// `terminal` is observed rather than read once: `workingDirectory` is
/// `@Published` and libghostty raises it on every OSC 7, so a `cd` in the pane
/// is an update here and nothing polls anything. The pane is passed alongside
/// because `startDir` is the answer before the shell has said anything.
///
/// The model is a `@StateObject`, so it survives the focused pane changing —
/// `setRoot` decides whether that was a re-root. Two panes open on the same
/// project therefore share one tree, expanded folders and all, and only a real
/// change of directory folds it up.
struct FilesPanel: View {
    let pane: ZmxSession
    let model: PaneModel
    @ObservedObject var terminal: TerminalViewState
    @StateObject private var tree = FileTreeModel()

    private var rootPath: String? {
        FileTree.rootPath(workingDirectory: terminal.workingDirectory, startDir: pane.startDir)
    }

    var body: some View {
        // Flattened once per pass and handed down, rather than recomputed by
        // each branch that asks whether there is anything to show.
        let rows = tree.rows
        return VStack(spacing: 0) {
            pathHeader
            Divider()
            if tree.root == nil {
                InspectorPlaceholder(text: "This pane has no directory")
            } else if rows.isEmpty {
                InspectorPlaceholder(text: tree.isLoadingRoot ? "Reading…" : "Empty")
            } else {
                listing(rows)
            }
        }
        // `initial: true` because the first root is not a change: the panel has
        // to point somewhere the moment it appears.
        .onChange(of: rootPath, initial: true) { _, path in tree.setRoot(path) }
    }

    private var pathHeader: some View {
        HStack(spacing: 6) {
            Text(displayRoot)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The tail is the part that identifies a directory; the head is
                // the part everything shares.
                .truncationMode(.head)
                .help(tree.root?.path ?? "")
            Spacer(minLength: 0)
            Button { tree.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Re-read this directory")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private var displayRoot: String {
        guard let path = tree.root?.path else { return "—" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func listing(_ rows: [FileRow]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    FileTreeRow(
                        row: row,
                        isSelected: tree.selected == row.entry.path,
                        onToggle: { tree.toggle(row) },
                        onSelect: { tree.selected = row.entry.path },
                        onInsert: { insert(row.entry) }
                    )
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Insert, never execute. The text is decided by `FileTree.insertion`,
    /// which #13 will call with the same rules for a drop from Finder, and the
    /// bytes go to the pane's own `ZmxClient` as ordinary keyboard input — the
    /// daemon cannot tell this from typing, which is exactly the point.
    private func insert(_ entry: FileEntry) {
        tree.selected = entry.path
        let text = FileTree.insertion(for: entry.path, relativeTo: rootPath)
        Log.debug("insert into \(pane.name): \(text)")
        model.insert(text)
    }
}

/// One row: an indent, a disclosure zone, an icon, a name.
///
/// Expansion hangs off the disclosure zone rather than off the row, and that is
/// deliberate. A single click selects and nothing else, so the double-click
/// that inserts a path cannot be preceded by a folder silently opening and
/// closing under the pointer. The zone is the full row height and wide enough
/// to hit without aiming.
private struct FileTreeRow: View {
    let row: FileRow
    let isSelected: Bool
    let onToggle: () -> Void
    let onSelect: () -> Void
    let onInsert: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(row.depth) * 11, height: 1)
            disclosure
            Image(systemName: row.entry.isDirectory ? "folder" : "doc")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 12)
            Text(row.entry.name)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.9) : .clear)
        )
        .contentShape(Rectangle())
        // The double-click handler is declared first so that SwiftUI resolves
        // the two-tap sequence to it rather than delivering two single taps.
        .onTapGesture(count: 2, perform: onInsert)
        .onTapGesture(perform: onSelect)
        .help(row.canExpand || !row.entry.isDirectory
            ? row.entry.path
            : "\(row.entry.path) — a link back to a directory already open above")
    }

    @ViewBuilder
    private var disclosure: some View {
        if row.isLoading {
            // Something has to happen when a slow directory is opened, or the
            // click reads as ignored.
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12)
        } else if row.canExpand {
            Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .contentShape(Rectangle())
                .onTapGesture(perform: onToggle)
        } else {
            Color.clear.frame(width: 12, height: 1)
        }
    }
}
