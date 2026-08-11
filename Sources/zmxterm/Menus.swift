import AppKit
import SwiftUI

/// Everything the right button offers, in one place so a pane's menu is the
/// same wherever you right-click it — sidebar row or pane header.
///
/// Killing is the only destructive verb here and it asks first. That isn't
/// politeness: the whole model rests on a pane being a view of a session rather
/// than the session itself, so anything that actually ends a process has to
/// look different from everything that doesn't.
struct PaneMenu: View {
    let pane: ZmxSession
    let registry: ZmxRegistry

    @Binding var renaming: ZmxSession?
    @Binding var killing: ZmxSession?
    var onSplit: (SplitAxis) -> Void

    var body: some View {
        Button("Split Right") { onSplit(.horizontal) }
        Button("Split Down") { onSplit(.vertical) }

        Divider()

        Button("Rename…") { renaming = pane }
        if pane.isEphemeral {
            Button("Keep") { registry.setEphemeral(false, on: pane.name) }
        } else {
            Button("Mark Disposable") { registry.setEphemeral(true, on: pane.name) }
        }
        if pane.state != nil {
            Button("Clear Status") { Zmx.run(["set", pane.name, "state="]); registry.refresh() }
        }

        Divider()

        Button("Copy Attach Command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("zmx attach \(pane.name)", forType: .string)
        }
        Button("Copy Session Name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pane.name, forType: .string)
        }

        Divider()

        // Deliberately adjacent to Kill, because the two are only distinguishable
        // if you can see them together: this one takes the pane off the tab and
        // leaves the process alone, the next one ends it. Neither word is a
        // synonym for the other, and no dialog interrupts this one — there is
        // nothing to lose, and the pane is still in the sidebar under its own
        // name afterwards.
        if pane.canLeaveTab {
            Button("Remove from Tab") { registry.removeFromTab(pane.name) }
        }
        Button("Kill Session…") { killing = pane }
    }
}

/// A tab is the one thing here that genuinely can be renamed, because its
/// identity is a label rather than a socket path.
struct TabMenu: View {
    let tab: String
    let panes: [ZmxSession]
    let registry: ZmxRegistry

    @Binding var renamingTab: String?
    @Binding var killingTab: String?

    var body: some View {
        Button("New Pane") {
            if let anchor = panes.first { registry.split(pane: anchor.name, axis: .horizontal) }
        }
        Button("Rename Tab…") { renamingTab = tab }

        Divider()

        Button("Kill All Panes…") { killingTab = tab }
    }
}

/// Rename and kill both need a beat of confirmation, and both are the same
/// shape, so they share one modifier rather than being spelled out at each
/// call site.
extension View {
    func renameSheet(
        item: Binding<ZmxSession?>,
        title: String = "Rename Pane",
        perform: @escaping (ZmxSession, String) -> Void
    ) -> some View {
        modifier(RenamePrompt(item: item, title: title, perform: perform))
    }
}

private struct RenamePrompt: ViewModifier {
    @Binding var item: ZmxSession?
    let title: String
    let perform: (ZmxSession, String) -> Void

    @State private var text = ""

    func body(content: Content) -> some View {
        content
            .alert(title, isPresented: .init(get: { item != nil }, set: { if !$0 { item = nil } })) {
                TextField("Name", text: $text)
                Button("Cancel", role: .cancel) { item = nil }
                Button("Rename") {
                    if let target = item { perform(target, text) }
                    item = nil
                }
            } message: {
                // Say the constraint rather than silently mangling the input.
                Text("Letters, digits, dots, dashes and underscores. Spaces become dashes.")
            }
            .onChange(of: item) { _, new in
                text = new.map { PaneLabel.display($0, among: [$0]) } ?? ""
            }
    }
}
