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

/// A rename that turned out to land on an existing tab, held while the user is
/// asked whether they meant to merge.
private struct TabMerge: Equatable {
    let from: String
    let into: String
}

/// The New Tab dialog while it is open.
///
/// `proposed` is kept alongside `typed` rather than being recovered by
/// comparison later, because "was this name accepted or chosen" is the whole
/// question the dialog exists to answer, and it stops being answerable the
/// moment the proposal is forgotten.
private struct NewTabPrompt: Equatable {
    let proposed: String
    var typed: String
    /// Set when a create was refused, so the reason can be shown next to the
    /// field being fixed rather than in a second dialog on top of this one.
    var taken: String?

    init(proposed: String) {
        self.proposed = proposed
        typed = proposed
    }
}

/// A sheet rather than the `.alert` the rename prompts use, and the difference
/// is the entire point of the feature.
///
/// The proposal has to open selected, so that accepting it costs one keystroke
/// and replacing it costs none — a field you must clear first is the friction
/// this dialog was asked for in order to remove. A SwiftUI `TextField` in an
/// `.alert` takes focus and leaves the caret at the end, and there is no
/// supported way in, because the alert's window is AppKit's and the field
/// inside it is not reachable from the view that declared it. An
/// `NSViewRepresentable` in a sheet is a real `NSTextField` we hold, so
/// selecting its contents is one call on its field editor. Matching the
/// alerts' looks would have been worth something; matching them by shipping a
/// field that does not select would have been worth less than nothing.
private struct NewTabSheet: View {
    let proposed: String
    @Binding var typed: String
    let taken: String?
    var onCancel: () -> Void
    var onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Tab").font(.headline)
            // The same sentence the Rename Tab alert says, because it is the
            // same charset and the user should not have to discover it twice.
            Text("Letters, digits, dots, dashes and underscores. Spaces become dashes.")
                .font(.caption)
                .foregroundStyle(.secondary)

            SelectedTextField(text: $typed, placeholder: proposed, onSubmit: onCreate, onCancel: onCancel)
                .frame(height: 22)

            if let taken {
                // Which name, not just "that didn't work" — the refusal is only
                // useful if it says what to change.
                Text("\(taken) is already in use. A tab's name is also its session, so a new one cannot share it.")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// An `NSTextField` that selects what is already in it the moment it takes
/// focus.
///
/// Everything here is about that one behaviour. Focus is claimed once, on the
/// first update that has a window to claim it from — a sheet's contents are
/// built before they are hosted, so doing it in `makeNSView` would aim at no
/// window — and `selectAll` runs on the field editor, which only exists once
/// the field is first responder.
///
/// Return and Escape are handled here rather than left to the sheet's default
/// and cancel buttons. While the field editor is first responder it sees those
/// keys first, and what it does with them is its own business; routing them
/// explicitly is the difference between "usually works" and "works".
private struct SelectedTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var onSubmit: () -> Void
    var onCancel: () -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: text)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.sendsActionOnEndEditing = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        // Only when it differs: writing the value back unconditionally moves
        // the insertion point to the end on every keystroke.
        if field.stringValue != text { field.stringValue = text }
        guard !context.coordinator.hasFocused, let window = field.window else { return }
        context.coordinator.hasFocused = true
        DispatchQueue.main.async {
            window.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
            // The one thing nobody can check by reading the code, and nothing
            // on screen distinguishes "focused" from "focused and selected"
            // until you type. So say it out loud: a run with ZMXTERM_DEBUG set
            // reports the range, and a selection of the whole string is the
            // feature working.
            Log.debug("new tab field: selected \(field.currentEditor()?.selectedRange ?? NSRange(location: -1, length: -1)) of \(field.stringValue.count)")
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SelectedTextField
        var hasFocused = false

        init(_ parent: SelectedTextField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

struct RootView: View {
    @StateObject private var registry = ZmxRegistry()
    @StateObject private var store = PaneStore()
    @State private var selectedTab: String?
    @State private var selectedPane: String?
    @AppStorage("railCollapsed") private var isRailCollapsed = false
    /// The right sidebar, stored exactly like the rail beside it. Whether a
    /// panel is open, how wide it is and which one it shows are preferences
    /// about this window — they say nothing about any zmx session, so they are
    /// none of `zsm`'s business and none of a label's.
    @AppStorage("inspectorCollapsed") private var isInspectorCollapsed = false
    @AppStorage("inspectorWidth") private var inspectorWidth = 260.0
    @AppStorage("inspectorPanel") private var inspectorPanel = InspectorPanel.files.rawValue
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
    @State private var mergingTab: TabMerge?
    @State private var newTabPrompt: NewTabPrompt?
    @State private var tabNameDraft = ""
    @State private var focusRequest: (pane: String, token: Int) = ("", 0)
    @State private var configWatcher = TerminalConfig.Watcher()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(
                tabs: registry.tabs,
                collapsed: isRailCollapsed,
                registry: registry,
                selectedTab: $selectedTab,
                selectedPane: $selectedPane,
                onFocusPane: requestFocus,
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
                        killingPane: $killingPane,
                        focusRequest: focusRequest
                    )
                    .padding(Theme.gap)
                } else {
                    EmptyStateView(sessionCount: registry.sessions.count)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            InspectorView(
                pane: focusedPane,
                // Asking the store for the focused pane's model creates nothing
                // new: it is a pane of the tab being rendered, so the split
                // canvas has already asked for the same object.
                model: focusedPane.map { store.model(for: $0.name) },
                collapsed: $isInspectorCollapsed,
                width: $inspectorWidth,
                panel: $inspectorPanel
            )
            .frame(width: isInspectorCollapsed ? InspectorView.collapsedWidth : inspectorWidth)
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
                    switch registry.planRename(of: tab, to: tabNameDraft) {
                    case .unchanged:
                        break
                    case let .rename(slug):
                        registry.writeTab(slug, over: tab)
                        selectedTab = slug
                    case let .merge(slug):
                        // Not refused, but not done either: the write is held
                        // until someone says they meant it.
                        mergingTab = TabMerge(from: tab, into: slug)
                    }
                }
                renamingTab = nil
            }
        }
        .confirmationDialog(
            "A tab called \(mergingTab?.into ?? "") already exists.",
            isPresented: .init(get: { mergingTab != nil }, set: { if !$0 { mergingTab = nil } })
        ) {
            Button("Merge Tabs") {
                if let merge = mergingTab {
                    registry.writeTab(merge.into, over: merge.from)
                    selectedTab = merge.into
                }
                mergingTab = nil
            }
            Button("Cancel", role: .cancel) { mergingTab = nil }
        } message: {
            // Say the cost rather than a generic "are you sure". Nothing stops
            // running — this is not Kill — but the `tab` label was the only
            // record of which tab a pane belonged to, so renaming back does not
            // undo it.
            Text("""
            Renaming \(mergingTab?.from ?? "") onto it puts both tabs' panes in one \
            layout, interleaved by the slots they already claimed and at half the \
            sizes they asked for. Nothing stops running, but there is no way back: \
            the labels saying which tab each pane came from are what gets overwritten.
            """)
        }
        .sheet(isPresented: .init(get: { newTabPrompt != nil }, set: { if !$0 { newTabPrompt = nil } })) {
            if let prompt = newTabPrompt {
                NewTabSheet(
                    proposed: prompt.proposed,
                    typed: .init(
                        get: { newTabPrompt?.typed ?? "" },
                        // Editing clears the refusal: the message is about a
                        // name that is no longer the one in the field.
                        set: { newTabPrompt?.typed = $0; newTabPrompt?.taken = nil }
                    ),
                    taken: prompt.taken,
                    onCancel: { newTabPrompt = nil },
                    onCreate: createTab
                )
            }
        }
        .onChange(of: renamingTab) { _, new in tabNameDraft = new ?? "" }
        .onChange(of: registry.sessions) { _, sessions in
            store.prune(keeping: Set(sessions.map(\.name)))
            reconcileSelection(with: sessions)
        }
        .onAppear {
            selectedTab = AppOptions.initialTab ?? registry.tabs.first?.name
            // Opening a terminal without a live keyboard is the same bug in a
            // different coat, so claim focus once the first tab resolves.
            if let first = resolvedTab?.panes.first?.name {
                selectedPane = first
                requestFocus(first)
            }
        }
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
                // ⌥⌘B for the other side, because it is the same thought.
                Button("") { isInspectorCollapsed.toggle() }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                // ⇧⌘, is Ghostty's own reload binding.
                Button("") { TerminalConfig.reload() }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
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

    /// A new pane exists to be typed into, so creating one has to put the
    /// keyboard in it. Selection alone only draws the ring.
    private func requestFocus(_ pane: String) {
        focusRequest = (pane, focusRequest.token + 1)
    }

    private func split(_ axis: SplitAxis) {
        guard let focused = selectedPane ?? resolvedTab?.panes.first?.name else { return }
        if let created = registry.split(pane: focused, axis: axis) {
            selectedPane = created
            requestFocus(created)
        }
    }

    /// Both entry points — the sidebar button and ⌘T, which are the same button
    /// — end here, and here only opens the dialog. Nothing is created until it
    /// is confirmed.
    private func openTab() {
        guard newTabPrompt == nil else { return }
        newTabPrompt = NewTabPrompt(proposed: registry.proposedTabName())
    }

    private func createTab() {
        guard let prompt = newTabPrompt else { return }
        switch registry.planNewTab(typed: prompt.typed, proposed: prompt.proposed) {
        case let .taken(name):
            // The dialog stays open with what was typed still in it. Creating
            // under a name in use would attach to that session instead of
            // making a tab, so there is nothing to fall back to.
            newTabPrompt?.taken = name
        case let .create(name, ephemeral):
            newTabPrompt = nil
            let near = selectedPane.flatMap { pane in registry.sessions.first { $0.name == pane } }
            if let created = registry.newTab(named: name, ephemeral: ephemeral, near: near) {
                selectedTab = created
                selectedPane = created
                requestFocus(created)
            }
        }
    }

    private var resolvedTab: (name: String, panes: [ZmxSession])? {
        registry.tabs.first { $0.name == selectedTab }
    }

    /// The pane anything on the right is about.
    ///
    /// Restricted to the visible tab on purpose: `selectedPane` can name a pane
    /// in a tab you have since switched away from, and a file tree following a
    /// pane nobody can see would be worse than one following nothing. A tab
    /// with panes but no selection falls back to its first, which is the pane
    /// the keyboard would go to anyway.
    private var focusedPane: ZmxSession? {
        guard let tab = resolvedTab else { return nil }
        return tab.panes.first { $0.name == selectedPane } ?? tab.panes.first
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
    let onFocusPane: (String) -> Void
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
    /// knowing that — and the shortcut hangs off this button rather than a
    /// second one, so there is only ever one thing New Tab can mean.
    ///
    /// The ellipsis is a promise the app now keeps: something opens and asks
    /// before anything is created.
    private var newTabButton: some View {
        Button(action: onNewTab) {
            HStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                if !collapsed {
                    Text("New Tab…").font(.system(size: 12))
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
        .help("New tab (⌘T)")
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
                                onFocusPane(pane.name)
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
    let focusRequest: (pane: String, token: Int)

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
                        focusToken: focusRequest.pane == placed.session.name ? focusRequest.token : 0,
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
    /// Non-zero when this pane has been asked to take the keyboard.
    let focusToken: Int

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
                .background(TerminalFocusProbe(token: focusToken))
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
        //
        // Repainting a rebuilt surface happens off its first viewport report,
        // inside `PaneModel` — `onAppear` runs before the representable has
        // made a surface, so a replay asked for here would land on nothing.
        // This asks anyway, late and idempotently, because a report is not
        // guaranteed to arrive at all; `repaintAfterRebuild` explains when.
        .onAppear { model.repaintAfterRebuild() }
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
