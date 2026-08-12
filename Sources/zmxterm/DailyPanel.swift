import AppKit
import SwiftUI

/// The last twelve top-level lines of today's daily note, newest first.
///
/// Nothing here follows the focused pane, which makes it the first inspector
/// panel that is about the *day* rather than about a session — the container
/// was built for a second panel and this is what it turned out to be.
///
/// It draws only when `Daily.settings` is set, and the panel is not offered at
/// all otherwise: see `InspectorPanel.available`. Most people have no daily note
/// and should see no panel, no placeholder, and no explanation of a feature they
/// did not ask for.
struct DailyPanel: View {
    @ObservedObject var monitor: DailyMonitor

    var body: some View {
        VStack(spacing: 0) {
            pathHeader
            Divider()
            content
        }
        // The timer covers a note appearing while the window is elsewhere, but
        // looking at the panel is the moment its content matters most, and a
        // refresh is one `stat` and a small read.
        .onAppear { monitor.refresh() }
    }

    private var pathHeader: some View {
        HStack(spacing: 6) {
            Text(monitor.relativePath.isEmpty ? "—" : monitor.relativePath)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                // The tail identifies the note; the head is the folder every
                // one of them shares.
                .truncationMode(.head)
            Spacer(minLength: 0)
            if let name = monitor.settings?.adapter.name {
                Text(name)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .help(monitor.absolutePath ?? "")
    }

    @ViewBuilder
    private var content: some View {
        switch monitor.note {
        case .missing:
            // The normal state of every morning. Not an error, and not phrased
            // as one.
            InspectorPlaceholder(text: "Nothing written today yet")
        case .downloading:
            // Never "no work today" for a note that exists on another machine —
            // saying the day was empty when it was only absent is the worst
            // thing this panel could get wrong.
            InspectorPlaceholder(text: "Fetching today's note from iCloud…")
        case let .unreadable(reason):
            InspectorPlaceholder(text: reason)
        case .text:
            if monitor.bullets.isEmpty {
                InspectorPlaceholder(text: "No top-level entries yet")
            } else {
                entries
            }
        }
    }

    private var entries: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(monitor.bullets) { bullet in
                    DailyRow(bullet: bullet, onOpen: open)
                }
            }
            .padding(.vertical, 4)
        }
    }

    /// Clicking any line opens the *note*, not the line — neither scheme
    /// addresses a block, and a link that claims to would land somewhere else.
    ///
    /// A missing app fails quietly: `NSWorkspace.open` returns false for a
    /// scheme nobody has registered, and a dialog about it would be this app
    /// complaining about another app's absence.
    private func open() {
        guard let url = monitor.url else { return }
        if !NSWorkspace.shared.open(url) {
            Log.debug("daily: nothing opened \(url.scheme ?? "?"):// — is the app installed?")
        }
    }
}

/// One line: markdown rendered where it is free, truncated to a line, with the
/// whole of it on hover.
///
/// These lines are long — 300 characters is ordinary — so the tooltip is not a
/// nicety, it is the only way to read one. `.help` on the row rather than on the
/// text, so the hover target is the same shape as the click target.
private struct DailyRow: View {
    let bullet: Daily.Bullet
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        Text(bullet.rendered)
            .font(.system(size: 11))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isHovering ? Color.primary.opacity(0.07) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture(perform: onOpen)
            .help(bullet.text)
    }
}
