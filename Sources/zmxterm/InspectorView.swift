import AppKit
import GhosttyTerminal
import SwiftUI

/// The panels the right sidebar can show.
///
/// The container was built for a second panel — a case, an icon and a line in
/// the `switch` in `InspectorView.panelBody`, with the header, the collapse
/// rail, the width and the preference already working — and `daily` is it.
/// (The markdown preview it was originally built in anticipation of turned out
/// to belong in a zmx session instead; see `Reader`.) Whatever a panel needs
/// from the focused pane arrives the same way the files panel gets it: passed
/// in. `daily` needs nothing from it, which is allowed.
enum InspectorPanel: String, CaseIterable, Identifiable {
    case files
    case daily

    var id: String { rawValue }

    var title: String {
        switch self {
        case .files: "Files"
        case .daily: "Today"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder"
        case .daily: "text.line.first.and.arrowtriangle.forward"
        }
    }

    /// Which panels exist *on this machine*, which is not the same as which
    /// panels this build has.
    ///
    /// `daily` is offered only once somebody has configured a vault, and this
    /// is the one place that decides it: the rail, the picker and the body all
    /// read the same list, so a panel cannot be missing from the rail and still
    /// reachable through a stale preference. Hiding it entirely is the point of
    /// the feature rather than a nicety — most people have no daily note, and a
    /// panel that greets them with an explanation of one is worse than no panel.
    static func available(daily isConfigured: Bool) -> [InspectorPanel] {
        allCases.filter { $0 != .daily || isConfigured }
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
    /// Needed because a panel can do more than look: opening a document finds
    /// this tab's reader, or splits a pane to make one.
    let registry: ZmxRegistry
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

    /// Today's note. Owned here rather than by `DailyPanel`, because whether
    /// there is a daily panel at all is a question the rail and the picker ask
    /// before any panel is built — and because a `@StateObject` inside a view
    /// that only exists while its panel is selected would re-read the file
    /// every time you switched tabs in this sidebar.
    @StateObject private var daily = DailyMonitor()

    private var panels: [InspectorPanel] {
        InspectorPanel.available(daily: daily.settings != nil)
    }

    /// A stored preference can name a panel that is no longer available — the
    /// vault moved, or the defaults were cleared with the sidebar open on
    /// `daily` — so the selection is resolved against what exists rather than
    /// trusted. Falling back to `.files` is the same rule `resolvedTab` follows
    /// when a tab disappears from under the window.
    private var selectedPanel: InspectorPanel {
        let chosen = InspectorPanel(rawValue: panel) ?? .files
        return panels.contains(chosen) ? chosen : .files
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
            ForEach(panels) { item in
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
            // would be a segmented control of one, which reads as broken — and
            // on a machine with no daily note configured, one panel is exactly
            // what there is.
            if panels.count > 1 {
                Picker("", selection: $panel) {
                    ForEach(panels) { item in
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
                FilesPanel(pane: pane, model: model, registry: registry, terminal: model.terminal)
            } else {
                InspectorPlaceholder(text: "No pane focused")
            }
        case .daily:
            DailyPanel(monitor: daily)
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
    let registry: ZmxRegistry
    @ObservedObject var terminal: TerminalViewState
    @StateObject private var tree = FileTreeModel()

    /// Sending a document to the reader can reach a pane that has no surface —
    /// one in a hidden tab, or one created a moment ago — so the store is what
    /// answers "is there a live client for this", not the model above.
    @EnvironmentObject private var store: PaneStore

    /// Why the last Open in Reader did nothing. An alert rather than a line in
    /// the panel: every reason is something to go and fix, and a message that
    /// scrolls away with the tree would be a refusal nobody read.
    @State private var readerProblem: String?

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
        .alert(
            "Nothing opened",
            isPresented: .init(get: { readerProblem != nil }, set: { if !$0 { readerProblem = nil } })
        ) {
            Button("OK", role: .cancel) { readerProblem = nil }
        } message: {
            Text(readerProblem ?? "")
        }
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
                        onInsert: { insert(row.entry) },
                        onOpenInReader: { openInReader(row.entry) }
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

    /// The other thing a file can do, and deliberately not what double-clicking
    /// does.
    ///
    /// Double-click still inserts a path, for every file, `.md` or not: uniform
    /// behaviour beats special-casing by extension, and a gesture whose meaning
    /// depends on the file you aimed it at is a gesture you have to think about.
    /// Opening a document is a verb you ask for by name.
    ///
    /// The path is absolute, not the tree-relative text `insert` produces. The
    /// reader's shell is not necessarily sitting where the tree is rooted, and
    /// a relative path resolved against the wrong directory opens nothing.
    private func openInReader(_ entry: FileEntry) {
        tree.selected = entry.path
        // Read here rather than inside, so a complaint about the list itself can
        // be said out loud. A viewer list that could not be read falls back to
        // the built-in defaults, which means everything still works and nothing
        // the file said applies — the exact shape of bug that is discovered
        // three days later, so it is said once per distinct problem per run:
        // often enough to be seen, rarely enough not to become the alert you
        // dismiss without reading.
        let viewers = Reader.rules
        let outcome = registry.openInReader(
            path: entry.path, tab: pane.tab, near: pane.name, store: store, rules: viewers.rules
        )
        Log.debug("open in reader from \(pane.name): \(entry.path) → \(outcome)")
        if let problem = viewers.problem, problem != Self.reportedViewerProblem {
            Self.reportedViewerProblem = problem
            Log.notice("reader: \(problem)")
            readerProblem = [problem, outcome.problem].compactMap { $0 }.joined(separator: "\n\n")
            return
        }
        readerProblem = outcome.problem
    }

    private static var reportedViewerProblem: String?
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
    let onOpenInReader: () -> Void

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
        .contextMenu {
            // Offered for every file rather than for `.md` alone: the viewer is
            // configuration, so which files are readable is the viewer's
            // opinion and not something to hardcode a list of extensions
            // against. Directories are excluded because no viewer takes one.
            if !row.entry.isDirectory {
                Button("Open in Reader") { onOpenInReader() }
            }
            Button("Insert Path") { onInsert() }
        }
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
