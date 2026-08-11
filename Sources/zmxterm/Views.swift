import AppKit
import GhosttyTerminal
import SwiftUI

enum Theme {
    /// The gap between panes. It has to be independent of whatever Ghostty
    /// theme is loaded — if the chrome ever matches the terminal background the
    /// separation disappears and the rounded corners read as nothing.
    static let chrome = Color(nsColor: .underPageBackgroundColor)
    static let groupCard = Color(nsColor: .controlBackgroundColor)
    static let failedCard = Color(nsColor: .systemRed).opacity(0.18)
    static let cornerRadius: CGFloat = 8
    static let gap: CGFloat = 8

    /// Shape is who, colour is whether. A resting pane is dim; one that wants
    /// you takes its own colour. Selection lives in the background, so the two
    /// channels never collide.
    static func stateColor(_ state: String?) -> Color {
        switch state {
        case "waiting": .orange
        case "failed": .red
        default: .secondary.opacity(0.7)
        }
    }
}

struct RootView: View {
    @StateObject private var registry = ZmxRegistry()
    @StateObject private var store = PaneStore()
    @State private var selectedTab: String?
    @State private var selectedPane: String?
    @AppStorage("railCollapsed") private var isRailCollapsed = false
    /// Acknowledging is a destructive write to someone else's session, so it
    /// waits for the window to settle. SwiftUI hands out initial focus while
    /// the app is still inactive, and clearing an agent's `waiting` because a
    /// window opened — possibly on another Space — would lose the one signal
    /// the whole feature exists to carry.
    @State private var acksEnabled = false
    @State private var renamingPane: ZmxSession?
    @State private var killingPane: ZmxSession?
    @State private var renamingTab: String?
    @State private var killingTab: String?
    @State private var tabNameDraft = ""

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                tabs: registry.tabs,
                collapsed: isRailCollapsed,
                registry: registry,
                selectedTab: $selectedTab,
                selectedPane: $selectedPane,
                renamingPane: $renamingPane,
                killingPane: $killingPane,
                renamingTab: $renamingTab,
                killingTab: $killingTab,
                onNewTab: openTab
            )
            .frame(width: isRailCollapsed ? 44 : 220)

            Divider()

            Group {
                if let tab = resolvedTab, let node = PaneTree.build(tab.panes) {
                    let _ = Log.debug("rendering tab \(tab.name): \(node.debugShape)")
                    SplitCanvas(
                        node: node,
                        selectedPane: $selectedPane,
                        registry: registry,
                        renamingPane: $renamingPane,
                        killingPane: $killingPane
                    )
                    .padding(Theme.gap)
                } else {
                    EmptyStateView(sessionCount: registry.sessions.count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.chrome)
        .environmentObject(store)
        .renameSheet(item: $renamingPane) { pane, name in registry.setTitle(name, on: pane.name) }
        .confirmationDialog(
            "Kill \(killingPane?.name ?? "")?",
            isPresented: .init(get: { killingPane != nil }, set: { if !$0 { killingPane = nil } })
        ) {
            Button("Kill Session", role: .destructive) {
                if let pane = killingPane { registry.kill(pane.name) }
                killingPane = nil
            }
        } message: {
            Text("Whatever is running in it stops. Closing the pane instead just detaches.")
        }
        .confirmationDialog(
            "Kill every pane in \(killingTab ?? "")?",
            isPresented: .init(get: { killingTab != nil }, set: { if !$0 { killingTab = nil } })
        ) {
            Button("Kill All", role: .destructive) {
                if let tab = killingTab {
                    for pane in registry.sessions where pane.tab == tab { registry.kill(pane.name) }
                }
                killingTab = nil
            }
        }
        .alert(
            "Rename Tab",
            isPresented: .init(get: { renamingTab != nil }, set: { if !$0 { renamingTab = nil } })
        ) {
            TextField("Name", text: $tabNameDraft)
            Button("Cancel", role: .cancel) { renamingTab = nil }
            Button("Rename") {
                if let tab = renamingTab {
                    registry.renameTab(tab, to: tabNameDraft)
                    selectedTab = Zmx.slug(tabNameDraft)
                }
                renamingTab = nil
            }
        }
        .onChange(of: renamingTab) { _, new in tabNameDraft = new ?? "" }
        .onChange(of: registry.sessions) { _, sessions in
            store.prune(keeping: Set(sessions.map(\.name)))
            reconcileSelection(with: sessions)
        }
        .onAppear { selectedTab = AppOptions.initialTab ?? registry.tabs.first?.name }
        .onChange(of: selectedPane) { _, name in
            // Looking at a pane is the acknowledgement. Clearing the label
            // rather than a local flag means a second window and `zsm` agree,
            // and that "I already saw that one" survives a restart.
            guard acksEnabled, NSApp.isActive else { return }
            guard let name, registry.sessions.first(where: { $0.name == name })?.state != nil else { return }
            Log.debug("ack: clearing state on \(name)")
            Zmx.run(["set", name, "state="])
            registry.refresh()
        }
        .task {
            try? await Task.sleep(for: .seconds(2))
            acksEnabled = true
        }
        .background {
            // Hidden buttons rather than a command menu: a SwiftPM executable
            // has no menu nib to hang one off.
            Group {
                Button("") { isRailCollapsed.toggle() }
                    .keyboardShortcut("b", modifiers: .command)
                Button("") { split(.horizontal) }
                    .keyboardShortcut("d", modifiers: .command)
                Button("") { split(.vertical) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            .opacity(0)
        }
    }

    /// Killing a pane from `zsm` is a normal thing to do, so the selection has
    /// to survive whatever it leaves behind. A tab that loses its last pane
    /// stops existing, and a window still pointing at it would sit on an empty
    /// state forever with a sidebar full of live sessions beside it.
    private func reconcileSelection(with sessions: [ZmxSession]) {
        let names = Set(registry.tabs.map(\.name))
        if selectedTab == nil || !names.contains(selectedTab!) {
            selectedTab = AppOptions.initialTab.flatMap { names.contains($0) ? $0 : nil }
                ?? registry.tabs.first?.name
        }
        if let pane = selectedPane, !sessions.contains(where: { $0.name == pane }) {
            selectedPane = resolvedTab?.panes.first?.name
        }
    }

    private func split(_ axis: SplitAxis) {
        guard let focused = selectedPane ?? resolvedTab?.panes.first?.name else { return }
        if let created = registry.split(pane: focused, axis: axis) {
            selectedPane = created
        }
    }

    private func openTab() {
        let near = selectedPane.flatMap { name in registry.sessions.first { $0.name == name } }
        if let created = registry.newTab(near: near) {
            selectedTab = created
            selectedPane = created
        }
    }

    private var resolvedTab: (name: String, panes: [ZmxSession])? {
        registry.tabs.first { $0.name == selectedTab }
    }
}

/// A window opens showing nothing and you pick a session — so the empty state
/// is the session browser, which is the view the app needs anyway.
struct EmptyStateView: View {
    let sessionCount: Int

    var body: some View {
        VStack(spacing: 6) {
            Text(sessionCount == 0 ? "No live zmx sessions" : "Pick a tab")
                .font(.headline)
            Text(sessionCount == 0
                ? "zmx attach <name> in any terminal and it appears here"
                : "\(sessionCount) session\(sessionCount == 1 ? "" : "s") running")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    let tabs: [(name: String, panes: [ZmxSession])]
    let collapsed: Bool
    let registry: ZmxRegistry
    @Binding var selectedTab: String?
    @Binding var selectedPane: String?
    @Binding var renamingPane: ZmxSession?
    @Binding var killingPane: ZmxSession?
    @Binding var renamingTab: String?
    @Binding var killingTab: String?
    let onNewTab: () -> Void

    @StateObject private var usage = UsageMonitor()

    var body: some View {
        VStack(spacing: 0) {
            tabList
            Spacer(minLength: 0)
            newTabButton
            UsageFooter(meters: usage.meters, collapsed: collapsed, isStale: usage.isStale)
        }
        .background(Theme.chrome)
    }

    /// ⌘T works without it, but a window you've never used shouldn't require
    /// knowing that.
    private var newTabButton: some View {
        Button(action: onNewTab) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                if !collapsed {
                    Text("New Terminal").font(.system(size: 12))
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, collapsed ? 0 : 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("t", modifiers: .command)
        .help("New terminal (⌘T)")
    }

    private var tabList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(tabs, id: \.name) { tab in
                    // A tab with three panes is three rows inside one card, so
                    // the group reads as one object the way the split does.
                    VStack(alignment: .leading, spacing: 2) {
                        if !collapsed {
                            // The name carries the hierarchy, so the chrome can
                            // stop repeating it: the tab owns everything before
                            // the dot, each row owns what comes after.
                            Text(tab.name)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.top, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .contextMenu {
                                    TabMenu(
                                        tab: tab.name, panes: tab.panes, registry: registry,
                                        renamingTab: $renamingTab, killingTab: $killingTab
                                    )
                                }
                        }
                        ForEach(tab.panes) { pane in
                            // Collapsed keeps one row per pane rather than one
                            // per tab: vertical space is the plentiful axis on
                            // a tall screen, horizontal is the scarce one, and
                            // the gaps still carry the grouping.
                            Group {
                                if collapsed {
                                    RailRow(pane: pane, isSelected: selectedPane == pane.name)
                                } else {
                                    SidebarRow(
                                        pane: pane,
                                        label: PaneLabel.display(pane, among: tab.panes),
                                        isSelected: selectedPane == pane.name,
                                        isInSelectedTab: selectedTab == tab.name
                                    )
                                }
                            }
                            .onTapGesture {
                                selectedTab = tab.name
                                selectedPane = pane.name
                            }
                            .contextMenu {
                                PaneMenu(
                                    pane: pane,
                                    registry: registry,
                                    renaming: $renamingPane,
                                    killing: $killingPane,
                                    onSplit: { registry.split(pane: pane.name, axis: $0) }
                                )
                            }
                        }
                    }
                    .padding(4)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius)
                            .fill(tab.panes.contains { $0.state == "failed" } ? Theme.failedCard : Theme.groupCard)
                    )
                }
            }
            .padding(collapsed ? 4 : 8)
        }
    }
}

/// Icon plus state, nothing else. Shape says who, colour says whether — so a
/// rail of dim glyphs with one orange in it answers "who needs me" at a glance,
/// without expanding.
struct RailRow: View {
    let pane: ZmxSession
    let isSelected: Bool

    var body: some View {
        AgentIcon(pane: pane, size: 16)
            .frame(width: 30, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.9) : .clear)
            )
            .contentShape(Rectangle())
            .help("\(pane.name)\(pane.state.map { " — " + $0 } ?? "")")
    }
}

struct SidebarRow: View {
    let pane: ZmxSession
    let label: String
    let isSelected: Bool
    let isInSelectedTab: Bool

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(pane: pane, size: 13)
                .frame(width: 14)
            Text(label)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if pane.clients == 0 {
                // Running, unwatched — a state no terminal that owns its
                // sessions can express.
                Circle().fill(.secondary.opacity(0.35)).frame(width: 5, height: 5)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.9)
                    : isInSelectedTab ? Color.primary.opacity(0.05) : .clear)
        )
        .contentShape(Rectangle())
        .help("\(pane.name) — \(pane.displayDirectory) — \(pane.clients) client(s)")
    }
}

// MARK: - Splits

/// Every pane and divider placed from one rect, in one pass.
///
/// Divider drags stay local until mouse-up. Routing each mouse event through
/// the registry would mean a `zmx set` subprocess per frame, and would rebuild
/// the sidebar sixty times a second for no visible change there. Release
/// commits every leaf's share once.
struct SplitCanvas: View {
    let node: PaneNode
    @Binding var selectedPane: String?
    let registry: ZmxRegistry
    @Binding var renamingPane: ZmxSession?
    @Binding var killingPane: ZmxSession?

    private static let space = "zmxterm.splitCanvas"

    @EnvironmentObject private var store: PaneStore

    @State private var overrides: [String: [Double]] = [:]
    /// Pre-drag fractions for the divider currently being dragged. Fixed for
    /// the whole gesture, so the pointer is measured against something that
    /// isn't moving with it.
    @State private var dragBase: [String: [Double]] = [:]

    var body: some View {
        GeometryReader { geometry in
            let layout = PaneLayout.compute(
                node,
                in: CGRect(origin: .zero, size: geometry.size),
                gap: Theme.gap,
                overrides: overrides
            )

            ZStack(alignment: .topLeading) {
                ForEach(layout.panes, id: \.session.name) { placed in
                    PaneSurfaceView(
                        session: placed.session,
                        label: PaneLabel.display(placed.session, among: layout.panes.map(\.session)),
                        model: store.model(for: placed.session.name),
                        isSelected: selectedPane == placed.session.name,
                        onFocus: { select($0) },
                        menu: {
                            PaneMenu(
                                pane: placed.session,
                                registry: registry,
                                renaming: $renamingPane,
                                killing: $killingPane,
                                onSplit: { registry.split(pane: placed.session.name, axis: $0) }
                            )
                        }
                    )
                    .frame(width: placed.rect.width, height: placed.rect.height)
                    .offset(x: placed.rect.minX, y: placed.rect.minY)
                }
                ForEach(layout.dividers) { divider in
                    DividerHandle(
                        divider: divider,
                        coordinateSpace: Self.space,
                        onDrag: { location in drag(divider, to: location) },
                        onCommit: { commit(layout.panes) },
                        onEqualize: { equalize(divider) }
                    )
                    .frame(width: divider.rect.width, height: divider.rect.height)
                    .offset(x: divider.rect.minX, y: divider.rect.minY)
                }
            }
            .coordinateSpace(name: Self.space)
            // Frames are computed, never animated. A drag resizes panes every
            // mouse event and an implicit animation would make them chase the
            // pointer instead of tracking it.
            .transaction { $0.animation = nil }
        }
        // Drop a drag override once the labels catch up — either our own
        // commit round-tripping, or an agent rewriting the layout while we
        // watch. Without this the local drag would outrank the model forever.
        .onChange(of: layoutSignature) { _, _ in overrides = [:] }
    }

    private func select(_ name: String) {
        if selectedPane != name { selectedPane = name }
    }

    private var layoutSignature: String {
        node.leaves.map { "\($0.name):\($0.position ?? ""):\($0.sizeFraction ?? 0)" }.joined(separator: "|")
    }

    private func drag(_ divider: PaneLayout.Divider, to location: CGPoint) {
        let base = dragBase[divider.id] ?? divider.fractions
        dragBase[divider.id] = base
        let along = divider.axis == .horizontal ? location.x : location.y
        if let moved = PaneLayout.fractions(draggingTo: along, divider: divider, base: base) {
            overrides[divider.splitID] = moved
        }
    }

    private func commit(_ panes: [PaneLayout.Placed]) {
        dragBase = [:]
        // Whole-tab shares are exactly what `size` means, and the layout has
        // already worked them out, so committing is writing them back.
        for placed in panes {
            Zmx.run(["set", placed.session.name, String(format: "size=%.3f", placed.share)])
        }
    }

    /// Double-click equalises, the way Ghostty's divider does.
    private func equalize(_ divider: PaneLayout.Divider) {
        let count = divider.fractions.count
        guard count > 0 else { return }
        overrides[divider.splitID] = Array(repeating: 1.0 / Double(count), count: count)
    }
}

/// The seam between two panes: a hairline you can see, a wider strip you can
/// grab. The gesture reports in the canvas's coordinate space rather than the
/// handle's own, because the handle moves while you drag it.
private struct DividerHandle: View {
    let divider: PaneLayout.Divider
    let coordinateSpace: String
    let onDrag: (CGPoint) -> Void
    let onCommit: () -> Void
    let onEqualize: () -> Void

    private static let grabOutset: CGFloat = 4
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .contentShape(Rectangle().inset(by: -Self.grabOutset))
            .overlay {
                Capsule()
                    .fill(.secondary.opacity(isHovering ? 0.5 : 0))
                    .frame(
                        width: divider.axis == .horizontal ? 2 : 24,
                        height: divider.axis == .horizontal ? 24 : 2
                    )
            }
            .onHover { hovering in
                isHovering = hovering
                // push/pop rather than set: the system resets the cursor on
                // every mouse-moved event, so a plain set flickers.
                if hovering {
                    (divider.axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpace))
                    .onChanged { onDrag($0.location) }
                    .onEnded { _ in onCommit() }
            )
            .onTapGesture(count: 2) { onEqualize(); onCommit() }
    }
}

struct PaneSurfaceView: View {
    let session: ZmxSession
    let label: String
    @ObservedObject var model: PaneModel
    let isSelected: Bool

    /// Raised when the surface itself takes focus — a click inside the
    /// terminal, or focus arriving from the sidebar.
    var onFocus: ((String) -> Void)?
    /// The same menu the sidebar row shows, so a pane offers the same verbs
    /// wherever you happen to right-click it.
    @ViewBuilder var menu: () -> PaneMenu

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(session: session, label: label, model: model)
                // Deliberately only on the header. A tap gesture spanning the
                // surface consumes the click the terminal needed for first
                // responder, so focusing took two.
                .onTapGesture { onFocus?(session.name) }
                .contextMenu(menuItems: menu)
            TerminalSurfaceView(context: model.terminal)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        // Listen, never push. `TerminalSurfaceView.terminalFocused` is a
        // two-way binding, and its push half resigns first responder whenever
        // the binding reads false during an update — which it does on the very
        // render triggered by the click that just focused the pane. The result
        // was focus granted and immediately revoked, so it took two clicks.
        // `isFocused` comes from the surface's own delegate and needs no
        // binding at all.
        .onReceive(model.terminal.$isFocused) { focused in
            guard focused else { return }
            onFocus?(session.name)
        }
    }
}

struct PaneHeader: View {
    let session: ZmxSession
    let label: String
    @ObservedObject var model: PaneModel

    var body: some View {
        HStack(spacing: 6) {
            AgentIcon(pane: session, size: 12)
            Text(label)
                .font(.system(size: 11, weight: .medium))
            Text(session.displayDirectory)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 0)
            Text(model.gridSummary)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Theme.groupCard)
    }
}
